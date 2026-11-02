#!/usr/bin/env python3
"""Build experimental control/candidate extractors without running extraction.

Run on macOS 26 Intel with Xcode 26.4.1, using --output for a new ignored
directory beneath the checkout. B rebuilds the unpatched Swift importer object;
C rebuilds the same object with the pinned guard patch. Each uses independent
Bazel caches and the public build/install target. The stock CodeQL bundle is
neither an input nor a destination.

The unchanged public semmle_code stub omits internal Linux glibc checks and Rust
universal assembly. Both configured Swift closures must contain zero targets
from that stub. This build does not claim internal release or regression tests.
All external commands have deadlines, bounded logs, and task-owned cleanup.
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
import time
from types import FrameType
from pathlib import Path, PurePosixPath
from typing import TypedDict


class SourceFile(TypedDict):
    """Validated fields from the pinned public-source manifest."""

    name: str
    git_blob: str
    sha256: str
    bytes: int


class ArchiveMember(TypedDict):
    """Observed payload identity at the native archive boundary."""

    name: str
    bytes: int
    sha256: str


class PackageFile(TypedDict):
    """Observed file or directory identity in an installed extractor pack."""

    path: str
    type: str
    bytes: int
    mode: int
    sha256: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def json_object(value: object, fields: set[str]) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("JSON object keys must be strings")
        result[key] = item
    if set(result) != fields:
        raise ValueError(f"Unexpected JSON fields: expected {sorted(fields)}")
    return result


def string_field(value: dict[str, object], name: str) -> str:
    item = value[name]
    if not isinstance(item, str) or not item:
        raise ValueError(f"Expected a nonempty string for {name}")
    return item


def positive_integer(value: dict[str, object], name: str) -> int:
    item = value[name]
    if type(item) is not int or item <= 0 or item > 2_000_000_000:
        raise ValueError(f"Invalid artifact byte count for {name}")
    return item


def read_pins(directory: Path) -> dict[str, str | int]:
    names = {
        "codeql_commit", "codeql_archive_sha256", "swift_prebuilt_sha256",
        "resource_dir_macos_sha256", "picosha2_sha256", "bazel_version",
        "bazel_darwin_arm64_sha256", "bazel_darwin_x86_64_sha256",
        "candidate_patch_sha256", "private_source_manifest_sha256",
        "codeql_archive_bytes", "swift_prebuilt_bytes", "resource_dir_macos_bytes",
        "picosha2_bytes",
    }
    raw: object = json.loads((directory / "inputs.json").read_text())
    data = json_object(raw, names)
    result: dict[str, str | int] = {}
    for name in sorted(names):
        if name.endswith("_bytes"):
            result[name] = positive_integer(data, name)
        else:
            item = string_field(data, name)
            if name.endswith("_sha256") and not re.fullmatch("[0-9a-f]{64}", item):
                raise ValueError(f"Invalid SHA-256 pin: {name}")
            result[name] = item
    if result["bazel_version"] != "9.0.0":
        raise ValueError("This reviewed recipe requires Bazel 9.0.0")
    if not re.fullmatch("[0-9a-f]{40}", pin_string(result, "codeql_commit")):
        raise ValueError("CodeQL source must use a full commit identity")
    return result


def pin_string(pins: dict[str, str | int], name: str) -> str:
    value = pins[name]
    if not isinstance(value, str):
        raise ValueError(f"Expected string pin: {name}")
    return value


def pin_size(pins: dict[str, str | int], name: str) -> int:
    value = pins[name]
    if type(value) is not int:
        raise ValueError(f"Expected integer pin: {name}")
    return value


def read_sources(directory: Path, pins: dict[str, str | int]) -> tuple[str, list[SourceFile]]:
    manifest = directory / "swift-source-manifest.json"
    if sha256_file(manifest) != pin_string(pins, "private_source_manifest_sha256"):
        raise ValueError("Swift source manifest digest does not match its pin")
    raw: object = json.loads(manifest.read_text())
    data = json_object(raw, {"commit", "path_prefix", "sources"})
    commit = string_field(data, "commit")
    if not re.fullmatch("[0-9a-f]{40}", commit) or data["path_prefix"] != "lib/ClangImporter":
        raise ValueError("Unexpected Swift source identity or path prefix")
    rows = data["sources"]
    if not isinstance(rows, list) or len(rows) != 18:
        raise ValueError("The pinned Swift manifest must contain 18 files")
    sources: list[SourceFile] = []
    for row in rows:
        item = json_object(row, {"name", "git_blob", "sha256", "bytes"})
        name = string_field(item, "name")
        blob = string_field(item, "git_blob")
        digest = string_field(item, "sha256")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*\.(h|def|cpp)", name):
            raise ValueError(f"Invalid Swift source basename: {name}")
        if not re.fullmatch("[0-9a-f]{40}", blob) or not re.fullmatch("[0-9a-f]{64}", digest):
            raise ValueError(f"Invalid Swift source identity: {name}")
        sources.append({"name": name, "git_blob": blob, "sha256": digest,
                        "bytes": positive_integer(item, "bytes")})
    if len({row["name"] for row in sources}) != 18:
        raise ValueError("Duplicate Swift source names")
    if sum(row["name"] == "ImportMacro.cpp" for row in sources) != 1:
        raise ValueError("The manifest must contain exactly one ImportMacro.cpp")
    return commit, sources


def command_environment(developer_dir: str, temporary: Path) -> dict[str, str]:
    environment = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "LANG") if key in os.environ}
    return {**environment, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
            "DEVELOPER_DIR": developer_dir, "TMPDIR": str(temporary)}


def host_information() -> dict[str, str]:
    if platform.system() != "Darwin":
        raise RuntimeError("This experiment requires macOS 26 Intel")
    macos = subprocess.check_output(["/usr/bin/sw_vers", "--productVersion"], text=True, timeout=20).strip()
    if not macos.startswith("26.") or platform.machine() != "x86_64":
        raise RuntimeError(f"This experiment requires macOS 26 Intel; found macOS {macos} {platform.machine()}")
    xcode = subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True, timeout=20).strip()
    xcode_lines = xcode.splitlines()
    if not xcode_lines or xcode_lines[0] != "Xcode 26.4.1":
        raise RuntimeError("This experiment requires Xcode 26.4.1; selected Xcode does not match")
    developer = os.environ.get("DEVELOPER_DIR")
    if developer is None:
        developer = subprocess.check_output(["/usr/bin/xcode-select", "-p"], text=True, timeout=20).strip()
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True, timeout=20).strip()
    sdk_version = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True, timeout=20).strip()
    if not Path(sdk).is_dir() or sdk_version != "26.4":
        raise RuntimeError(f"Selected Xcode must supply macOS SDK 26.4; found {sdk_version}")
    return {"macos": macos, "architecture": platform.machine(), "xcode": xcode,
            "developer_dir": developer, "sdk": sdk, "sdk_version": sdk_version}


def terminate_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)


def run_command(command: list[str], cwd: Path, output: Path, name: str,
                environment: dict[str, str], deadline: float, monitored: tuple[Path, ...]) -> None:
    logs = output / "logs"
    stdout = logs / (name + ".stdout")
    stderr = logs / (name + ".stderr")
    started = time.monotonic()
    if started >= deadline:
        raise RuntimeError(f"Experiment deadline reached before {name}")
    reason = ""
    with stdout.open("xb") as out, stderr.open("xb") as err:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=out,
                                   stderr=err, start_new_session=True)
        try:
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    reason = "20 minute experiment deadline"
                    break
                if shutil.disk_usage(output).free < 3_000_000_000:
                    reason = "free disk below 3 GB"
                    break
                if any(path.exists() and path.stat().st_size > 64 * 1024 * 1024
                       for path in (stdout, stderr, *monitored)):
                    reason = "diagnostic log exceeded 64 MiB"
                    break
                time.sleep(0.2)
        finally:
            terminate_process(process)
    result = {"name": name, "command": command, "exit_code": process.returncode,
              "seconds": round(time.monotonic() - started, 3), "stop_reason": reason}
    with (output / "summary/commands.jsonl").open("a") as stream:
        stream.write(json.dumps(result) + "\n")
    if reason or process.returncode != 0:
        raise RuntimeError(f"{name} failed: status {process.returncode}; {reason or 'see bounded logs/' + name + '.stderr'}")


def download(url: str, target: Path, digest: str, size: int, output: Path,
             name: str, environment: dict[str, str], deadline: float) -> None:
    command = ["/usr/bin/curl", "--fail", "--location", "--proto", "=https",
               "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "180",
               "--max-filesize", str(size), "--silent", "--show-error", "--output", str(target), url]
    run_command(command, output, output, name, environment, deadline, ())
    if target.stat().st_size != size or sha256_file(target) != digest:
        raise ValueError(f"Downloaded artifact identity mismatch: {target.name}")


def extract_source(archive: Path, destination: Path, prefix: str) -> None:
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        names: set[str] = set()
        total = 0
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != prefix:
                raise ValueError(f"Unsafe source archive path: {member.name}")
            if member.name in names or not (member.isfile() or member.isdir()):
                raise ValueError(f"Duplicate or special source archive member: {member.name}")
            names.add(member.name)
            total += member.size
        if len(members) > 100_000 or total > 500_000_000:
            raise ValueError("Source archive exceeded the reviewed extraction bounds")
        destination.mkdir()
        for member in members:
            relative = PurePosixPath(member.name).relative_to(prefix)
            if relative == PurePosixPath("."):
                continue
            target = destination / str(relative)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = source.extractfile(member)
                if stream is None:
                    raise ValueError(f"Missing source member payload: {member.name}")
                with stream, target.open("xb") as result:
                    shutil.copyfileobj(stream, result)
                target.chmod(member.mode & 0o777)


def archive_members(path: Path) -> list[ArchiveMember]:
    members: list[ArchiveMember] = []
    with path.open("rb") as stream:
        if stream.read(8) != b"!<arch>\n":
            raise ValueError("Compiler library is not a native ar archive")
        while header := stream.read(60):
            if len(header) != 60 or header[58:] != b"`\n":
                raise ValueError("Malformed compiler archive header")
            name = header[:16].decode("ascii").strip()
            size = int(header[48:58])
            if size < 0 or size > 500_000_000 or len(members) > 10_000:
                raise ValueError("Compiler archive member exceeded bounds")
            name_size = 0
            if name.startswith("#1/"):
                name_size = int(name[3:])
                if name_size < 1 or name_size > min(size, 4096):
                    raise ValueError("Invalid compiler archive extended name")
                name = stream.read(name_size).rstrip(b"\0").decode("utf8")
            digest = hashlib.sha256()
            remaining = size - name_size
            while remaining:
                block = stream.read(min(remaining, 1024 * 1024))
                if not block:
                    raise ValueError("Truncated compiler archive member")
                digest.update(block)
                remaining -= len(block)
            if not name.startswith("__.SYMDEF"):
                members.append({"name": name, "bytes": size - name_size, "sha256": digest.hexdigest()})
            if size % 2 and len(stream.read(1)) != 1:
                raise ValueError("Missing compiler archive padding")
    return members


def verify_replacement(original: list[ArchiveMember], replacement: list[ArchiveMember], object_file: Path) -> None:
    if len(original) != 4638 or len(replacement) != len(original):
        raise ValueError("Compiler archive member count changed")
    changes = [(before, after) for before, after in zip(original, replacement) if before != after]
    if len(changes) != 1:
        raise ValueError("Compiler library must have exactly one changed non-index member")
    before, after = changes[0]
    if before["name"] != "ImportMacro.cpp.o" or after["name"] != "ImportMacro.cpp.o":
        raise ValueError("Compiler library changed an unrelated object")
    if after["sha256"] != sha256_file(object_file) or after["bytes"] != object_file.stat().st_size:
        raise ValueError("Compiler library does not contain the requested object payload")


def package_manifest(directory: Path) -> list[PackageFile]:
    result: list[PackageFile] = []
    for path in sorted(directory.rglob("*")):
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            result.append({"path": str(path.relative_to(directory)), "type": "directory",
                           "bytes": 0, "mode": stat.S_IMODE(mode), "sha256": ""})
        elif not stat.S_ISREG(mode):
            raise ValueError(f"Installed pack contains a symlink or special file: {path.relative_to(directory)}")
        else:
            result.append({"path": str(path.relative_to(directory)), "type": "file", "bytes": path.stat().st_size,
                           "mode": stat.S_IMODE(mode), "sha256": sha256_file(path)})
    required = ("codeql-extractor.yml", "swift.dbscheme", "swift.dbscheme.stats", "LICENSE",
                "tools/osx64/extractor", "tools/osx64/extractor.real", "tools/osx64/swift-autobuilder")
    if any(not (directory / name).is_file() for name in required) or not (directory / "resource-dir/osx64").is_dir():
        raise ValueError("Installed extractor pack is incomplete")
    return result


def bazel_arguments(bazel: Path, prebuilt: Path, cache: Path, host: dict[str, str]) -> list[str]:
    return [str(bazel), "--batch", "--nosystem_rc", "--nohome_rc",
            "--output_user_root=" + str(cache / "user"), "--output_base=" + str(cache / "output"),
            "--host_jvm_args=-Xmx2g", "--macos_qos_class=utility", "run",
            "--repository_cache=" + str(cache / "repositories"), "--jobs=2", "--loading_phase_threads=2",
            "--local_resources=cpu=2", "--local_resources=memory=4096", "--http_max_parallel_downloads=2",
            "--experimental_convenience_symlinks=ignore", "--override_repository=swift-prebuilt-macos=" + str(prebuilt),
            "--macos_sdk_version=" + host["sdk_version"], "--macos_minimum_os=13.0",
            "--extra_toolchains=@@apple_support++apple_cc_configure_extension+local_config_apple_cc_toolchains//:all",
            "--verbose_failures", "--color=no", "--curses=no"]


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def build(output: Path, inputs: Path, host: dict[str, str]) -> None:
    pins = read_pins(inputs)
    swift_commit, sources = read_sources(inputs, pins)
    patch = inputs / "ImportMacro-feature-guard.patch"
    if sha256_file(patch) != pin_string(pins, "candidate_patch_sha256"):
        raise ValueError("Candidate patch does not match its reviewed digest")
    if output.exists() or output.is_symlink():
        raise ValueError("Output must be a new directory; existing work is never removed")
    ancestor = output.parent
    while not ancestor.exists():
        ancestor = ancestor.parent
    checkout = Path(subprocess.check_output(["git", "-C", str(ancestor), "rev-parse", "--show-toplevel"], text=True, timeout=20).strip()).resolve()
    if not output.is_relative_to(checkout) or ".git" in output.relative_to(checkout).parts:
        raise ValueError("Output must be beneath an existing checkout and outside Git metadata")
    ignored = subprocess.run(["git", "-C", str(checkout), "check-ignore", "--quiet", str(output)], timeout=20)
    if ignored.returncode != 0:
        raise ValueError("Output must be ignored by the checkout, such as build/compiler-candidate")
    output.mkdir(parents=True, mode=0o700)
    for name in ("downloads", "logs", "summary", "tmp", "events"):
        (output / name).mkdir()
    environment = command_environment(host["developer_dir"], output / "tmp")
    deadline = time.monotonic() + 1200
    write_json(output / "provenance.json", {"host": host, "pins": pins, "sources": sources,
               "input_sha256": sha256_file(inputs / "inputs.json"), "extraction_executed": False,
               "experimental_only": True, "compiler_regression_tests_run": False})
    shutil.copy2(output / "provenance.json", output / "summary/provenance.json")
    write_json(output / "summary/status.json", {"complete": False, "extraction_executed": False,
               "state": "build in progress; final summary is required for success"})
    commit = pin_string(pins, "codeql_commit")
    downloads = output / "downloads"
    source_archive = downloads / "codeql.tar.gz"
    download("https://codeload.github.com/github/codeql/tar.gz/" + commit, source_archive,
             pin_string(pins, "codeql_archive_sha256"), pin_size(pins, "codeql_archive_bytes"),
             output, "download-codeql", environment, deadline)
    source = output / "codeql-source"
    extract_source(source_archive, source, "codeql-" + commit)
    if (source / ".bazelversion").read_text().strip() != pin_string(pins, "bazel_version"):
        raise ValueError("Public source Bazel version differs from the pinned recipe")
    bazel_name = "bazel-9.0.0-darwin-x86_64"
    bazel_url = "https://releases.bazel.build/9.0.0/release/" + bazel_name
    # The official checksum is also fetched; the reviewed digest remains authoritative.
    checksum = downloads / "bazel.sha256"
    run_command(["/usr/bin/curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
                 "--connect-timeout", "10", "--max-time", "30", "--max-filesize", "1024", "--silent",
                 "--show-error", "--output", str(checksum), bazel_url + ".sha256"], output, output,
                "download-bazel-checksum", environment, deadline, ())
    checksum_line = checksum.read_text().strip()
    expected_checksum = pin_string(pins, "bazel_darwin_x86_64_sha256") + "  " + bazel_name
    if checksum_line != expected_checksum:
        raise ValueError("Official Bazel checksum differs from the reviewed digest")
    bazel = downloads / bazel_name
    run_command(["/usr/bin/curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
                 "--connect-timeout", "10", "--max-time", "180", "--max-filesize", "100000000", "--silent",
                 "--show-error", "--output", str(bazel), bazel_url], output, output, "download-bazel",
                environment, deadline, ())
    if sha256_file(bazel) != pin_string(pins, "bazel_darwin_x86_64_sha256"):
        raise ValueError("Bazel binary digest mismatch")
    bazel.chmod(0o700)
    resource_names = [("swift-prebuilt-macos.tar.zst", "swift_prebuilt"),
                      ("resource-dir-macos.zip", "resource_dir_macos"),
                      ("PicoSHA2-27fcf6979298949e8a462e16d09a0351c18fcaf2.tar.zst", "picosha2")]
    for filename, key in resource_names:
        pointer = source / "swift/third_party/resources" / filename
        expected = f"version https://git-lfs.github.com/spec/v1\noid sha256:{pin_string(pins, key + '_sha256')}\nsize {pin_size(pins, key + '_bytes')}\n"
        if pointer.read_text() != expected:
            raise ValueError(f"Public LFS pointer differs from reviewed pins: {filename}")
        artifact = downloads / filename
        download("https://media.githubusercontent.com/media/github/codeql/" + commit + "/swift/third_party/resources/" + filename,
                 artifact, pin_string(pins, key + "_sha256"), pin_size(pins, key + "_bytes"), output,
                 "download-" + key, environment, deadline)
        if key != "swift_prebuilt":
            shutil.copy2(artifact, pointer)
    prebuilt_archive = downloads / "swift-prebuilt-macos.tar.zst"
    run_command(["/usr/bin/tar", "-tf", str(prebuilt_archive)], output, output,
                "list-prebuilt", environment, deadline, ())
    entries = (output / "logs/list-prebuilt.stdout").read_text().splitlines()
    if len(entries) != 4640 or any(PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts for name in entries):
        raise ValueError("Pinned compiler archive entry inventory differs from reviewed safe archive")
    run_command(["/usr/bin/tar", "-tvf", str(prebuilt_archive)], output, output,
                "inspect-prebuilt-types", environment, deadline, ())
    details = (output / "logs/inspect-prebuilt-types.stdout").read_text().splitlines()
    if len(details) != len(entries) or any(
        not re.match(r"[-d][rwx-]{9}\s", detail) or not detail.endswith(" " + name)
        for detail, name in zip(details, entries)
    ):
        raise ValueError("Compiler archive must contain only reviewed regular files and directories")
    original = output / "original-prebuilt"
    original.mkdir()
    # This exact digest was inspected: regular files/directories only, no links.
    run_command(["/usr/bin/tar", "-xf", str(prebuilt_archive), "-C", str(original), "--no-same-owner"],
                output, output, "extract-prebuilt", environment, deadline, ())
    if any(path.is_symlink() or not (path.is_file() or path.is_dir()) for path in original.rglob("*")):
        raise ValueError("Compiler archive extracted an unexpected special member")
    library = original / "libCodeQLSwiftFrontendTool.a"
    original_identity = {"sha256": sha256_file(library), "bytes": library.stat().st_size,
                         "mtime_ns": library.stat().st_mtime_ns}
    original_members = archive_members(library)
    if sum(row["name"] == "ImportMacro.cpp.o" for row in original_members) != 1:
        raise ValueError("Original compiler library has no unique importer object")
    swift_source = output / "swift-source/lib/ClangImporter"
    swift_source.mkdir(parents=True)
    for row in sources:
        path = swift_source / row["name"]
        download("https://raw.githubusercontent.com/swiftlang/swift/" + swift_commit + "/lib/ClangImporter/" + row["name"],
                 path, row["sha256"], row["bytes"], output, "download-swift-" + row["name"], environment, deadline)
        payload = path.read_bytes()
        if hashlib.sha1(b"blob " + str(len(payload)).encode("ascii") + b"\0" + payload).hexdigest() != row["git_blob"]:
            raise ValueError(f"Swift Git blob identity mismatch: {row['name']}")
    manifests: dict[str, list[PackageFile]] = {}
    closure_counts: dict[str, int] = {}
    for variant in ("B", "C"):
        variant_source = output / ("source-" + variant)
        importer = variant_source / "lib/ClangImporter/ImportMacro.cpp"
        importer.parent.mkdir(parents=True)
        shutil.copy2(swift_source / "ImportMacro.cpp", importer)
        if variant == "C":
            run_command(["/usr/bin/patch", "--dry-run", "-p1", "-i", str(patch)], variant_source,
                        output, "patch-dry-run", environment, deadline, ())
            run_command(["/usr/bin/patch", "-p1", "-i", str(patch)], variant_source, output,
                        "patch-candidate", environment, deadline, ())
            if sha256_file(importer) != "b4c2d12385e49ad4cc241844828bc1a5526eddf6edb4045ebb1379b928926659":
                raise ValueError("Patched importer source differs from the reviewed candidate")
        object_directory = output / ("object-" + variant)
        object_directory.mkdir()
        object_file = object_directory / "ImportMacro.cpp.o"
        compile_command = ["/usr/bin/xcrun", "clang++", "-std=c++20", "-fno-rtti", "-O2", "-DNDEBUG",
                           "-target", "x86_64-apple-macos13.0", "-isysroot", host["sdk"],
                           "-I", str(original / "include"), "-I", str(original / "stdlib/public/SwiftShims"),
                           "-I", str(swift_source), "-c", str(importer), "-o", str(object_file)]
        run_command(compile_command, output, output, "compile-object-" + variant, environment, deadline, ())
        prebuilt = output / ("prebuilt-" + variant)
        shutil.copytree(original, prebuilt)
        shutil.copy2(source / "swift/third_party/BUILD.swift-llvm-support.bazel", prebuilt / "BUILD.bazel")
        (prebuilt / "REPO.bazel").write_text("")
        run_command(["/usr/bin/xcrun", "ar", "-r", str(prebuilt / library.name), str(object_file)],
                    output, output, "replace-object-" + variant, environment, deadline, ())
        verify_replacement(original_members, archive_members(prebuilt / library.name), object_file)
        cache = output / ("bazel-" + variant)
        cache.mkdir()
        arguments = bazel_arguments(bazel, prebuilt, cache, host)
        query = ["cquery" if item == "run" else item for item in arguments]
        run_command(query + ["--output=label", "deps(//swift:install)"], source, output,
                    "closure-" + variant, environment, deadline, ())
        labels = (output / ("logs/closure-" + variant + ".stdout")).read_text().splitlines()
        if not labels or any("semmle_code" in label for label in labels):
            raise ValueError(f"Swift {variant} dependency closure is empty or includes an internal stub target")
        closure_counts[variant] = len(labels)
        pack = output / ("pack-" + variant)
        # Build events may include client environment fields. Never upload them.
        events = output / ("events/build-" + variant + ".json")
        run_command(arguments + ["--build_event_json_file=" + str(events), "//swift:install", "--", "--destdir=" + str(pack)],
                    source, output, "build-" + variant, environment, deadline, (events,))
        for name, command in [("file", ["/usr/bin/file", str(pack / "tools/osx64/extractor.real")]),
                              ("load-commands", ["/usr/bin/xcrun", "otool", "-l", str(pack / "tools/osx64/extractor.real")]),
                              ("dependencies", ["/usr/bin/xcrun", "otool", "-L", str(pack / "tools/osx64/extractor.real")])]:
            run_command(command, output, output, variant + "-" + name, environment, deadline, ())
        file_text = (output / ("logs/" + variant + "-file.stdout")).read_text()
        load_text = (output / ("logs/" + variant + "-load-commands.stdout")).read_text()
        if "Mach-O 64-bit executable x86_64" not in file_text or not re.search(r"LC_BUILD_VERSION\n\s+cmdsize \d+\n\s+platform 1\n\s+minos 13\.0", load_text):
            raise ValueError(f"Installed {variant} binary architecture/deployment is incorrect")
        dependencies = (output / ("logs/" + variant + "-dependencies.stdout")).read_text().splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" (compatibility version", 1)[0]
            if not dependency.startswith(("/usr/lib/", "/System/Library/Frameworks/", "@rpath/", "@loader_path/")):
                raise ValueError(f"Installed {variant} binary has an unexpected runtime library reference")
            if dependency.startswith(("@rpath/", "@loader_path/")):
                relative_library = PurePosixPath(dependency.split("/", 1)[1])
                if ".." in relative_library.parts or not (pack / "tools/osx64" / str(relative_library)).is_file():
                    raise ValueError(f"Installed {variant} binary has a missing packaged runtime library")
        manifests[variant] = package_manifest(pack)
        write_json(output / ("summary/pack-" + variant + ".json"), manifests[variant])
        write_json(output / ("summary/object-" + variant + ".json"), {
            "source_sha256": sha256_file(importer), "object_sha256": sha256_file(object_file),
            "archive_sha256": sha256_file(prebuilt / library.name), "closure_count": len(labels),
            "semmle_code_targets": [], "other_archive_members_identical": True})
    before = {row["path"]: row for row in manifests["B"]}
    after = {row["path"]: row for row in manifests["C"]}
    differences = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    if differences != ["tools/osx64/extractor.real"]:
        raise ValueError(f"Unexpected installed pack differences: {differences}")
    current_identity = {"sha256": sha256_file(library), "bytes": library.stat().st_size,
                        "mtime_ns": library.stat().st_mtime_ns}
    if current_identity != original_identity or sha256_file(prebuilt_archive) != pin_string(pins, "swift_prebuilt_sha256"):
        raise ValueError("Original compiler inputs changed")
    stub = source / "misc/bazel/semmle_code_stub"
    stub_files = {str(path.relative_to(stub)): path.read_text() for path in sorted(stub.rglob("*")) if path.is_file()}
    write_json(output / "summary.json", {"complete": True, "extraction_executed": False,
        "compiler_regression_tests_run": False, "experimental_only": True, "host": host,
        "pack_files": {variant: sum(row["type"] == "file" for row in rows) for variant, rows in manifests.items()},
        "pack_entries": {variant: len(rows) for variant, rows in manifests.items()},
        "pack_differences": differences, "independent_bazel_caches": True,
        "configured_closure_counts": closure_counts, "semmle_code_targets": [],
        "standalone_stub_files": stub_files,
        "standalone_stub_limits": "Unchanged public stub omits internal Linux glibc checks and Rust universal assembly; zero selected Swift targets depend on it. No vendor release or regression testing claimed.",
        "original_compiler_preserved": True,
        "compiler_original_sha256": original_identity["sha256"],
        "B": before["tools/osx64/extractor.real"], "C": after["tools/osx64/extractor.real"]})
    shutil.copy2(output / "summary.json", output / "summary/status.json")


def cancel_command(signum: int, frame: FrameType | None) -> None:
    raise InterruptedError(f"Build cancelled by signal {signum}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New ignored directory beneath the checkout")
    arguments = parser.parse_args()
    if not arguments.output.is_absolute() or arguments.output.is_symlink():
        raise ValueError("Output must be an absolute path without an existing symlink")
    output = arguments.output.resolve()
    host = host_information()
    signal.signal(signal.SIGTERM, cancel_command)
    build(output, Path(__file__).resolve().parent, host)
    print("Experimental control/candidate packs built and statically verified; no extraction executed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"Compiler candidate build failed: {error}", file=sys.stderr)
        sys.exit(1)
