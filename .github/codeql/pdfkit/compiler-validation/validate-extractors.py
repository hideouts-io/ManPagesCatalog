#!/usr/bin/env python3
"""Compare fixed released/control/patched extractors on public, fresh CI fixtures.

This is supported-host diagnostic acceptance, not the application's security gate.
The installed CodeQL bundle is read and hashed, never replaced or configured globally.
"""

from __future__ import annotations

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from typing import Mapping, NamedTuple, Optional, Sequence
from urllib.parse import unquote


Lane = NamedTuple("Lane", [("name", str), ("pack", Path), ("index", int)])
Case = NamedTuple("Case", [("name", str), ("source", Path), ("header", Optional[Path]), ("modulemap", Optional[Path]),
                         ("flags", tuple[str, ...]), ("native_exit", int),
                         ("counts", tuple[int, int, int]), ("message", Optional[str])])
Result = NamedTuple("Result", [("lane", str), ("case", str), ("notifications", int)])


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def object_value(value: object, context: str) -> dict[str, object]:
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise ValueError(f"{context} must be a JSON object with string keys")
    return {key: item for key, item in value.items()}


def array_value(value: object, context: str) -> list[object]:
    if not isinstance(value, list):
        raise ValueError(f"{context} must be a JSON array")
    return [item for item in value]


def text_value(value: object, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context} must be a nonempty string")
    return value


def read_json(path: Path) -> object:
    value: object = json.loads(path.read_text(encoding="utf-8"))
    return value


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def tree_digest(path: Path) -> str:
    digest = hashlib.sha256()
    for entry in sorted(path.rglob("*")):
        relative = entry.relative_to(path).as_posix()
        if entry.is_symlink():
            payload = "link:" + os.readlink(entry)
        elif entry.is_file():
            payload = "file:" + digest_file(entry)
        else:
            continue
        digest.update((relative + "\0" + payload + "\n").encode())
    return digest.hexdigest()


def run(command: Sequence[str], cwd: Path, log: Path, environment: Mapping[str, str],
        deadline: float, timeout: int) -> int:
    """Record only arguments and output, with a deadline for the owned process group."""
    remaining = min(float(timeout), deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError("The differential validation deadline expired")
    log.parent.mkdir(parents=True, exist_ok=True)
    write_json(log.with_suffix(".command.json"), list(command))
    started = time.monotonic()
    with log.open("wb") as output, log.with_suffix(".stderr.log").open("wb") as errors:
        process = subprocess.Popen(list(command), cwd=cwd, env=dict(environment),
                                   stdin=subprocess.DEVNULL, stdout=output,
                                   stderr=errors, start_new_session=True)
        try:
            status = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as cause:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            write_json(log.with_suffix(".status.json"), {"timed_out": True,
                       "seconds": round(time.monotonic() - started, 3)})
            raise TimeoutError(f"Command exceeded its deadline; inspect {log}") from cause
    write_json(log.with_suffix(".status.json"), {"exit_status": status,
               "seconds": round(time.monotonic() - started, 3), "timed_out": False})
    return status


def require_command(command: Sequence[str], cwd: Path, log: Path,
                    environment: Mapping[str, str], deadline: float, timeout: int) -> None:
    status = run(command, cwd, log, environment, deadline, timeout)
    if status != 0:
        raise RuntimeError(f"Required command exited {status}; inspect {log}")


def sarif_evidence(path: Path) -> tuple[list[dict[str, object]], set[str]]:
    document = object_value(read_json(path), "SARIF")
    runs = array_value(document.get("runs"), "SARIF runs")
    if not runs:
        raise ValueError("SARIF runs must not be empty")
    errors: list[dict[str, object]] = []
    sources: set[str] = set()
    for run_value in runs:
        run_record = object_value(run_value, "SARIF run")
        invocations = array_value(run_record.get("invocations"), "SARIF invocations")
        if not invocations:
            raise ValueError("SARIF invocations must not be empty")
        for invocation_value in invocations:
            invocation = object_value(invocation_value, "SARIF invocation")
            if invocation.get("executionSuccessful") is not True:
                raise ValueError("CodeQL SARIF does not confirm successful analysis execution")
            notifications = array_value(invocation.get("toolExecutionNotifications"), "SARIF notifications")
            for notification_value in notifications:
                notification = object_value(notification_value, "SARIF notification")
                descriptor = object_value(notification.get("descriptor"), "notification descriptor")
                identifier = text_value(descriptor.get("id"), "notification descriptor id")
                if identifier == "swift/diagnostics/extraction-errors":
                    message = object_value(notification.get("message"), "compiler diagnostic message")
                    text_value(message.get("text"), "compiler diagnostic text")
                    errors.append(notification)
                if identifier == "swift/diagnostics/successfully-extracted-files" and "locations" in notification:
                    for location_value in array_value(notification["locations"], "extracted source locations"):
                        location = object_value(location_value, "source location")
                        physical = object_value(location.get("physicalLocation"), "physical source location")
                        artifact = object_value(physical.get("artifactLocation"), "source artifact")
                        sources.add(Path(unquote(text_value(artifact.get("uri"), "source URI"))).name)
    return errors, sources


def csv_rows(path: Path, columns: int) -> Counter[tuple[str, ...]]:
    with path.open(newline="", encoding="utf-8") as source:
        rows = list(csv.reader(source))
    if not rows or any(len(row) != columns for row in rows):
        raise ValueError(f"Semantic CSV has an absent header or unexpected column count: {path}")
    return Counter(tuple(row) for row in rows[1:])


def verify_resolution(cli: Path, lane: Lane, output: Path, environment: Mapping[str, str],
                      deadline: float) -> None:
    log = output / "logs" / f"resolve-{lane.name}.log"
    require_command((str(cli), "resolve", "extractor", "--language=swift", "--format=json",
                     f"--search-path={lane.pack}"), output, log, environment, deadline, 60)
    actual = Path(text_value(read_json(log), "resolved extractor root")).resolve(strict=True)
    if actual != lane.pack:
        raise RuntimeError(f"Lane {lane.name} resolved the wrong extractor: {actual}")
    write_json(output / "summary" / f"extractor-{lane.name}.json", {
        "lane": lane.name, "resolved_root": str(actual),
        "extractor_sha256": digest_file(actual / "tools/osx64/extractor.real"),
        "schema_sha256": digest_file(actual / "swift.dbscheme"),
    })


def validate_case(cli: Path, lane: Lane, case: Case, output: Path, query_pack: Path,
                  sdk: str, environment: Mapping[str, str], deadline: float) -> Result:
    case_root = output / "cases" / lane.name / case.name
    source_root = case_root / "src"
    source_root.mkdir(parents=True)
    logs = output / "logs" / lane.name / case.name
    summary = output / "summary" / lane.name / case.name
    summary.mkdir(parents=True)
    pdf = case.name == "pdfkit"
    source = source_root / ("FileUtilities.swift" if pdf else "Probe.swift")
    shutil.copyfile(case.source, source)
    if case.header is not None:
        if case.modulemap is None:
            raise ValueError(f"{case.name}: a header requires its explicit module map")
        shutil.copyfile(case.header, source_root / "Probe.h")
        shutil.copyfile(case.modulemap, source_root / "module.modulemap")
    write_json(summary / "sources.json", {p.name: digest_file(p) for p in sorted(source_root.iterdir())})
    common = ("xcrun", "swiftc", "-target", "x86_64-apple-macos13.0", "-sdk", sdk,
              "-swift-version", "5", "-Xfrontend", "-enable-cross-import-overlays",
              "-I", str(source_root), *case.flags)
    native = (*common, "-module-cache-path", str(case_root / "native-cache"), "-emit-module",
              str(source), "-module-name", "ValidationFixture", "-emit-module-path", str(case_root / "native.swiftmodule"))
    native_status = run(native, case_root, logs / "native.log", environment, deadline, 120)
    if native_status != case.native_exit:
        raise RuntimeError(f"{lane.name}/{case.name}: native exit {native_status}, expected {case.native_exit}")
    if case.native_exit != 0:
        native_text = (logs / "native.log").read_text(encoding="utf-8") + (logs / "native.stderr.log").read_text(encoding="utf-8")
        if "error: cannot find 'ValidationFunctionAlias' in scope" not in native_text:
            raise RuntimeError(f"{lane.name}/{case.name}: native failure was not the intended alias diagnostic")
    if pdf:
        fixture_root = case.source.parent.parent
        behavior = case_root / "behavior"
        fixtures = case_root / "fixtures"
        fixtures.mkdir()
        for fixture in (fixture_root / "fixtures").glob("*.txt"):
            shutil.copyfile(fixture, fixtures / fixture.name)
        for name in ("invalid.pdf", "two-pages.pdf"):
            require_command(("base64", "-D", "-i", str(fixture_root / "fixtures" / f"{name}.b64"),
                             "-o", str(fixtures / name)), case_root, logs / f"decode-{name}.log", environment, deadline, 30)
        require_command((*common, str(source), str(fixture_root / "Behavior.swift"), "-o", str(behavior)),
                        case_root, logs / "behavior-compile.log", environment, deadline, 120)
        require_command((str(behavior), str(fixtures)), case_root, logs / "behavior.log", environment, deadline, 30)
        if digest_file(logs / "behavior.log") != "46668bfa093cbbbb35dd864350e992e0f8bcba65985833195bf455fac47d4735":
            raise RuntimeError(f"{lane.name}: real PDF behavior differs from the verified six-case baseline")
        shutil.copyfile(logs / "behavior.log", summary / "behavior.txt")
    traced = (*common, "-module-cache-path", str(case_root / "extraction-cache"), "-emit-module",
              str(source), "-module-name", "FileUtilitiesProbe" if pdf else "ValidationFixture",
              "-emit-module-path", str(case_root / "extracted.swiftmodule"))
    build = case_root / "build.sh"
    lines = ["#!/bin/bash", "set -euo pipefail"]
    if case.native_exit != 0:
        companion = source_root / "Valid.swift"
        shutil.copyfile(Path(__file__).parent / "fixtures/Valid.swift", companion)
        valid = (*common, "-module-cache-path", str(case_root / "negative-valid-cache"), "-emit-module",
                 str(companion), "-module-name", "ValidCompanion", "-emit-module-path", str(case_root / "valid.swiftmodule"))
        lines.append(shlex.join(valid))
        lines.append(shlex.join(("bash", str(Path(__file__).parent / "expect-compile-failure.sh"),
                                 str(logs / "traced-negative"), *traced)))
    else:
        lines.append(shlex.join(traced))
    write_json(summary / "sources.json", {p.name: digest_file(p) for p in sorted(source_root.iterdir())})
    build.write_text("\n".join(lines) + "\n", encoding="utf-8")
    database = case_root / "db"
    require_command((str(cli), "database", "create", str(database), "--language=swift",
                     f"--search-path={lane.pack}", f"--source-root={source_root}",
                     f"--command={shlex.join(('bash', str(build)))}", "--threads=1", "--ram=2048",
                     f"--common-caches={output / 'common-caches'}"),
                    case_root, logs / "database-create.log", environment, deadline, 480)
    sarif = summary / "swift.sarif"
    require_command((str(cli), "database", "analyze", str(database),
                     "codeql/swift-queries:codeql-suites/swift-code-scanning.qls",
                     "--format=sarif-latest", f"--output={sarif}", "--threads=1", "--ram=2048",
                     "--timeout=180", f"--common-caches={output / 'common-caches'}"),
                    case_root, logs / "database-analyze.log", environment, deadline, 480)
    errors, sources = sarif_evidence(sarif)
    expected_count = case.counts[lane.index]
    write_json(summary / "extraction-errors.json", errors)
    write_json(summary / "result.json", {"lane": lane.name, "case": case.name,
               "native_exit": native_status, "extraction_notification_count": len(errors),
               "expected_notification_count": expected_count, "successful_sources": sorted(sources)})
    if len(errors) != expected_count:
        raise RuntimeError(f"{lane.name}/{case.name}: extraction notifications {len(errors)}, expected {expected_count}")
    if expected_count:
        for error in errors:
            message = object_value(error["message"], "compiler diagnostic message")
            if case.message is None or case.message not in text_value(message["text"], "compiler diagnostic text"):
                raise RuntimeError(f"{lane.name}/{case.name}: unexpected compiler diagnostic")
    expected_source = "Valid.swift" if case.native_exit != 0 else source.name
    if expected_source not in sources:
        raise RuntimeError(f"{lane.name}/{case.name}: expected source {expected_source} was not extracted")
    if pdf:
        for name in ("calls", "expressions", "inheritance", "candidates", "members"):
            bqrs = case_root / f"{name}.bqrs"
            require_command((str(cli), "query", "run", str(query_pack / f"{name}.ql"),
                             f"--database={database}", f"--output={bqrs}", "--threads=1", "--ram=2048",
                             f"--common-caches={output / 'common-caches'}"),
                            case_root, logs / f"query-{name}.log", environment, deadline, 180)
            require_command((str(cli), "bqrs", "decode", str(bqrs), "--format=csv",
                             f"--output={summary / (name + '.csv')}"),
                            case_root, logs / f"decode-{name}.log", environment, deadline, 60)
    return Result(lane.name, case.name, len(errors))


def validate_semantics(output: Path) -> None:
    root = output / "summary"
    for name, columns in (("calls", 6), ("expressions", 8), ("inheritance", 8), ("members", 6), ("candidates", 6)):
        reference = csv_rows(root / "A/pdfkit" / f"{name}.csv", columns)
        if not reference:
            raise RuntimeError(f"Released PDF semantic probe {name} returned no rows")
        for lane in ("B", "C"):
            actual = csv_rows(root / lane / "pdfkit" / f"{name}.csv", columns)
            if actual != reference:
                write_json(root / f"semantic-difference-{lane}-{name}.json", {
                    "missing": list((reference - actual).elements()),
                    "extra": list((actual - reference).elements())})
                raise RuntimeError(f"Lane {lane} changed the PDF {name} semantic rows")
    members = csv_rows(root / "C/pdfkit/members.csv", 6)
    expected = {(".pageCount", "FileUtilities.swift", "pageCount", "PDFKit", "PDFDocument", "Int"),
                (".string", "FileUtilities.swift", "string", "PDFKit", "PDFPage", "String?")}
    if set(members) != expected or sum(members.values()) != 2:
        raise RuntimeError("Selected PDF property declarations/modules/types are missing or unexpected")
    baseline_candidates = csv_rows(root / "A/pdfkit/candidates.csv", 6)
    required = Counter({row: count for row, count in baseline_candidates.items() if row[1] in ("class", "protocol")})
    if len(required) < 2:
        raise RuntimeError("Released accessibility class/protocol declarations are absent")
    for lane in ("B", "C"):
        actual = csv_rows(root / lane / "pdfkit/candidates.csv", 6)
        selected = Counter({row: count for row, count in actual.items() if row[1] in ("class", "protocol")})
        if selected != required:
            raise RuntimeError(f"Lane {lane} changed accessibility class/protocol declarations")
    write_json(root / "semantic-parity.json", {"calls": True, "expressions": True,
               "inheritance": True, "selected_members": True, "candidates": True, "accessibility_types": True})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("codeql", "control-pack", "patched-pack", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--candidate-revision", required=True)
    arguments = parser.parse_args()
    cli: Path = arguments.codeql.resolve(strict=True)
    output: Path = arguments.output.absolute()
    candidate: str = arguments.candidate_revision
    if re.fullmatch(r"[0-9a-f]{40}", candidate) is None:
        raise ValueError("Candidate revision must be a full lowercase Git SHA")
    if sys.platform != "darwin" or os.uname().machine != "x86_64":
        raise RuntimeError("Differential Swift extraction requires the supported Intel macOS runner")
    if subprocess.check_output(("sw_vers", "-productVersion"), text=True, timeout=10).split(".")[0] != "26":
        raise RuntimeError("Differential Swift extraction requires macOS 26")
    if "Xcode 26.4.1\n" not in subprocess.check_output(("xcodebuild", "-version"), text=True, timeout=30):
        raise RuntimeError("Differential Swift extraction requires Xcode 26.4.1")
    if subprocess.check_output(("xcrun", "--sdk", "macosx", "--show-sdk-version"), text=True, timeout=10).strip() != "26.4":
        raise RuntimeError("Differential Swift extraction requires macOS SDK 26.4")
    native_swift = subprocess.check_output(("xcrun", "swiftc", "--version"), text=True, timeout=30).strip()
    if "Apple Swift version 6.3.1 (" not in native_swift:
        raise RuntimeError("Differential native baselines require Apple Swift 6.3.1 from Xcode 26.4.1")
    if any(name in os.environ for name in ("CODEQL_EXTRACTOR_SWIFT_RUN_UNDER", "CODEQL_EXTRACTOR_SWIFT_RUN_UNDER_FILTER")):
        raise RuntimeError("Differential validation must run without extractor debugging hooks")
    output.mkdir(mode=0o700)
    (output / "summary").mkdir()
    (output / "logs").mkdir()
    deadline = time.monotonic() + 2100
    environment = {**os.environ, "CODEQL_EXTRACTOR_SWIFT_LOG_LEVELS":
                   "*:info,out:binary:no_logs,out:text:info,out:console:warning"}
    require_command((str(cli), "version", "--format=json"), output, output / "logs/version.log", environment, deadline, 30)
    version = object_value(read_json(output / "logs/version.log"), "CodeQL version")
    if version.get("version") != "2.27.3":
        raise RuntimeError("Differential validation requires stock CodeQL CLI 2.27.3")
    stock = (cli.parent / "swift").resolve(strict=True)
    lanes = (Lane("A", stock, 0), Lane("B", arguments.control_pack.resolve(strict=True), 1),
             Lane("C", arguments.patched_pack.resolve(strict=True), 2))
    if len({lane.pack for lane in lanes}) != 3:
        raise ValueError("A/B/C extractor roots must be distinct")
    if any(cli.parent in lane.pack.parents for lane in lanes[1:]):
        raise ValueError("Control and patched extractors must be outside the stock CodeQL bundle")
    stock_before = tree_digest(cli.parent)
    write_json(output / "summary/provenance.json", {"candidate_revision": candidate,
               "checkout_revision": subprocess.check_output(("git", "rev-parse", "HEAD"), text=True, timeout=10).strip(),
               "cli_sha256": digest_file(cli), "stock_tree_before": stock_before,
               "native_swift": native_swift, "xcode": "26.4.1", "sdk": "26.4", "architecture": "x86_64",
               "cache_policy": {"module_caches_and_databases": "fresh per lane and case",
                                "package_and_query_plan_cache": "shared task-owned common-caches"},
               "application_acceptance": False})
    try:
        sdk = subprocess.check_output(("xcrun", "--sdk", "macosx", "--show-sdk-path"), text=True, timeout=10).strip()
        for lane in lanes:
            verify_resolution(cli, lane, output, environment, deadline)
            if digest_file(lane.pack / "swift.dbscheme") != digest_file(stock / "swift.dbscheme"):
                raise RuntimeError(f"Lane {lane.name} does not use the unchanged stock Swift schema")
        here = Path(__file__).resolve().parent
        probe = here.parent
        query_pack = output / "query-pack"
        shutil.copytree(probe / "queries", query_pack, ignore=shutil.ignore_patterns("codeql-pack.lock.yml", "*.bqrs"))
        shutil.copyfile(here / "queries/members.ql", query_pack / "members.ql")
        require_command((str(cli), "pack", "install", f"--common-caches={output / 'common-caches'}"),
                        query_pack, output / "logs/query-pack-install.log", environment, deadline, 180)
        shutil.copyfile(query_pack / "codeql-pack.lock.yml", output / "summary/query-pack.lock.yml")
        feature = here / "fixtures/feature"
        cases: list[Case] = []
        for name, counts in (("class-macro", (0, 0, 0)), ("class-protocol-macro", (1, 1, 0)),
                             ("class-protocol", (0, 0, 0))):
            cases.append(Case(name, probe / "macro-controls/Probe.swift", probe / f"macro-controls/{name}/Probe.h",
                              probe / "macro-controls/module.modulemap", (), 0, counts, "reference to 'ProbeElement' is ambiguous"))
        cases.extend((
            Case("collision-feature-on", probe / "macro-controls/Probe.swift",
                 probe / "macro-controls/class-protocol-macro/Probe.h", probe / "macro-controls/module.modulemap",
                 ("-enable-experimental-feature", "ImportMacroAliases"),
                 0, (1, 1, 1), "reference to 'ProbeElement' is ambiguous"),
            Case("literals-feature-off", feature / "Literals.swift", feature / "Probe.h", feature / "module.modulemap",
                 (), 0, (0, 0, 0), None),
            Case("aliases-feature-on", feature / "Alias.swift", feature / "Probe.h",
                 feature / "module.modulemap",
                 ("-enable-experimental-feature", "ImportMacroAliases"), 0, (0, 0, 0), None),
            Case("alias-negative", feature / "Alias.swift", feature / "Probe.h", feature / "module.modulemap", (), 1, (1, 1, 1),
                 "cannot find 'ValidationFunctionAlias' in scope"),
            Case("pdfkit", probe / "baseline/FileUtilities.swift", None, None, (), 0, (1, 1, 0),
                 "reference to 'NSAccessibilityElement' is ambiguous"),
        ))
        results: list[Result] = []
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(validate_case, cli, lane, case, output, query_pack, sdk, environment, deadline)
                       for case in cases for lane in lanes]
            try:
                for future in as_completed(futures):
                    result = future.result()
                    results.append(result)
                    write_json(output / "summary/completed.json", [item._asdict() for item in results])
                    print(f"Validated {result.lane}/{result.case}: {result.notifications} extraction notifications", flush=True)
            except (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
                for future in futures:
                    future.cancel()
                raise
        validate_semantics(output)
        for lane in lanes:
            verify_resolution(cli, lane, output, environment, deadline)
    finally:
        stock_after = tree_digest(cli.parent)
        write_json(output / "summary/stock-integrity.json", {"before": stock_before, "after": stock_after,
                   "unchanged": stock_before == stock_after})
        if stock_before != stock_after:
            raise RuntimeError("The installed stock Swift extractor bundle changed during validation") from sys.exc_info()[1]
    write_json(output / "summary/verdict.json", {"differential_fixture_validation": True,
               "case_count": len(results), "stock_bundle_unchanged": True, "application_acceptance": False})


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Differential extractor validation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
