#!/usr/bin/env python3
"""Exercise the production CLI's mounted-volume exclusion on an isolated manual tree."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit


EXCLUDED_MOUNT = Path("/System/Volumes/VM")
MISSING_EXCLUDED_MANUAL = EXCLUDED_MOUNT / "manpagescatalog-scoped-fixture-unmounted-target.1"
SOURCE_MANUAL = Path("/usr/share/man/man1/ls.1")


def object_at(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object at {path}")
    return value


def local_path(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError(f"Expected a file URL, got {type(value).__name__}")
    parsed = urlsplit(value)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        raise ValueError(f"Expected a local file URL, got {value}")
    return str(Path(unquote(parsed.path)))


def run_cli(binary: Path, arguments: list[str]) -> None:
    result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=120, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"Discovery CLI exited {result.returncode}: {result.stderr[-1200:]}")


def verify_whole_plan_without_scanning(binary: Path, existing_output: Path) -> None:
    result = subprocess.run([str(binary), "whole-filesystem", "--output", str(existing_output),
                             "--cancel-seconds", "0", "--telemetry", "disabled", "--cache-state", "unknown",
                             "--exclude-mounted-volume", str(EXCLUDED_MOUNT)],
                            capture_output=True, text=True, timeout=30, check=False)
    if result.returncode != 1 or "Fresh scan output already exists" not in result.stderr:
        raise AssertionError(f"Scoped whole-filesystem plan did not reach the no-scan output guard: {result.stderr[-1200:]}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify_scope(output: Path, fixture: Path, volume_alias: Path, manual_alias: Path,
                 missing_alias: Path, output_alias: Path) -> tuple[tuple[str, ...], str]:
    checkpoint = object_at(output / "checkpoint.json")
    plan = checkpoint.get("plan")
    require(isinstance(plan, dict), "Checkpoint is missing its saved plan")
    roots = plan.get("roots")
    require(isinstance(roots, list), "Checkpoint plan has no root array")
    require([local_path(root) for root in roots] == [str(fixture)], "Selected-root scope changed")
    raw_exclusions = plan.get("traversalExclusions")
    require(isinstance(raw_exclusions, list), "Checkpoint plan has no traversal exclusions")
    exclusions = tuple(issue.get("path") for issue in raw_exclusions if isinstance(issue, dict))
    require(str(EXCLUDED_MOUNT) in exclusions, "Mounted-volume exclusion was not saved")
    require(str(output) in exclusions, "Owned output exclusion was not saved")

    result = object_at(output / "result.json")
    require(result.get("state") == "completed" and result.get("pendingLocations") == 0,
            "Scoped fixture traversal did not complete")
    require(result.get("indexedManuals") == 1 and result.get("indexFailed") == 0,
            "Fixture manual was not indexed successfully")
    inventory = object_at(output / "inventory.json")
    pages = inventory.get("pages")
    require(isinstance(pages, list) and len(pages) == 1, "Expected exactly one discovered fixture manual")
    coverage = inventory.get("coverage")
    require(isinstance(coverage, list), "Inventory is missing coverage records")
    issues = [issue for source in coverage if isinstance(source, dict)
              for issue in source.get("issues", []) if isinstance(issue, dict)]
    for path in [str(EXCLUDED_MOUNT), str(volume_alias), str(manual_alias), str(missing_alias)]:
        require(any(issue.get("path") == path and issue.get("kind") == "excluded"
                    and "Explicitly excluded mounted volume" in str(issue.get("reason")) for issue in issues),
                f"Missing classified excluded-volume gap for {path}")
    require(any(issue.get("path") == str(output_alias) and issue.get("kind") == "excluded"
                and "Harness-owned measurement output" in str(issue.get("reason")) for issue in issues),
            f"Missing classified output-alias gap for {output_alias}")
    fingerprint = ""
    for page in pages:
        require(isinstance(page, dict), "Manual page entry must be an object")
        value = page.get("fingerprint")
        if not isinstance(value, str) or len(value) != 64:
            raise AssertionError("Manual fingerprint is missing")
        fingerprint = value
        locations = page.get("locations")
        require(isinstance(locations, list), "Manual page has no source locations")
        for location in locations:
            require(isinstance(location, dict), "Manual location must be an object")
            source = local_path(location.get("source"))
            require(source == str(fixture / "ls.1"), f"Unexpected manual source: {source}")
    with sqlite3.connect(output / "search.sqlite") as index:
        require(index.execute("PRAGMA integrity_check").fetchone() == ("ok",), "SQLite index integrity failed")
    return exclusions, fingerprint


def main(arguments: list[str]) -> int:
    if len(arguments) != 1:
        raise ValueError("Usage: test_scoped_discovery.py /absolute/path/to/discovery-benchmark")
    binary = Path(arguments[0])
    require(binary.is_absolute() and binary.is_file(), "Provide an existing absolute CLI binary path")
    require(os.path.ismount(EXCLUDED_MOUNT), f"Required system volume is not mounted: {EXCLUDED_MOUNT}")
    require(not MISSING_EXCLUDED_MANUAL.exists(), f"Expected missing excluded target exists: {MISSING_EXCLUDED_MANUAL}")
    require(SOURCE_MANUAL.is_file(), f"Required local fixture manual is missing: {SOURCE_MANUAL}")
    owned = Path(tempfile.mkdtemp(prefix="manpages-scoped-discovery-"))
    try:
        verify_whole_plan_without_scanning(binary, owned)
        fixture = owned / "manuals"
        fixture.mkdir()
        shutil.copyfile(SOURCE_MANUAL, fixture / "ls.1")
        volume_alias = fixture / "mounted-volume-link"
        volume_alias.symlink_to(EXCLUDED_MOUNT, target_is_directory=True)
        manual_alias = fixture / "mounted-manual-alias.1"
        manual_alias.write_text(f".so {EXCLUDED_MOUNT}\n", encoding="utf-8")
        missing_alias = fixture / "missing-mounted-manual-alias.1"
        missing_alias.write_text(f".so {MISSING_EXCLUDED_MANUAL}\n", encoding="utf-8")
        output = owned / "result"
        output_alias = fixture / "output-manual-alias.1"
        output_alias.write_text(f".so {output / 'not-yet-written.1'}\n", encoding="utf-8")
        run_cli(binary, ["scan", "--root", str(fixture), "--output", str(output),
                         "--cancel-seconds", "0", "--telemetry", "enabled", "--cache-state", "unknown",
                         "--exclude-mounted-volume", str(EXCLUDED_MOUNT)])
        before = verify_scope(output, fixture, volume_alias, manual_alias, missing_alias, output_alias)
        run_cli(binary, ["resume", "--output", str(output), "--cancel-seconds", "0",
                         "--telemetry", "enabled", "--cache-state", "unknown"])
        after = verify_scope(output, fixture, volume_alias, manual_alias, missing_alias, output_alias)
        require(after == before, "Resume changed the saved mounted-volume exclusions")
        print("Scoped mounted-volume CLI integration passed: one indexed fixture manual, five classified exclusions including missing mount and output alias targets, zero pending paths, valid SQLite, saved-scope resume.")
    except Exception:
        print(f"Retained failed scoped-discovery fixture and reports at {owned}", file=sys.stderr)
        raise
    shutil.rmtree(owned)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
