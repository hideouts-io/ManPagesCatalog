#!/usr/bin/env python3
"""Bounded local APFS controller; all catalog/index writes run through the native production worker.

The image, fillers, subprocesses and cleanup are ownership checked. Interrupted
atomic writes count only when an incomplete temporary file or live SQLite
journal is observed before stopping the exact worker PID.
"""

import argparse
from contextlib import closing
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import stat
import subprocess
import time
import uuid


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def write_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".temporary")
    with temporary.open("x") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")
    temporary.replace(path)


def worker_run(worker: Path, volume: Path, token: str, operation: str, library: str, evidence: Path) -> int:
    began = time.monotonic()
    result = subprocess.run([str(worker), operation, str(volume), token, library], capture_output=True, timeout=200)
    attempt = 1
    while (evidence / f"{library}-{operation}-attempt-{attempt:02d}.stdout").exists():
        attempt += 1
    stem = f"{library}-{operation}-attempt-{attempt:02d}"
    (evidence / f"{stem}.stdout").write_bytes(result.stdout)
    (evidence / f"{stem}.stderr").write_bytes(result.stderr)
    write_json(evidence / f"{stem}.process.json", {
        "operation": operation, "library": library, "status": result.returncode,
        "attempt": attempt,
        "controllerElapsedSeconds": time.monotonic() - began,
    })
    return result.returncode


def verify_library(library: Path) -> dict[str, object]:
    with (library / "discovery-v1.json").open() as source:
        inventory = json.load(source)
    pages = inventory["pages"]
    with closing(sqlite3.connect(f"file:{library / 'search.sqlite'}?mode=ro", uri=True)) as connection:
        integrity = connection.execute("PRAGMA integrity_check").fetchall()
        rows = connection.execute("SELECT id,fingerprint,description,body,diagnostic FROM manuals_v3 ORDER BY id").fetchall()
        mapping = connection.execute("SELECT id,manual_rowid FROM manuals_rowids_v1 ORDER BY id").fetchall()
        marker_counts = [connection.execute("SELECT count(*) FROM manuals_v3 WHERE manuals_v3 MATCH ?", (f'"storagerecovery{ordinal}"',)).fetchone()[0] for ordinal in range(132)]
    content = json.dumps(rows, separators=(",", ":")).encode()
    return {
        "inventorySHA256": digest(library / "discovery-v1.json"), "manuals": len(pages),
        "inventoryContentSHA256": hashlib.sha256(json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "indexed": sum(page["indexed"] for page in pages), "uniqueIDs": len({page["fingerprint"] + ":" + page["section"] + ":" + page["language"] for page in pages}),
        "indexRows": len(rows), "indexContentSHA256": hashlib.sha256(content).hexdigest(),
        "mappingRows": len(mapping), "integrity": integrity, "markerCounts": marker_counts,
        "checkpointSHA256": digest(library / "scan-checkpoint-v1.json"),
    }


def verify_large_library(library: Path) -> dict[str, object]:
    with (library / "discovery-v1.json").open() as source:
        inventory = json.load(source)
    pages = inventory["pages"]
    with closing(sqlite3.connect(f"file:{library / 'search.sqlite'}?mode=ro", uri=True)) as connection:
        integrity = connection.execute("PRAGMA integrity_check").fetchall()
        rows = connection.execute("SELECT id,fingerprint,description,body,diagnostic FROM manuals_v3 ORDER BY id").fetchall()
        mapping = connection.execute("SELECT id,manual_rowid FROM manuals_rowids_v1 ORDER BY id").fetchall()
    return {"manuals": len(pages), "locations": sum(len(page["locations"]) for page in pages),
            "indexed": sum(page["indexed"] for page in pages), "inventorySHA256": digest(library / "discovery-v1.json"),
            "inventoryContentSHA256": hashlib.sha256(json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
            "indexRows": len(rows), "mappingRows": len(mapping), "integrity": integrity,
            "indexContentSHA256": hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()}


def fill_volume(volume: Path, token: str, limit: int) -> dict[str, object]:
    ownership = json.loads((volume / ".manpages-storage-owner.json").read_text())
    if ownership["token"] != token or ownership["volume"] != str(volume) or not os.path.ismount(volume):
        raise RuntimeError("Refusing filler on an unowned or unmounted volume")
    filler = volume / f"owned-filler-{token}.bin"
    descriptor = os.open(filler, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    before = os.fstat(descriptor)
    payload = os.urandom(1024 * 1024)
    written = 0
    failure = None
    began = time.monotonic()
    try:
        while written < limit:
            try:
                written += os.write(descriptor, payload[:min(len(payload), limit - written)])
            except OSError as error:
                if error.errno != errno.ENOSPC:
                    raise
                failure = {"errno": error.errno, "description": str(error)}
                break
        if failure is None:
            raise RuntimeError("Explicit filler limit was reached without observing ENOSPC")
    finally:
        os.close(descriptor)
    return {"filler": str(filler), "device": before.st_dev, "inode": before.st_ino,
            "bytes": written, "error": failure, "seconds": time.monotonic() - began,
            "availableBytes": os.statvfs(volume).f_bavail * os.statvfs(volume).f_frsize}


def remove_filler(record: dict[str, object], volume: Path, token: str) -> None:
    path = Path(str(record["filler"]))
    if path != volume / f"owned-filler-{token}.bin":
        raise RuntimeError("Unexpected filler path")
    current = path.lstat()
    if current.st_dev != record["device"] or current.st_ino != record["inode"] or not stat.S_ISREG(current.st_mode):
        raise RuntimeError("Filler identity changed; cleanup refused")
    path.unlink()


def interrupted_write(worker: Path, volume: Path, token: str, operation: str, library: str, evidence: Path) -> dict[str, object]:
    observer = worker.parent / "storage-write-interruption"
    result = subprocess.run([str(observer), str(worker), operation, str(volume), token, library], capture_output=True, timeout=45)
    (evidence / f"{library}-interruption.stdout").write_bytes(result.stdout)
    (evidence / f"{library}-interruption.stderr").write_bytes(result.stderr)
    if result.returncode != 0:
        raise RuntimeError("Native exact-PID write observer failed; inspect retained evidence")
    return json.loads(result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--capacity-mib", required=True, type=int)
    parser.add_argument("--reserve-mib", required=True, type=int)
    parser.add_argument("--reference-library", required=True, type=Path)
    options = parser.parse_args()
    if not options.worker.is_file() or not options.output.is_absolute() or options.output.exists():
        raise RuntimeError("Provide an existing native worker and a new absolute output directory")
    if not options.reference_library.is_absolute() or not (options.reference_library / "discovery-v1.json").is_file():
        raise RuntimeError("Provide the separately retained 10,006-manual reference library")
    if not 256 <= options.capacity_mib <= 1024 or options.reserve_mib < 10240:
        raise RuntimeError("Capacity must be 256–1024 MiB and host reserve at least 10240 MiB")
    free = shutil.disk_usage(options.output.parent).free
    if free - options.capacity_mib * 1024 * 1024 < options.reserve_mib * 1024 * 1024:
        raise RuntimeError("Insufficient host reserve for isolated storage volume")
    options.output.mkdir()
    token = uuid.uuid4().hex
    volume_name = f"ManPagesRecovery-{token[:8]}"
    volume = Path("/Volumes") / volume_name
    image = options.output / "owned-recovery.img"
    if volume.exists():
        raise RuntimeError("Refusing preexisting mount path")
    write_json(options.output / "ownership.json", {"owner": "ManPagesCatalog StorageRecovery", "token": token,
               "image": str(image), "volume": str(volume), "capacityMiB": options.capacity_mib,
               "hostReserveMiB": options.reserve_mib, "hostAvailableBeforeBytes": free,
               "uid": os.geteuid(), "created": time.time()})
    created = subprocess.run(["/usr/sbin/diskutil", "image", "create", "blank", "--size", str(options.capacity_mib * 1024 * 1024), "--volumeName", volume_name, "--fs", "APFS", str(image)], capture_output=True, check=True)
    (options.output / "create-image.log").write_bytes(created.stdout + created.stderr)
    mounted = subprocess.run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-plist", str(image)], capture_output=True, check=True)
    (options.output / "attach.plist").write_bytes(mounted.stdout)
    entities = plistlib.loads(mounted.stdout)["system-entities"]
    if not any(entity.get("mount-point") == str(volume) for entity in entities) or not os.path.ismount(volume):
        raise RuntimeError("Owned disk image did not mount at the expected path")
    try:
        write_json(volume / ".manpages-storage-owner.json", {"owner": "ManPagesCatalog StorageRecovery", "token": token, "volume": str(volume)})
        if worker_run(options.worker, volume, token, "prepare", "baseline", options.output) != 0:
            raise RuntimeError("Native preparation failed; inspect retained worker output")
        initial = verify_library(volume / "baseline")
        write_json(options.output / "initial.json", initial)
        shutil.copytree(volume / "baseline", volume / "uninterrupted")
        if worker_run(options.worker, volume, token, "resume", "uninterrupted", options.output) != 0:
            raise RuntimeError("Uninterrupted production baseline failed")
        expected = verify_library(volume / "uninterrupted")
        write_json(options.output / "uninterrupted.json", expected)
        results: list[dict[str, object]] = []
        for operation in ("inventory-write", "checkpoint-write", "index-write", "resume"):
            name = f"pressure-{operation}"
            shutil.copytree(volume / "baseline", volume / name)
            before = verify_library(volume / name)
            filler = fill_volume(volume, token, options.capacity_mib * 1024 * 1024)
            status = worker_run(options.worker, volume, token, operation, name, options.output)
            remove_filler(filler, volume, token)
            if worker_run(options.worker, volume, token, "inspect", name, options.output) != 0:
                raise RuntimeError("Production index reopening could not recover the retained state")
            after_failure = verify_library(volume / name)
            recovery_status = worker_run(options.worker, volume, token, "resume", name, options.output)
            recovered = verify_library(volume / name)
            result = {"operation": operation, "filler": filler, "failureStatus": status, "before": before,
                      "afterFailure": after_failure, "recoveryStatus": recovery_status, "recovered": recovered,
                      "matchesUninterruptedContent": recovered["indexContentSHA256"] == expected["indexContentSHA256"],
                      "matchesUninterruptedInventory": recovered["inventoryContentSHA256"] == expected["inventoryContentSHA256"]}
            results.append(result)
            write_json(options.output / "pressure-results.json", results)
        for operation in ("inventory-write", "checkpoint-write", "index-write"):
            name = f"interrupted-{operation}"
            shutil.copytree(volume / "baseline", volume / name)
            before = verify_library(volume / name)
            interrupted = interrupted_write(options.worker, volume, token, operation, name, options.output)
            if worker_run(options.worker, volume, token, "inspect", name, options.output) != 0:
                raise RuntimeError("Production index reopening could not recover the interrupted state")
            after = verify_library(volume / name)
            recovery_status = worker_run(options.worker, volume, token, "resume", name, options.output)
            recovered = verify_library(volume / name)
            results.append({"operation": operation, "before": before, "interruption": interrupted, "afterInterruption": after,
                            "recoveryStatus": recovery_status, "recovered": recovered,
                            "matchesUninterruptedContent": recovered["indexContentSHA256"] == expected["indexContentSHA256"],
                            "matchesUninterruptedInventory": recovered["inventoryContentSHA256"] == expected["inventoryContentSHA256"]})
            write_json(options.output / "all-results.json", results)
        shutil.copytree(volume / "baseline", volume / "paired-export")
        report_path = volume / "paired-export/scan-performance-v1.json"
        report = json.loads(report_path.read_text())
        report["limitations"].append("Harness-owned synthetic output-size pressure: " + "x" * (32 * 1024 * 1024))
        report_path.write_text(json.dumps(report))
        exports = volume / "exports"
        exports.mkdir()
        pair_results: list[dict[str, object]] = []
        for prior_state in ("existing", "absent"):
            coverage = exports / "coverage.json"
            performance = exports / "coverage.performance.json"
            if prior_state == "existing":
                coverage.write_bytes(b'{"ownedPriorCoverage":true}\n')
                performance.write_bytes(b'{"ownedPriorPerformance":true}\n')
            else:
                coverage.unlink()
                performance.unlink()
            before = {str(path.name): digest(path) if path.exists() else None for path in (coverage, performance)}
            filler = fill_volume(volume, token, options.capacity_mib * 1024 * 1024)
            filler_path = Path(str(filler["filler"]))
            descriptor = os.open(filler_path, os.O_WRONLY | os.O_NOFOLLOW)
            try:
                os.ftruncate(descriptor, max(0, int(filler["bytes"]) - 16 * 1024 * 1024))
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            available = os.statvfs(volume).f_bavail * os.statvfs(volume).f_frsize
            case_evidence = options.output / f"paired-{prior_state}"
            case_evidence.mkdir()
            status = worker_run(options.worker, volume, token, "export-write", "paired-export", case_evidence)
            after = {str(path.name): digest(path) if path.exists() else None for path in (coverage, performance)}
            remove_filler(filler, volume, token)
            pair_results.append({"priorState": prior_state, "availableBeforeExportBytes": available, "nativeExitStatus": status,
                                 "before": before, "after": after, "priorPairPreserved": before == after, "filler": filler})
            write_json(options.output / "paired-results.json", pair_results)
            if prior_state == "existing" and before != after:
                raise RuntimeError("Second-write failed export did not preserve the existing pair")
            if prior_state == "absent" and before != after:
                raise RuntimeError("Second-write failed export did not restore original absence")
        coverage = exports / "coverage.json"
        performance = exports / "coverage.performance.json"
        coverage.write_bytes(b'{"ownedPriorCoverage":true}\n')
        performance.write_bytes(b'{"ownedPriorPerformance":true}\n')
        pair_before = {path.name: digest(path) for path in (coverage, performance)}
        pair_interruption = interrupted_write(options.worker, volume, token, "export-write", "paired-export", options.output)
        pair_after = {path.name: digest(path) if path.exists() else None for path in (coverage, performance)}
        pair_retry = worker_run(options.worker, volume, token, "export-write", "paired-export", options.output)
        retained_pair = json.loads((volume / "paired-export/discovery-v1.json").read_text())
        retained_report = json.loads(report_path.read_text())
        pair_recovery = {"interruption": pair_interruption, "before": pair_before, "afterInterruption": pair_after,
                         "mixedPairObserved": pair_after[coverage.name] != pair_before[coverage.name] and pair_after[performance.name] == pair_before[performance.name],
                         "retryStatus": pair_retry, "coverageMatchesRetained": json.loads(coverage.read_text()) == retained_pair["coverage"],
                         "performanceMatchesRetained": json.loads(performance.read_text()) == retained_report,
                         "limitation": "Each output replacement is atomic; a killed process between the two can leave mixed report generations. Repeating export replaces both, but the pair has no crash-atomic guarantee."}
        write_json(options.output / "paired-interruption-results.json", pair_recovery)
        large_reference = verify_large_library(options.reference_library)
        write_json(options.output / "large-reference-before.json", large_reference)
        preparation = subprocess.run([str(options.worker), "prepare-large", str(volume), token, "large-library", str(options.reference_library)], capture_output=True, timeout=30)
        (options.output / "large-prepare.stdout").write_bytes(preparation.stdout)
        (options.output / "large-prepare.stderr").write_bytes(preparation.stderr)
        if preparation.returncode != 0:
            raise RuntimeError("Native large-library preparation failed")
        large_before = verify_large_library(volume / "large-library")
        write_json(options.output / "large-before-pressure.json", large_before)
        large_filler = fill_volume(volume, token, options.capacity_mib * 1024 * 1024)
        large_status = worker_run(options.worker, volume, token, "resume-large", "large-library", options.output)
        remove_filler(large_filler, volume, token)
        if worker_run(options.worker, volume, token, "inspect", "large-library", options.output) != 0:
            raise RuntimeError("Large production index could not reopen after ENOSPC")
        large_failed = verify_large_library(volume / "large-library")
        write_json(options.output / "large-after-pressure.json", large_failed)
        large_recovery_status = worker_run(options.worker, volume, token, "resume-large", "large-library", options.output)
        large_recovered = verify_large_library(volume / "large-library")
        large_after_reference = verify_large_library(options.reference_library)
        large_result = {"failureStatus": large_status, "filler": large_filler, "before": large_before,
                        "afterPressure": large_failed, "recoveryStatus": large_recovery_status, "recovered": large_recovered,
                        "matchesReferenceContent": large_recovered["indexContentSHA256"] == large_reference["indexContentSHA256"],
                        "matchesReferenceInventory": large_recovered["inventoryContentSHA256"] == large_reference["inventoryContentSHA256"],
                        "referenceUnchanged": large_after_reference == large_reference}
        write_json(options.output / "large-results.json", large_result)
        if large_status == 0 or large_recovery_status != 0 or not large_result["matchesReferenceContent"] or not large_result["matchesReferenceInventory"]:
            raise RuntimeError("Large pressure failure or exact recovery parity did not meet acceptance")
        if worker_run(options.worker, volume, token, "export-write", "large-library", options.output) != 0:
            raise RuntimeError("Recovered large catalog coverage export failed")
        actual_coverage = json.loads((exports / "coverage.json").read_text())
        actual_performance = json.loads((exports / "coverage.performance.json").read_text())
        retained = json.loads((volume / "large-library/discovery-v1.json").read_text())
        retained_performance = json.loads((volume / "large-library/scan-performance-v1.json").read_text())
        coverage_parity = {"coverageMatchesRetainedScan": actual_coverage == retained["coverage"],
                           "performanceMatchesRetainedReport": actual_performance == retained_performance,
                           "manuals": len(retained["pages"]), "indexed": sum(page["indexed"] for page in retained["pages"]),
                           "scanID": actual_performance["scanID"], "state": actual_performance["state"]}
        write_json(options.output / "large-export-parity.json", coverage_parity)
        shutil.copy2(exports / "coverage.json", options.output / "recovered-large-coverage.json")
        shutil.copy2(exports / "coverage.performance.json", options.output / "recovered-large-coverage.performance.json")
        write_json(options.output / "completion.json", {"state": "completed", "cases": len(results), "hostAvailableAfterBytes": shutil.disk_usage(options.output).free,
                   "imageRetained": str(image), "limitations": ["The APFS image shares host physical storage; not an external-drive or sudden-power-loss test.",
                   "The real installed-source recovery corpus contains 132 distinct manuals; oversized persistence fields only widen an observable write window.",
                   "Paired exports are tested separately; this controller does not claim crash-atomic pairs.", "Cache state and concurrent host build/GUI activity are uncontrolled."]})
    finally:
        detached = subprocess.run(["/usr/sbin/diskutil", "eject", str(volume)], capture_output=True)
        (options.output / "detach.log").write_bytes(detached.stdout + detached.stderr)
        if detached.returncode != 0:
            raise RuntimeError("Cannot detach owned recovery image; mounted evidence retained")


if __name__ == "__main__":
    main()
