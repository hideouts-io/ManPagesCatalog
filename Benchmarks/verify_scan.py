#!/usr/bin/env python3
"""Verify production LibraryScan identities, source locations and coverage against a fixture manifest."""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path, PurePosixPath
import sys
import unicodedata
from urllib.parse import unquote, urlsplit


class VerificationInputError(ValueError):
    """A scan or manifest lacks required, correctly typed fields."""


@dataclass(frozen=True)
class Manual:
    path: str
    name: str
    section: str
    language: str
    group: str


@dataclass(frozen=True)
class Issue:
    path: str
    kind: str


@dataclass(frozen=True)
class ExpectedScan:
    root: str
    manuals: tuple[Manual, ...]
    issues: tuple[Issue, ...]
    inaccessible_verified: bool
    ordinary_files_created: int


@dataclass(frozen=True)
class ObservedRoot:
    root: str
    files: int
    directories: int
    completed: bool


@dataclass(frozen=True)
class ObservedScan:
    manuals: tuple[Manual, ...]
    issues: tuple[Issue, ...]
    groups: tuple[str, ...]
    files: int
    directories: int
    completed_roots: tuple[str, ...]
    incomplete_roots: tuple[str, ...]
    roots: tuple[ObservedRoot, ...]
    cancelled: bool


def mapping(value: object, context: str) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise VerificationInputError(f"{context} must be a JSON object with string keys")
    return {str(key): item for key, item in value.items()}


def sequence(value: object, context: str) -> tuple[object, ...]:
    if not isinstance(value, list):
        raise VerificationInputError(f"{context} must be a JSON array")
    return tuple(value)


def string(value: object, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise VerificationInputError(f"{context} must be a nonempty string")
    return value


def boolean(value: object, context: str) -> bool:
    if not isinstance(value, bool):
        raise VerificationInputError(f"{context} must be a boolean")
    return value


def integer(value: object, context: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise VerificationInputError(f"{context} must be a nonnegative integer")
    return value


def required(value: dict[str, object], field: str, context: str) -> object:
    if field not in value:
        raise VerificationInputError(f"{context} is missing required field {field}")
    return value[field]


def load(path: Path) -> dict[str, object]:
    decoded: object = json.loads(path.read_text())
    return mapping(decoded, str(path))


def source_path(value: object, context: str) -> str:
    source = string(value, context)
    parsed = urlsplit(source)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost") or parsed.query or parsed.fragment:
        raise VerificationInputError(f"{context} must be a local file URL: {source}")
    path = unquote(parsed.path)
    if not path.startswith("/"):
        raise VerificationInputError(f"{context} has a nonabsolute path: {source}")
    return path


def inside(root: str, path: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def canonical_root(root: str) -> str:
    return unicodedata.normalize("NFC", str(PurePosixPath(root))).rstrip("/") or "/"


def parse_expected(value: dict[str, object]) -> ExpectedScan:
    if integer(required(value, "schema", "manifest"), "manifest.schema") != 1:
        raise VerificationInputError("Only manifest schema 1 is supported")
    if not boolean(required(value, "generationComplete", "manifest"), "manifest.generationComplete"):
        raise VerificationInputError("A complete production scan requires a complete generation manifest")
    if string(required(value, "filesystem", "manifest"), "manifest.filesystem") != "apfs":
        raise VerificationInputError("This verifier's canonical Unicode path comparison is scoped to APFS fixtures")
    ownership = mapping(required(value, "ownership", "manifest"), "manifest.ownership")
    root = string(required(ownership, "root", "ownership"), "ownership.root")
    if not root.startswith("/"):
        raise VerificationInputError("Manifest root must be absolute")
    fixtures = mapping(required(value, "fixtures", "manifest"), "manifest.fixtures")
    manuals: list[Manual] = []
    issues: list[Issue] = []
    for item in sequence(required(fixtures, "manuals", "fixtures"), "fixtures.manuals"):
        manual = mapping(item, "expected manual")
        relative = string(required(manual, "relativePath", "manual"), "manual.relativePath")
        if PurePosixPath(relative).is_absolute() or ".." in PurePosixPath(relative).parts:
            raise VerificationInputError(f"Expected relative manual path escapes the root: {relative}")
        name = string(required(manual, "name", "manual"), "manual.name")
        section = string(required(manual, "section", "manual"), "manual.section")
        language = string(required(manual, "language", "manual"), "manual.language")
        digest = string(required(manual, "contentSHA256", "manual"), "manual.contentSHA256")
        group = string(required(manual, "groupIdentity", "manual"), "manual.groupIdentity")
        if group != f"{digest}:{section}:{language}":
            raise VerificationInputError(f"Expected group differs from content/section/language at {relative}")
        manuals.append(Manual(str(Path(root) / relative), name, section, language, group))
    for item in sequence(required(fixtures, "issues", "fixtures"), "fixtures.issues"):
        issue = mapping(item, "expected issue")
        relative = string(required(issue, "relativePath", "issue"), "issue.relativePath")
        if PurePosixPath(relative).is_absolute() or ".." in PurePosixPath(relative).parts:
            raise VerificationInputError(f"Expected issue path escapes the root: {relative}")
        issues.append(Issue(str(Path(root) / relative), string(required(issue, "kind", "issue"), "issue.kind")))
    return ExpectedScan(root, tuple(manuals), tuple(issues), boolean(required(fixtures, "inaccessibleVerified", "fixtures"), "fixtures.inaccessibleVerified"), integer(required(value, "ordinaryFilesCreated", "manifest"), "manifest.ordinaryFilesCreated"))


def parse_observed(value: dict[str, object]) -> ObservedScan:
    manuals: list[Manual] = []
    issues: list[Issue] = []
    groups: list[str] = []
    completed: list[str] = []
    incomplete: list[str] = []
    roots: list[ObservedRoot] = []
    files = 0
    directories = 0
    for item in sequence(required(value, "pages", "scan"), "scan.pages"):
        page = mapping(item, "observed page")
        digest = string(required(page, "fingerprint", "page"), "page.fingerprint")
        section = string(required(page, "section", "page"), "page.section")
        language = string(required(page, "language", "page"), "page.language")
        group = f"{digest}:{section}:{language}"
        groups.append(group)
        for entry in sequence(required(page, "locations", "page"), "page.locations"):
            location = mapping(entry, "observed location")
            name = string(required(location, "name", "location"), "location.name")
            own_section = string(required(location, "section", "location"), "location.section")
            own_language = string(required(location, "language", "location"), "location.language")
            if (own_section, own_language) != (section, language):
                raise VerificationInputError("Observed location section/language differs from its grouped page")
            manuals.append(Manual(source_path(required(location, "source", "location"), "location.source"), name, own_section, own_language, group))
    for item in sequence(required(value, "coverage", "scan"), "scan.coverage"):
        coverage = mapping(item, "observed coverage")
        root = source_path(required(coverage, "root", "coverage"), "coverage.root")
        root_files = integer(required(coverage, "files", "coverage"), "coverage.files")
        root_directories = integer(required(coverage, "directories", "coverage"), "coverage.directories")
        root_completed = boolean(required(coverage, "completed", "coverage"), "coverage.completed")
        roots.append(ObservedRoot(root, root_files, root_directories, root_completed))
        files += root_files
        directories += root_directories
        if root_completed:
            completed.append(root)
        else:
            incomplete.append(root)
        for entry in sequence(required(coverage, "issues", "coverage"), "coverage.issues"):
            issue = mapping(entry, "observed issue")
            issues.append(Issue(string(required(issue, "path", "issue"), "issue.path"), string(required(issue, "kind", "issue"), "issue.kind")))
    return ObservedScan(tuple(manuals), tuple(issues), tuple(groups), files, directories, tuple(completed), tuple(incomplete), tuple(roots), boolean(required(value, "cancelled", "scan"), "scan.cancelled"))


def verify(expected: ExpectedScan, observed: ObservedScan) -> dict[str, object]:
    actual = tuple(manual for manual in observed.manuals if inside(expected.root, manual.path))
    actual_issues = tuple(issue for issue in observed.issues if inside(expected.root, issue.path))
    canonical_actual = tuple(canonical_manual(manual) for manual in actual)
    expected_set = {canonical_manual(manual) for manual in expected.manuals}
    actual_set = set(canonical_actual)
    expected_issues = {Issue(unicodedata.normalize("NFC", issue.path), issue.kind) for issue in expected.issues if issue.kind != "unverified"}
    observed_issues = {Issue(unicodedata.normalize("NFC", issue.path), issue.kind) for issue in actual_issues}
    missing_manuals = sorted(expected_set - actual_set, key=lambda manual: manual.path)
    extra_manuals = sorted(actual_set - expected_set, key=lambda manual: manual.path)
    missing_issues = sorted(expected_issues - observed_issues, key=lambda issue: issue.path)
    extra_issues = sorted(observed_issues - expected_issues, key=lambda issue: issue.path)
    duplicate_groups = sorted(group for group in set(observed.groups) if observed.groups.count(group) != 1)
    duplicate_locations = sorted(manual.path for manual in set(canonical_actual) if canonical_actual.count(manual) != 1)
    failures = []
    for label, items in [("missing expected manual locations", missing_manuals), ("unexpected manual metadata/locations", extra_manuals), ("missing expected coverage issues", missing_issues), ("unexpected coverage issues", extra_issues), ("duplicate grouped pages", duplicate_groups), ("duplicate locations", duplicate_locations)]:
        if items:
            failures.append(f"{label}: {len(items)}")
    if observed.cancelled or observed.incomplete_roots:
        failures.append("Scan is cancelled or has incomplete roots")
    if not any(inside(expected.root, root) or inside(root, expected.root) for root in observed.completed_roots):
        failures.append("No completed scan root covers the expected tree")
    ordinary_root = str(Path(expected.root) / "ordinary")
    ordinary_coverage = tuple(root for root in observed.roots if canonical_root(root.root) == canonical_root(ordinary_root))
    if expected.ordinary_files_created:
        if len(ordinary_coverage) != 1:
            failures.append(f"Expected exactly one separate ordinary root coverage entry for {ordinary_root}; observed {len(ordinary_coverage)}")
        else:
            ordinary = ordinary_coverage[0]
            if not ordinary.completed:
                failures.append(f"Ordinary root coverage is incomplete: {ordinary_root}")
            if ordinary.files != expected.ordinary_files_created:
                failures.append(f"Ordinary files inspected by production differ from the generator manifest: expected {expected.ordinary_files_created}, observed {ordinary.files}")
    return {"schema": 1, "passed": not failures, "expectedRoot": expected.root, "expectedManualLocations": len(expected_set), "observedManualLocationsWithinTree": len(actual), "expectedUniqueGroups": len({manual.group for manual in expected_set}), "observedUniqueGroupsWithinTree": len({manual.group for manual in actual}), "otherManualLocations": len(observed.manuals) - len(actual), "inaccessibleFixtureVerifiedByGenerator": expected.inaccessible_verified, "ordinaryFilesCreatedByGenerator": expected.ordinary_files_created, "expectedOrdinaryRoot": ordinary_root, "ordinaryRootCoverageObservedByProduction": [root.__dict__ for root in ordinary_coverage], "allRootsFilesInspectedByProduction": observed.files, "allRootsDirectoriesInspectedByProduction": observed.directories, "rootCoverageObservedByProduction": [root.__dict__ for root in observed.roots], "completedRoots": list(observed.completed_roots), "incompleteRoots": list(observed.incomplete_roots), "missingManuals": [manual.__dict__ for manual in missing_manuals], "unexpectedManuals": [manual.__dict__ for manual in extra_manuals], "missingIssues": [issue.__dict__ for issue in missing_issues], "unexpectedIssues": [issue.__dict__ for issue in extra_issues], "duplicateGroups": duplicate_groups, "duplicateLocations": duplicate_locations, "failures": failures, "unicodeComparison": "APFS is normalization-insensitive; source-path comparisons use canonical NFC equivalence. Case, aliases, and distinct locations are preserved. Original production URL strings remain in the scan JSON.", "unicodeReference": "https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html", "countInterpretation": "Generator-created ordinary files and production-inspected files remain independently recorded. A nonempty ordinary corpus requires exactly one completed ordinary root whose production-inspected count equals the manifest expectation. Fixture file totals are not hardcoded because production candidate-counter definitions differ between scanner versions. A zero-ordinary manifest does not require an ordinary root."}


def canonical_manual(manual: Manual) -> Manual:
    return Manual(unicodedata.normalize("NFC", manual.path), manual.name, manual.section, manual.language, manual.group)


def main(arguments: tuple[str, ...]) -> int:
    if len(arguments) != 3:
        raise VerificationInputError("Usage: verify_scan.py manifest-v1.json production-scan.json verification-output.json")
    expected = parse_expected(load(Path(arguments[0])))
    observed = parse_observed(load(Path(arguments[1])))
    result = verify(expected, observed)
    output = Path(arguments[2])
    with output.open("w") as handle:
        json.dump(result, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main(tuple(sys.argv[1:])))
