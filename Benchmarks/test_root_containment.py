#!/usr/bin/env python3
"""Check saved selected-root containment with real manual discovery and indexing."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit


SOURCE_MAN = Path("/usr/share/man/man1")


def run(binary: Path, arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=120, check=False)


def file_path(value: str) -> str:
    parts = urlsplit(value)
    if parts.scheme != "file" or parts.netloc not in ("", "localhost"):
        raise ValueError(f"Expected a local file URL: {value}")
    return str(Path(unquote(parts.path)))


def verify(output: Path, nested: Path, outer: Path, outside: Path) -> None:
    checkpoint = json.loads((output / "checkpoint.json").read_text(encoding="utf-8"))
    roots = [file_path(value) for value in checkpoint["plan"]["roots"]]
    boundary = [file_path(value) for value in checkpoint["plan"]["traversalRoots"]]
    assert roots == boundary == [str(nested), str(outer)]
    assert not any(str(outside) in value for value in boundary)

    result = json.loads((output / "result.json").read_text(encoding="utf-8"))
    assert result["state"] == "completed" and result["pendingLocations"] == 0
    assert result["indexFailed"] == 0 and result["indexedManuals"] == 2

    inventory = json.loads((output / "inventory.json").read_text(encoding="utf-8"))
    pages = inventory["pages"]
    assert len(pages) == 2
    sources = {file_path(location["source"]) for page in pages for location in page["locations"]}
    assert sources == {
        str(outer / "man1/ls.1"),
        str(outer / "man1/inside_alias.1"),
        str(outer / "man1/relative_alias.1"),
        str(nested / "man1/cat.1"),
    }, sources
    coverage = inventory["coverage"]
    measured = [record for record in coverage if file_path(record["root"]) in roots]
    assert len(measured) == 2 and all(record["completed"] for record in measured)
    issues = [issue for record in coverage for issue in record["issues"]]
    for path in [outer / "outside_link", outer / "man1/outside_link.1",
                 outer / "man1/outside_alias.1", outer / "man1/outside_missing_alias.1"]:
        assert any(issue["path"] == str(path) and issue["kind"] == "excluded"
                   and "Path leaves the selected scan roots" in issue["reason"] for issue in issues), path
    assert any(issue["path"] == str(nested) and issue["kind"] == "excluded"
               and issue.get("directoryReference") for issue in issues)

    with sqlite3.connect(output / "search.sqlite") as index:
        assert index.execute("PRAGMA integrity_check").fetchone() == ("ok",)


def verify_legacy_resume(binary: Path, output: Path, owned: Path) -> None:
    legacy = owned / "legacy-unconfined"
    shutil.copytree(output, legacy)
    checkpoint = legacy / "checkpoint.json"
    saved = json.loads(checkpoint.read_text(encoding="utf-8"))
    saved["plan"].pop("traversalRoots")
    clock = {key: saved.get(key) for key in ["bootReference", "bootReferenceClock"]}
    checkpoint.write_text(json.dumps(saved, sort_keys=True), encoding="utf-8")
    retained = {name: hashlib.sha256((legacy / name).read_bytes()).hexdigest()
                for name in ["checkpoint.json", "inventory.json", "search.sqlite"]}
    rejected = run(binary, ["resume", "--output", str(legacy), "--cancel-seconds", "0",
                            "--telemetry", "disabled", "--cache-state", "unknown", "--stay-within-roots"])
    assert rejected.returncode == 1
    assert all(hashlib.sha256((legacy / name).read_bytes()).hexdigest() == digest
               for name, digest in retained.items())
    resumed = run(binary, ["resume", "--output", str(legacy), "--cancel-seconds", "0",
                           "--telemetry", "disabled", "--cache-state", "unknown"])
    if resumed.returncode != 0:
        raise RuntimeError(f"Legacy unconfined resume exited {resumed.returncode}: {resumed.stderr[-1200:]}")
    loaded = json.loads(checkpoint.read_text(encoding="utf-8"))
    assert "traversalRoots" not in loaded["plan"]
    assert {key: loaded.get(key) for key in clock} == clock
    with sqlite3.connect(legacy / "search.sqlite") as index:
        assert index.execute("PRAGMA integrity_check").fetchone() == ("ok",)


def verify_selected_symlink_root(binary: Path, outer: Path, baseline: Path, owned: Path) -> None:
    alias = owned / "selected-root-alias"
    alias.symlink_to(outer, target_is_directory=True)
    output = owned / "selected-alias-output"
    scan = run(binary, ["scan", "--root", str(alias), "--output", str(output),
                        "--cancel-seconds", "0", "--telemetry", "disabled", "--cache-state", "unknown",
                        "--stay-within-roots"])
    if scan.returncode != 0:
        raise RuntimeError(f"Selected symlink root scan exited {scan.returncode}: {scan.stderr[-1200:]}")
    result = json.loads((output / "result.json").read_text(encoding="utf-8"))
    assert result["state"] == "completed" and result["pendingLocations"] == 0
    assert result["indexedManuals"] == 2 and result["indexFailed"] == 0
    checkpoint = json.loads((output / "checkpoint.json").read_text(encoding="utf-8"))
    assert [file_path(value) for value in checkpoint["plan"]["roots"]] == [str(alias)]
    inventory = json.loads((output / "inventory.json").read_text(encoding="utf-8"))
    expected = json.loads((baseline / "inventory.json").read_text(encoding="utf-8"))
    assert {(page["fingerprint"], page["section"], page["language"]) for page in inventory["pages"]} == {
        (page["fingerprint"], page["section"], page["language"]) for page in expected["pages"]}
    sources = {Path(file_path(location["source"])).resolve()
               for page in inventory["pages"] for location in page["locations"]}
    assert sources == {(outer / name).resolve() for name in ["man1/ls.1", "man1/inside_alias.1",
                                                            "man1/relative_alias.1", "nested/man1/cat.1"]}
    issues = [issue for record in inventory["coverage"] for issue in record["issues"]]
    for name in ["outside_link", "man1/outside_link.1", "man1/outside_alias.1", "man1/outside_missing_alias.1"]:
        assert any(issue["path"] == str(alias / name) and issue["kind"] == "excluded" for issue in issues), name
    with sqlite3.connect(output / "search.sqlite") as index:
        assert index.execute("PRAGMA integrity_check").fetchone() == ("ok",)


def main(arguments: list[str]) -> int:
    if len(arguments) != 1:
        raise ValueError("Usage: test_root_containment.py /absolute/path/to/discovery-benchmark")
    binary = Path(arguments[0])
    if not binary.is_absolute() or not binary.is_file():
        raise ValueError("Provide an existing absolute discovery-benchmark binary")
    for name in ["ls.1", "cat.1", "date.1"]:
        if not (SOURCE_MAN / name).is_file():
            raise FileNotFoundError(SOURCE_MAN / name)

    owned = Path(tempfile.mkdtemp(prefix="manpages-root-containment-"))
    try:
        outer = owned / "external"
        nested = outer / "nested"
        outside = owned / "internal"
        (outer / "man1").mkdir(parents=True)
        (nested / "man1").mkdir(parents=True)
        outside.mkdir()
        shutil.copyfile(SOURCE_MAN / "ls.1", outer / "man1/ls.1")
        shutil.copyfile(SOURCE_MAN / "cat.1", nested / "man1/cat.1")
        shutil.copyfile(SOURCE_MAN / "date.1", outside / "date.1")
        (outer / "outside_link").symlink_to(outside, target_is_directory=True)
        (outer / "man1/outside_link.1").symlink_to(outside / "date.1")
        (outer / "man1/outside_alias.1").write_text(f".so {outside / 'date.1'}\n", encoding="utf-8")
        (outer / "man1/outside_missing_alias.1").write_text(f".so {outside / 'missing.1'}\n", encoding="utf-8")
        (outer / "man1/inside_alias.1").write_text(f".so {nested / 'man1/cat.1'}\n", encoding="utf-8")
        (outer / "man1/relative_alias.1").write_text(".so ../man1/ls.1\n", encoding="utf-8")

        output = owned / "result"
        scan = run(binary, ["scan", "--root", str(nested), "--root", str(outer), "--output", str(output),
                            "--cancel-seconds", "0", "--telemetry", "enabled", "--cache-state", "unknown",
                            "--stay-within-roots"])
        if scan.returncode != 0:
            raise RuntimeError(f"Confined scan exited {scan.returncode}: {scan.stderr[-1200:]}")
        verify(output, nested, outer, outside)
        saved = hashlib.sha256((output / "checkpoint.json").read_bytes()).hexdigest()
        rejected = run(binary, ["resume", "--output", str(output), "--cancel-seconds", "0",
                                "--telemetry", "enabled", "--cache-state", "unknown", "--stay-within-roots"])
        assert rejected.returncode == 1
        assert hashlib.sha256((output / "checkpoint.json").read_bytes()).hexdigest() == saved
        resumed = run(binary, ["resume", "--output", str(output), "--cancel-seconds", "0",
                               "--telemetry", "enabled", "--cache-state", "unknown"])
        if resumed.returncode != 0:
            raise RuntimeError(f"Confined resume exited {resumed.returncode}: {resumed.stderr[-1200:]}")
        verify(output, nested, outer, outside)

        invalid = owned / "invalid-saved-scope"
        shutil.copytree(output, invalid)
        invalid_checkpoint = invalid / "checkpoint.json"
        changed = json.loads(invalid_checkpoint.read_text(encoding="utf-8"))
        changed["plan"]["traversalRoots"] = [outside.as_uri()]
        invalid_checkpoint.write_text(json.dumps(changed, sort_keys=True), encoding="utf-8")
        retained = {name: hashlib.sha256((invalid / name).read_bytes()).hexdigest()
                    for name in ["checkpoint.json", "inventory.json", "search.sqlite"]}
        refusal = run(binary, ["resume", "--output", str(invalid), "--cancel-seconds", "0",
                               "--telemetry", "enabled", "--cache-state", "unknown"])
        assert refusal.returncode == 1
        assert all(hashlib.sha256((invalid / name).read_bytes()).hexdigest() == digest
                   for name, digest in retained.items())
        verify_legacy_resume(binary, output, owned)
        verify_selected_symlink_root(binary, outer, output, owned)
        print("Selected-root containment passed: nested-root ownership, two indexed manuals, classified existing and missing alias escapes, relative alias alternative, valid SQLite, saved-scope resume, byte-preserving invalid-scope refusal, and legacy resume without invented containment or clock changes.")
    except Exception:
        print(f"Retained failed root-containment fixture and reports at {owned}", file=sys.stderr)
        raise
    shutil.rmtree(owned)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
