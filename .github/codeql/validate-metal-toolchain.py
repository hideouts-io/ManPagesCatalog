#!/usr/bin/env python3
"""Validate installed Metal metadata and its physical tool paths before CodeQL tracing."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import pwd
import re
import sys
from typing import Mapping, NamedTuple


Component = NamedTuple("Component", [("identifier", str), ("path", str)])


def safe_text(value: object) -> str:
    if isinstance(value, str) and len(value) <= 1024:
        return value
    return "type:string-over-1024" if isinstance(value, str) else "type:" + type(value).__name__


def write_evidence(path: Path, value: Mapping[str, object]) -> None:
    output = (json.dumps(dict(value), indent=2, sort_keys=True) + "\n").encode("utf-8")
    if len(output) > 65536:
        raise ValueError("Safe Metal evidence exceeds the 64 KiB output bound")
    path.write_bytes(output)


def read_component(path: Path, evidence: Path, show_status: int) -> tuple[dict[str, object], str | None]:
    """Record consumed fields even when the vendor command or its JSON fails."""
    document: object = None
    failure: str | None = None
    root_type = "invalid-or-oversize-json"
    with path.open("rb") as source:
        payload = source.read(65537)
    if len(payload) > 65536:
        failure = "Metal component metadata exceeds the 64 KiB input bound"
    else:
        try:
            document = json.loads(payload)
            root_type = type(document).__name__
        except (json.JSONDecodeError, UnicodeDecodeError):
            failure = "Metal component metadata is not valid JSON"
    record: dict[str, object] = {}
    if isinstance(document, dict):
        record = {key: value for key, value in document.items() if isinstance(key, str)}
    elif failure is None:
        failure = "Metal component metadata must be a JSON object"
    keys: list[str] = sorted(record)
    write_evidence(evidence / "component.json", {
        "show_component_exit_status": show_status,
        "root_type": root_type,
        "root_key_count": len(keys),
        "root_keys": [key if len(key) <= 128 else "type:key-over-128" for key in keys[:64]],
        "status": safe_text(record.get("status")),
        "toolchainIdentifier": safe_text(record.get("toolchainIdentifier")),
        "toolchainSearchPath": safe_text(record.get("toolchainSearchPath")),
    })
    return record, failure


def validate_component(record: Mapping[str, object]) -> Component:
    if record.get("status") != "installed":
        raise ValueError("Metal status must be installed; inspect metal-evidence/component.json")
    identifier = record.get("toolchainIdentifier")
    if not isinstance(identifier, str) or len(identifier) > 1024 or re.fullmatch(
            r"com\.apple\.dt\.toolchain\.Metal\.[A-Za-z0-9.]+", identifier) is None:
        raise ValueError("Metal identifier failed its required string/pattern validation")
    path = record.get("toolchainSearchPath")
    if not isinstance(path, str):
        raise ValueError("Metal search path must be a string")
    return Component(identifier, path)


def absolute_path(value: str) -> Path:
    if not value.startswith("/") or len(value) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("Metal path must be absolute, bounded, and free of control characters")
    if any(part in ("", ".", "..") for part in value.split("/")[1:]):
        raise ValueError("Metal path must not contain empty, dot, or parent components")
    return Path(value)


def installation_kind(path: Path, home: Path) -> str:
    if path.parent == Path("/private/var/run/com.apple.security.cryptexd/mnt") and re.fullmatch(
            r"[-A-Za-z0-9._]+", path.name) is not None and path.name not in (".", ".."):
        return "cryptex-mount"
    if path.parent == home / "Library/Developer/DVTDownloads/MetalToolchain/mounts" and re.fullmatch(
            r"[0-9a-f]{40}", path.name) is not None:
        return "dvt-user-mount"
    raise ValueError("Metal search path is outside the required installation roots or has an invalid mount leaf")


def resolve_component(component: Component, home: Path, evidence: Path) -> Path:
    """Keep the same installation kind and leaf through canonicalization; contain both tools."""
    details: dict[str, object] = {"raw_search_path": safe_text(component.path),
                                  "authoritative_home": safe_text(str(home)),
                                  "effective_uid": os.geteuid()}
    try:
        raw = absolute_path(component.path)
        raw_home = absolute_path(str(home))
        kind = installation_kind(raw, raw_home)
        details["root_kind"] = kind
        canonical_home = raw_home.resolve(strict=True)
        canonical = raw.resolve(strict=True)
        details["canonical_home"] = safe_text(str(canonical_home))
        details["canonical_search_path"] = safe_text(str(canonical))
        absolute_path(str(canonical_home))
        absolute_path(str(canonical))
        if not canonical_home.is_dir() or not canonical.is_dir():
            raise ValueError("Metal installation and authoritative home must be existing directories")
        if installation_kind(canonical, canonical_home) != kind or canonical.name != raw.name:
            raise ValueError("Metal canonical path changes its installation kind or mount leaf")
        for tool in ("metal", "metallib"):
            physical = (canonical / "Metal.xctoolchain/usr/bin" / tool).resolve(strict=True)
            details[tool + "_physical_path"] = safe_text(str(physical))
            absolute_path(str(physical))
            if canonical not in physical.parents or not physical.is_file():
                raise ValueError(f"Metal tool {tool} escapes its validated mount or is not a regular file")
        return canonical
    finally:
        write_evidence(evidence / "resolved-paths.json", details)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component_json", type=Path)
    parser.add_argument("evidence_directory", type=Path)
    parser.add_argument("show_component_exit_status", type=int)
    arguments = parser.parse_args()
    show_status: int = arguments.show_component_exit_status
    if not 0 <= show_status <= 255:
        raise ValueError("showComponent exit status must be between 0 and 255")
    record, failure = read_component(arguments.component_json, arguments.evidence_directory, show_status)
    if show_status != 0:
        print(f"xcodebuild -showComponent MetalToolchain failed with exit {show_status}; inspect safe component metadata.", file=sys.stderr)
        raise SystemExit(show_status)
    if failure is not None:
        raise ValueError(failure)
    component = validate_component(record)
    home = Path(pwd.getpwuid(os.geteuid()).pw_dir)
    canonical = resolve_component(component, home, arguments.evidence_directory)
    print(json.dumps({"identifier": component.identifier, "search_path": str(canonical)}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, RuntimeError) as error:
        print(f"Metal metadata/path validation failed: {error}; inspect metal-evidence.", file=sys.stderr)
        raise SystemExit(1) from error
