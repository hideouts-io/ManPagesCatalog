#!/usr/bin/env python3
"""Prepare the complete pinned stock bundle without executing CodeQL.

The original verified .tar.zst is retained for the pinned init action's tools
input. A separate complete unpacking is available for controls before init.
No bundle executable, extraction, tracer, or compiler is run by this helper.
Use --output for a new absolute directory. Existing work is never overwritten.
Vendor file and directory mtimes are preserved and verified at nanosecond
precision, using the exact PAX decimal value when present.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import threading
import time
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation, localcontext
from pathlib import Path, PurePosixPath
from types import FrameType
from typing import Iterator, Literal, TypedDict


class Member(TypedDict):
    """Validated fields consumed from the vendor archive boundary."""

    path: str
    kind: Literal["file", "directory"]
    size: int
    mode: int
    link: str
    sha256: str
    mtime_ns: int
    mtime_source: Literal["pax", "integer"]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def read_pins(path: Path) -> dict[str, str | int]:
    strings = {"version", "release_tag", "filename", "sha256", "checksum_filename",
               "checksum_sha256", "archive_root", "cli_relative_path"}
    integers = {"bytes", "checksum_bytes", "release_id", "asset_id", "max_entries", "max_unpacked_bytes",
                "expected_entries", "expected_regular_files", "expected_directories", "expected_regular_bytes"}
    raw: object = json.loads(path.read_text())
    if not isinstance(raw, dict) or set(raw) != strings | integers:
        raise ValueError("Stock bundle pins must use the exact reviewed schema")
    result: dict[str, str | int] = {}
    for key in strings:
        value = raw[key]
        if not isinstance(value, str) or not value:
            raise ValueError(f"Invalid stock bundle string field: {key}")
        if key.endswith("sha256") and not re.fullmatch("[0-9a-f]{64}", value):
            raise ValueError(f"Invalid stock bundle digest: {key}")
        result[key] = value
    for key in integers:
        value = raw[key]
        if type(value) is not int or not 0 < value <= 8_000_000_000:
            raise ValueError(f"Invalid stock bundle integer field: {key}")
        result[key] = value
    version = pin_string(result, "version")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Stock bundle version must be an exact release version")
    if result["release_tag"] != "codeql-bundle-v" + version:
        raise ValueError("Stock bundle tag does not match the pinned version")
    if result["filename"] != "codeql-bundle-osx64.tar.zst" or result["checksum_filename"] != result["filename"] + ".checksum.txt":
        raise ValueError("The complete macOS bundle and its official checksum are required")
    if result["archive_root"] != "codeql" or result["cli_relative_path"] != "codeql/codeql":
        raise ValueError("Unexpected stock bundle layout")
    if pin_size(result, "bytes") > 1_000_000_000 or pin_size(result, "checksum_bytes") > 1024:
        raise ValueError("Stock bundle downloads exceed the reviewed size bounds")
    if pin_size(result, "max_entries") > 200_000:
        raise ValueError("Stock archive entry bound exceeds 200000")
    return result


def pin_string(pins: dict[str, str | int], key: str) -> str:
    value = pins[key]
    if not isinstance(value, str):
        raise ValueError(f"Expected string pin: {key}")
    return value


def pin_size(pins: dict[str, str | int], key: str) -> int:
    value = pins[key]
    if type(value) is not int:
        raise ValueError(f"Expected integer pin: {key}")
    return value


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)


def download(url: str, path: Path, size: int, digest: str, output: Path, deadline: float) -> None:
    if path.exists() or path.is_symlink():
        raise ValueError(f"Download destination already exists: {path.name}")
    command = ["/usr/bin/curl", "--disable", "--fail", "--location", "--proto", "=https",
               "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "180",
               "--max-filesize", str(size), "--silent", "--show-error", "--output", str(path), url]
    environment = {key: os.environ[key] for key in ("HOME", "LANG") if key in os.environ}
    log = output / "logs" / (path.name + ".stderr")
    started = time.monotonic()
    if started >= deadline:
        raise TimeoutError("Stock bundle deadline reached before download")
    reason = ""
    with log.open("xb") as error:
        process = subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL,
                                   stderr=error, start_new_session=True)
        try:
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    reason = "10 minute stock preparation deadline"
                    break
                if log.stat().st_size > 64 * 1024 or (path.exists() and path.stat().st_size > size):
                    reason = "stock download exceeded its file/log bound"
                    break
                if shutil.disk_usage(output).free < 3_000_000_000:
                    reason = "free disk below 3 GB"
                    break
                time.sleep(0.2)
        finally:
            stop_process(process)
    if reason or process.returncode != 0:
        raise RuntimeError(f"Stock download failed: status {process.returncode}; {reason or 'see logs/' + log.name}")
    if path.stat().st_size != size or sha256_file(path) != digest:
        raise ValueError(f"Downloaded stock artifact does not match its size/digest: {path.name}")
    write_json(output / "summary" / (path.name + ".download.json"), {
        "url": url, "bytes": size, "sha256": digest, "seconds": round(time.monotonic() - started, 3)})


@contextmanager
def archive_stream(path: Path, output: Path, name: str, deadline: float) -> Iterator[tarfile.TarFile]:
    """Stream native decompression without restoring any archive path to disk."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Stock bundle deadline reached before archive read")
    log = output / "logs" / (name + ".stderr")
    expired = threading.Event()
    with log.open("xb") as error:
        # -P preserves source names for our validation; @ copies archive records
        # to a plain tar stream without filesystem extraction or tool execution.
        process = subprocess.Popen(["/usr/bin/tar", "-cPf", "-", "--format=pax", "@" + str(path)],
                                   stdout=subprocess.PIPE, stderr=error, start_new_session=True)
        if process.stdout is None:
            raise RuntimeError("Native archive reader has no output stream")

        def expire() -> None:
            expired.set()
            stop_process(process)

        timer = threading.Timer(remaining, expire)
        timer.start()
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
                yield archive
            while process.stdout.read(1024 * 1024):
                pass
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
            if expired.is_set():
                raise TimeoutError("Stock archive read exceeded its preparation deadline")
            if process.returncode != 0 or log.stat().st_size > 64 * 1024:
                raise RuntimeError(f"Native stock archive reader failed: status {process.returncode}")
        finally:
            timer.cancel()
            stop_process(process)
            timer.join(timeout=20)
            process.stdout.close()


def archive_path(name: str) -> str:
    if not name or len(name.encode("utf8")) > 4096 or any(ord(char) < 32 for char in name):
        raise ValueError("Invalid stock archive path length or control character")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "codeql":
        raise ValueError(f"Stock archive path escapes its root: {name}")
    return str(path)


def archive_mtime_ns(member: tarfile.TarInfo) -> int:
    if "mtime" not in member.pax_headers:
        if type(member.mtime) is not int or not 0 <= member.mtime <= 9_223_372_036:
            raise ValueError(f"Invalid integer archive mtime: {member.name}")
        return member.mtime * 1_000_000_000
    raw = member.pax_headers["mtime"]
    if not isinstance(raw, str) or not 0 < len(raw) <= 64 or not re.fullmatch(r"[+-]?[0-9]+(?:\.[0-9]+)?", raw):
        raise ValueError(f"Invalid PAX archive mtime: {member.name}")
    try:
        with localcontext() as context:
            context.prec = 80
            context.Emin = -100
            context.Emax = 100
            seconds = Decimal(raw)
            if not seconds.is_finite() or not 0 <= seconds <= Decimal("9223372036.854775807"):
                raise ValueError(f"Non-finite or out-of-range PAX archive mtime: {member.name}")
            nanoseconds = seconds * Decimal(1_000_000_000)
            if nanoseconds != nanoseconds.to_integral_value():
                raise ValueError(f"PAX archive mtime exceeds exact nanosecond precision: {member.name}")
            return int(nanoseconds)
    except InvalidOperation as error:
        raise ValueError(f"Malformed PAX archive mtime: {member.name}") from error


def restore_mtime(path: Path, nanoseconds: int) -> None:
    os.utime(path, ns=(path.lstat().st_atime_ns, nanoseconds), follow_symlinks=False)
    if path.lstat().st_mtime_ns != nanoseconds:
        raise ValueError(f"Unpacked stock mtime did not round-trip exactly: {path}")


def member_metadata(member: tarfile.TarInfo) -> Member:
    path = archive_path(member.name)
    if member.mode < 0 or member.mode & ~0o777 or member.size < 0:
        raise ValueError(f"Unsafe stock archive permissions or size: {path}")
    kind: Literal["file", "directory"]
    if member.isfile():
        kind = "file"
    elif member.isdir():
        kind = "directory"
    else:
        raise ValueError(f"Pinned stock archive must not contain links or special members: {path}")
    if member.linkname:
        raise ValueError(f"Pinned stock member has unexpected link metadata: {path}")
    if kind != "file" and member.size != 0:
        raise ValueError(f"Stock link/directory has unexpected payload bytes: {path}")
    mtime_source: Literal["pax", "integer"] = "pax" if "mtime" in member.pax_headers else "integer"
    return {"path": path, "kind": kind, "size": member.size, "mode": member.mode,
            "link": member.linkname, "sha256": "", "mtime_ns": archive_mtime_ns(member),
            "mtime_source": mtime_source}


def validate_members(members: dict[str, Member]) -> None:
    root = members.get("codeql")
    if root is None or root["kind"] != "directory":
        raise ValueError("Stock archive must contain its codeql root directory")
    for path in members:
        for parent in PurePosixPath(path).parents:
            ancestor = members.get(str(parent))
            if ancestor is not None and ancestor["kind"] != "directory":
                raise ValueError(f"Stock member is nested beneath a link or file: {path}")


def inventory(path: Path, output: Path, pins: dict[str, str | int], deadline: float) -> dict[str, Member]:
    members: dict[str, Member] = {}
    total = 0
    with archive_stream(path, output, "inventory", deadline) as archive:
        for entry in archive:
            member = member_metadata(entry)
            if member["path"] in members:
                raise ValueError(f"Duplicate normalized stock archive path: {member['path']}")
            if len(members) >= pin_size(pins, "max_entries"):
                raise ValueError("Stock archive exceeded its entry bound")
            total += member["size"]
            if total > pin_size(pins, "max_unpacked_bytes"):
                raise ValueError("Stock archive exceeded its uncompressed size bound")
            if member["kind"] == "file":
                stream = archive.extractfile(entry)
                if stream is None:
                    raise ValueError(f"Stock archive payload is unavailable: {member['path']}")
                digest = hashlib.sha256()
                with stream:
                    while block := stream.read(1024 * 1024):
                        digest.update(block)
                member = {**member, "sha256": digest.hexdigest()}
            members[member["path"]] = member
    validate_members(members)
    if len(members) != pin_size(pins, "expected_entries") or total != pin_size(pins, "expected_regular_bytes"):
        raise ValueError("Stock archive differs from its independently inspected entry/byte inventory")
    if sum(row["kind"] == "file" for row in members.values()) != pin_size(pins, "expected_regular_files"):
        raise ValueError("Stock archive regular-file count differs from its inspected inventory")
    if sum(row["kind"] == "directory" for row in members.values()) != pin_size(pins, "expected_directories"):
        raise ValueError("Stock archive directory count differs from its inspected inventory")
    return members


def unpack(path: Path, destination: Path, members: dict[str, Member], output: Path, deadline: float) -> None:
    if shutil.disk_usage(output).free < sum(row["size"] for row in members.values()) + 3_000_000_000:
        raise RuntimeError("Not enough disk space for the complete stock bundle plus 3 GB reserve")
    destination.mkdir()
    seen: set[str] = set()
    with archive_stream(path, output, "unpack", deadline) as archive:
        for entry in archive:
            member = member_metadata(entry)
            expected = members.get(member["path"])
            if expected is None or member != {**expected, "sha256": ""} or member["path"] in seen:
                raise ValueError("Stock archive inventory changed between validation and unpacking")
            seen.add(member["path"])
            target = destination / member["path"]
            if member["kind"] == "directory":
                target.mkdir(parents=True, exist_ok=True)
            elif member["kind"] == "file":
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = archive.extractfile(entry)
                if stream is None:
                    raise ValueError(f"Stock archive payload is unavailable: {member['path']}")
                with stream, target.open("xb") as result:
                    shutil.copyfileobj(stream, result, length=1024 * 1024)
                target.chmod(member["mode"])
    if seen != set(members):
        raise ValueError("Stock archive unpacking omitted inventory entries")
    for member in sorted(members.values(), key=lambda row: len(PurePosixPath(row["path"]).parts), reverse=True):
        target = destination / member["path"]
        actual_mode = target.lstat().st_mode
        if not (stat.S_ISREG(actual_mode) if member["kind"] == "file" else stat.S_ISDIR(actual_mode)):
            raise ValueError(f"Unpacked stock member is a link, special file, or incorrect type: {member['path']}")
        if member["kind"] == "directory":
            target.chmod(member["mode"])
        if member["kind"] == "file":
            if not stat.S_ISREG(target.lstat().st_mode) or target.stat().st_size != member["size"] or sha256_file(target) != member["sha256"]:
                raise ValueError(f"Unpacked stock file does not match its validated payload: {member['path']}")
        if stat.S_IMODE(target.lstat().st_mode) != member["mode"]:
            raise ValueError(f"Unpacked stock permissions differ: {member['path']}")
        restore_mtime(target, member["mtime_ns"])
        if time.monotonic() >= deadline:
            raise TimeoutError("Stock bundle verification exceeded its preparation deadline")


def prepare(output: Path, pins_path: Path) -> None:
    if platform.system() != "Darwin":
        raise RuntimeError("This stock macOS preparation helper requires native macOS BSD tar")
    pins = read_pins(pins_path)
    if output.exists() or output.is_symlink():
        raise ValueError("Stock output must be new; existing files are never removed or replaced")
    output.mkdir(parents=True, mode=0o700)
    (output / "summary").mkdir()
    (output / "logs").mkdir()
    write_json(output / "summary/status.json", {"complete": False, "codeql_executed": False})
    started = time.monotonic()
    deadline = started + 600
    base = "https://github.com/github/codeql-action/releases/download/" + pin_string(pins, "release_tag") + "/"
    checksum = output / pin_string(pins, "checksum_filename")
    download(base + checksum.name, checksum, pin_size(pins, "checksum_bytes"), pin_string(pins, "checksum_sha256"), output, deadline)
    expected_checksum = pin_string(pins, "sha256") + "  " + pin_string(pins, "filename") + "\n"
    if checksum.read_text() != expected_checksum:
        raise ValueError("Official stock checksum content differs from the reviewed bundle digest")
    archive = output / pin_string(pins, "filename")
    download(base + archive.name, archive, pin_size(pins, "bytes"), pin_string(pins, "sha256"), output, deadline)
    archive.chmod(0o400)
    original_stat = archive.stat()
    members = inventory(archive, output, pins, deadline)
    manifest = output / "inventory.json"
    write_json(manifest, list(members.values()))
    destination = output / "bundle"
    unpack(archive, destination, members, output, deadline)
    cli = destination / pin_string(pins, "cli_relative_path")
    if not cli.is_file() or not stat.S_ISREG(cli.lstat().st_mode) or not cli.stat().st_mode & 0o111:
        raise ValueError("Complete stock bundle is missing its executable codeql/codeql launcher")
    final_stat = archive.stat()
    if final_stat.st_size != original_stat.st_size or final_stat.st_mtime_ns != original_stat.st_mtime_ns or sha256_file(archive) != pin_string(pins, "sha256"):
        raise ValueError("Original stock archive changed during preparation")
    summary = {"complete": True, "release_version": pin_string(pins, "version"),
        "release_id": pin_size(pins, "release_id"), "asset_id": pin_size(pins, "asset_id"),
        "url": base + archive.name, "archive_path": str(archive), "archive_bytes": final_stat.st_size,
        "archive_sha256": pin_string(pins, "sha256"), "cli_path": str(cli), "cli_sha256": sha256_file(cli),
        "inventory_sha256": sha256_file(manifest), "entries": len(members),
        "regular_files": sum(row["kind"] == "file" for row in members.values()),
        "regular_bytes": sum(row["size"] for row in members.values()),
        "directories": sum(row["kind"] == "directory" for row in members.values()),
        "symlinks": 0, "hardlinks": 0, "links_and_special_members_rejected": True,
        "all_payloads_and_permissions_verified": True, "original_archive_preserved": True,
        "all_archive_mtimes_verified": True,
        "pax_mtime_entries": sum(row["mtime_source"] == "pax" for row in members.values()),
        "integer_mtime_entries": sum(row["mtime_source"] == "integer" for row in members.values()),
        "fractional_mtime_entries": sum(row["mtime_ns"] % 1_000_000_000 != 0 for row in members.values()),
        "codeql_executed": False, "compiler_extraction_executed": False,
        "seconds": round(time.monotonic() - started, 3)}
    write_json(output / "summary/status.json", summary)
    (output / "summary/archive-path.txt").write_text(str(archive) + "\n")
    (output / "summary/cli-path.txt").write_text(str(cli) + "\n")
    print(json.dumps(summary))


def cancel_command(signum: int, frame: FrameType | None) -> None:
    raise InterruptedError(f"Stock bundle preparation cancelled by signal {signum}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New absolute stock bundle output directory")
    arguments = parser.parse_args()
    if not arguments.output.is_absolute() or arguments.output.is_symlink():
        raise ValueError("Stock output must be absolute without an existing final symlink")
    signal.signal(signal.SIGTERM, cancel_command)
    prepare(arguments.output.resolve(), Path(__file__).resolve().parent / "stock-bundle.json")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        print(f"Stock CodeQL preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
