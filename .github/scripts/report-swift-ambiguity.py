#!/usr/bin/env python3
"""Retain compiler-only ambiguity evidence; never export argv, environment or databases."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys
from typing import TypedDict


class DiagnosticInputError(ValueError):
    """Required extractor evidence is absent, malformed or exceeds its bounds."""


class Diagnostic(TypedDict):
    level: str
    location: str
    line: int
    column: int
    message: str


class Invocation(TypedDict):
    module: str
    target: str
    sdk: str
    candidateNoteCount: int
    diagnostics: list[Diagnostic]


COMPILER = re.compile(r"\b(ERRO|DEBG|INFO|WARN) \[extractor/compiler\] (.+) \(SwiftDiagnosticsConsumer\.cpp:[1-9][0-9]*\)$")
LOCATION = re.compile(r"(.+):([0-9]{1,10}):([0-9]{1,10}) (.+)")
AMBIGUITY = "reference to 'NSAccessibilityElement' is ambiguous"


def metadata(pattern: str, command: str, name: str) -> str:
    values: list[str] = re.findall(pattern, command)
    if len(values) != 1:
        raise DiagnosticInputError(f"Failing invocation needs exactly one validated {name}")
    return values[0]


def position(value: str) -> int:
    result: int = int(value)
    if result > 2**32 - 1:
        raise DiagnosticInputError("Compiler location exceeds the UInt32 range")
    return result


def normalized_location(location: str, workspace: Path) -> str:
    """Keep public relative source identity; label unavailable or other locations explicitly."""
    if location == "<invalid loc>":
        return location
    sdk: re.Match[str] | None = re.fullmatch(r"/Applications/Xcode_[0-9.]+\.app/Contents/Developer/Platforms/MacOSX\.platform/Developer/SDKs/(MacOSX[0-9.]*\.sdk)/([A-Za-z0-9_./+ -]+)", location)
    if sdk is not None and ".." not in Path(sdk[2]).parts:
        return "<sdk>/" + sdk[1] + "/" + sdk[2]
    source: Path = Path(location)
    if source.is_absolute() and source.is_relative_to(workspace) and ".." not in source.parts:
        return "<repository>/" + str(source.relative_to(workspace))
    return "<outside-repository-and-sdk>"


def summarize(text: str, workspace: Path) -> Invocation | None:
    lines: list[str] = text.splitlines()
    if len(lines) > 100_000 or any(len(line.encode("utf-8")) > 256 * 1024 for line in lines):
        raise DiagnosticInputError("Extractor log exceeds line bounds")
    diagnostics: list[Diagnostic] = []
    following_error: bool = False
    for line in lines:
        match: re.Match[str] | None = COMPILER.search(line)
        if match is None:
            continue
        level: str = match[1]
        payload: re.Match[str] | None = LOCATION.fullmatch(match[2])
        if payload is None:
            raise DiagnosticInputError("Compiler diagnostic lacks a location record")
        if level != "DEBG":
            following_error = level == "ERRO" and payload[4] == AMBIGUITY
        if not following_error:
            continue
        if len(payload[4].encode("utf-8")) > 4096 or len(diagnostics) >= 32:
            raise DiagnosticInputError("Ambiguity diagnostics exceed report bounds")
        diagnostics.append(Diagnostic(level=level, location=normalized_location(payload[1], workspace),
                                      line=position(payload[2]), column=position(payload[3]), message=payload[4]))
    if not diagnostics:
        return None
    commands: list[str] = [line for line in lines if "[extractor/main] calling extractor with arguments \"" in line]
    if len(commands) != 1:
        raise DiagnosticInputError("Failing extractor log needs exactly one invocation record")
    command: str = commands[0]
    return Invocation(
        module=metadata(r'-module-name\s+([A-Za-z_][A-Za-z0-9_]{0,127})(?=\s|")', command, "module"),
        target=metadata(r'-target\s+((?:x86_64|arm64)-apple-macosx?[0-9.]+)(?=\s|")', command, "target"),
        sdk=metadata(r'-sdk\s+[^\s"]*/(MacOSX[0-9.]*\.sdk)(?=\s|")', command, "SDK"),
        candidateNoteCount=sum(item["level"] == "DEBG" for item in diagnostics),
        diagnostics=diagnostics,
    )


def report(directory: Path, workspace: Path, output: Path) -> None:
    """Validate bounded regular logs and write only selected compiler evidence without overwriting."""
    if directory.is_symlink() or not directory.is_dir():
        raise DiagnosticInputError("Swift invocation log directory is missing or is a symbolic link")
    logs: list[Path] = sorted(directory.glob("*.log"))
    if not 1 <= len(logs) <= 500:
        raise DiagnosticInputError("Expected between 1 and 500 Swift invocation logs")
    invocations: list[Invocation] = []
    total_bytes: int = 0
    for path in logs:
        if re.fullmatch(r"[0-9]+-[0-9]+\.log", path.name) is None or path.is_symlink() or not path.is_file():
            raise DiagnosticInputError("Invocation log must be a regular file without a symbolic link")
        with path.open("rb") as source:
            data: bytes = source.read(20 * 1024 * 1024 + 1)
        total_bytes += len(data)
        if len(data) > 20 * 1024 * 1024 or total_bytes > 80 * 1024 * 1024:
            raise DiagnosticInputError("Swift invocation logs exceed byte bounds")
        invocation: Invocation | None = summarize(data.decode("utf-8"), workspace)
        if invocation is not None:
            invocations.append(invocation)
    if not invocations:
        raise DiagnosticInputError("No NSAccessibilityElement ambiguity records found; strict SARIF gate remains failed")
    encoded: str = json.dumps({"examinedLogCount": len(logs), "invocations": invocations}, sort_keys=True, indent=2) + "\n"
    if len(encoded.encode("utf-8")) > 64 * 1024:
        raise DiagnosticInputError("Compiler report exceeds output bounds")
    with output.open("x", encoding="utf-8") as destination:
        destination.write(encoded)
    print(encoded, end="")


def main(arguments: list[str]) -> None:
    if len(arguments) != 3:
        raise DiagnosticInputError("Expected log directory, repository root and report output path")
    report(Path(arguments[0]), Path(arguments[1]), Path(arguments[2]))


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (DiagnosticInputError, OSError, UnicodeError) as error:
        print(f"Swift ambiguity report failed ({type(error).__name__}); "
              + (str(error) if isinstance(error, DiagnosticInputError) else "cannot read bounded UTF-8 logs or create the owned output; inspect runner paths and permissions"), file=sys.stderr)
        sys.exit(1)
