import XCTest
import PDFKit
import Combine
import Darwin
import SwiftUI
@testable import Man_Page_Catalog

final class DiscoveryIntegrationTests: XCTestCase {
    func testFailedAtomicCompanionPreservesForeignReplacement() throws {
        try verifyFailedAtomicDestinationPreservation(previous: Data("previous companion".utf8))
    }

    func testFailedAtomicCompanionPreservesNewFile() throws {
        try verifyFailedAtomicDestinationPreservation(previous: nil)
    }

    private func verifyFailedAtomicDestinationPreservation(previous: Data?) throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let coverage = directory.appendingPathComponent("coverage.json")
        let companion = directory.appendingPathComponent("coverage.performance.json")
        let originalCoverage = Data("previous coverage".utf8)
        let newCoverage = Data("new coverage".utf8)
        try originalCoverage.write(to: coverage, options: .atomic)
        if let previous { try previous.write(to: companion, options: .atomic) }
        let exports = [try prepareCoverageExport(destination: coverage, bytes: newCoverage),
                       try prepareCoverageExport(destination: companion, bytes: Data("new companion".utf8))]
        defer { for export in exports { XCTAssertTrue(closeCoverageExport(export).isEmpty) } }
        try publishCoverageExport(exports[0])
        try denyExportDirectoryWrites(directory)
        var writeFailure: Error?
        do { try publishCoverageExport(exports[1]) }
        catch { writeFailure = error }
        let failure = try XCTUnwrap(writeFailure, "The actual atomic companion publication must fail before recovery.")
        guard chmod(directory.path, 0o700) == 0 else {
            throw ManualToolError(message: "Cannot restore owned fixture write access: errno \(errno).")
        }
        let foreign = Data("independent writer after failed companion write".utf8)
        try foreign.write(to: companion, options: .atomic)
        var foreignIdentity = stat()
        XCTAssertEqual(lstat(companion.path, &foreignIdentity), 0)
        XCTAssertThrowsError(try restoreCoverageExport(exports: exports, failedIndex: 1, publishedIndices: [0], writeFailure: failure)) { error in
            XCTAssertTrue(error.localizedDescription.contains(companion.path))
            XCTAssertTrue(error.localizedDescription.contains("changed independently"))
            XCTAssertTrue(error.localizedDescription.contains(failure.localizedDescription))
        }
        XCTAssertEqual(try Data(contentsOf: companion), foreign)
        var retainedIdentity = stat()
        XCTAssertEqual(lstat(companion.path, &retainedIdentity), 0)
        XCTAssertEqual(retainedIdentity.st_ino, foreignIdentity.st_ino)
        XCTAssertEqual(try Data(contentsOf: coverage), originalCoverage)
    }

    func testOwnedExportRestoresPreviousBytes() throws {
        try verifyOwnedExportRestoration(original: Data("previous coverage".utf8))
    }

    func testOwnedExportRestoresPreviousAbsence() throws {
        try verifyOwnedExportRestoration(original: nil)
    }

    private func verifyOwnedExportRestoration(original: Data?) throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        if let original { try original.write(to: destination, options: .atomic) }
        let replacement = Data("published coverage".utf8)
        let export = try prepareCoverageExport(destination: destination, bytes: replacement)
        defer { XCTAssertTrue(closeCoverageExport(export).isEmpty) }
        var recoveryMetadata = stat()
        XCTAssertEqual(lstat(export.recoveryURL.path, &recoveryMetadata), 0)
        XCTAssertEqual(recoveryMetadata.st_mode & 0o777, 0o700)
        try publishCoverageExport(export)
        let outcome = try restorePublishedCoverageExport(export)
        XCTAssertTrue(outcome.contains(destination.path))
        if let original { XCTAssertEqual(try Data(contentsOf: destination), original) }
        else { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
        XCTAssertEqual(try Data(contentsOf: export.recoveryURL.appendingPathComponent("captured")), replacement)
    }

    func testPublishedExportPreservesIndependentReplacementAndOriginalBackup() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        let original = Data("previous coverage".utf8)
        try original.write(to: destination, options: .atomic)
        let export = try prepareCoverageExport(destination: destination, bytes: Data("new coverage".utf8))
        defer { XCTAssertTrue(closeCoverageExport(export).isEmpty) }
        try publishCoverageExport(export)
        let foreign = Data("independent successful-destination writer".utf8)
        try foreign.write(to: destination, options: .atomic)
        var before = stat()
        XCTAssertEqual(lstat(destination.path, &before), 0)
        XCTAssertThrowsError(try restorePublishedCoverageExport(export)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed after publication"))
            XCTAssertTrue(error.localizedDescription.contains(export.recoveryURL.path))
        }
        var after = stat()
        XCTAssertEqual(lstat(destination.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(try Data(contentsOf: destination), foreign)
        XCTAssertEqual(try Data(contentsOf: export.recoveryURL.appendingPathComponent("original")), original)
    }

    func testPublishedExportPreservesInPlaceWriterAndOriginalBackup() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        let original = Data("previous coverage".utf8)
        try original.write(to: destination, options: .atomic)
        let export = try prepareCoverageExport(destination: destination, bytes: Data("new coverage".utf8))
        defer { XCTAssertTrue(closeCoverageExport(export).isEmpty) }
        try publishCoverageExport(export)
        let foreign = Data("changed data".utf8)
        let writer = try FileHandle(forWritingTo: destination)
        try writer.write(contentsOf: foreign)
        try writer.close()
        var current = stat()
        XCTAssertEqual(lstat(destination.path, &current), 0)
        XCTAssertEqual(current.st_ino, export.replacement.identity.inode)
        XCTAssertThrowsError(try restorePublishedCoverageExport(export)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed after publication"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), foreign)
        XCTAssertEqual(try Data(contentsOf: export.recoveryURL.appendingPathComponent("original")), original)
    }

    func testDeniedRestorationRetainsPublishedAndPriorBytes() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        let original = Data("previous coverage".utf8)
        let replacement = Data("new coverage".utf8)
        try original.write(to: destination, options: .atomic)
        let export = try prepareCoverageExport(destination: destination, bytes: replacement)
        defer { XCTAssertTrue(closeCoverageExport(export).isEmpty) }
        try publishCoverageExport(export)
        try denyExportDirectoryWrites(directory)
        XCTAssertThrowsError(try restorePublishedCoverageExport(export)) { error in
            XCTAssertTrue(error.localizedDescription.contains("capture published output"))
            XCTAssertTrue(error.localizedDescription.contains(export.recoveryURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertEqual(try Data(contentsOf: export.recoveryURL.appendingPathComponent("original")), original)
    }

    func testExclusiveOriginalRestorationPreservesNewerPathAndCapturedBytes() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        let original = Data("previous coverage".utf8)
        let replacement = Data("new coverage".utf8)
        try original.write(to: destination, options: .atomic)
        let export = try prepareCoverageExport(destination: destination, bytes: replacement)
        defer { XCTAssertTrue(closeCoverageExport(export).isEmpty) }
        try publishCoverageExport(export)
        try capturePublishedCoverageExport(export)
        let foreign = Data("writer after capture".utf8)
        try foreign.write(to: destination, options: .atomic)
        XCTAssertThrowsError(try restoreCapturedCoverageExport(export)) { error in
            XCTAssertTrue(error.localizedDescription.contains("errno 17"))
            XCTAssertTrue(error.localizedDescription.contains(export.recoveryURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: destination), foreign)
        XCTAssertEqual(try Data(contentsOf: export.recoveryURL.appendingPathComponent("original")), original)
        XCTAssertEqual(try Data(contentsOf: export.recoveryURL.appendingPathComponent("captured")), replacement)
    }

    func testForeignCaptureReturnsWithoutOverwritingNewerPath() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        let original = Data("previous coverage".utf8)
        try original.write(to: destination, options: .atomic)
        let export = try prepareCoverageExport(destination: destination, bytes: Data("new coverage".utf8))
        defer { XCTAssertTrue(closeCoverageExport(export).isEmpty) }
        try publishCoverageExport(export)
        let capturedForeign = Data("foreign before capture".utf8)
        try capturedForeign.write(to: destination, options: .atomic)
        try capturePublishedCoverageExport(export)
        let newest = Data("newer independent writer".utf8)
        try newest.write(to: destination, options: .atomic)
        XCTAssertThrowsError(try restoreCapturedCoverageExport(export)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed during capture"))
            XCTAssertTrue(error.localizedDescription.contains("errno 17"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), newest)
        XCTAssertEqual(try Data(contentsOf: export.recoveryURL.appendingPathComponent("captured")), capturedForeign)
        XCTAssertEqual(try Data(contentsOf: export.recoveryURL.appendingPathComponent("original")), original)
    }

    func testForeignSymlinkCaptureReturnsWithoutFollowingTarget() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        let target = directory.appendingPathComponent("untouched.txt")
        let targetBytes = Data("foreign symlink target".utf8)
        try targetBytes.write(to: target)
        let export = try prepareCoverageExport(destination: destination, bytes: Data("new coverage".utf8))
        defer { XCTAssertTrue(closeCoverageExport(export).isEmpty) }
        try publishCoverageExport(export)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        try capturePublishedCoverageExport(export)
        XCTAssertThrowsError(try restoreCapturedCoverageExport(export)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Captured entry returned"))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    func testPreparedPairRefusesRecreatedParentBeforePublication() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let parent = directory.appendingPathComponent("exports")
        let relocated = directory.appendingPathComponent("relocated-exports")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let coverage = parent.appendingPathComponent("coverage.json")
        let previousCoverage = Data("prior coverage in original directory".utf8)
        try previousCoverage.write(to: coverage)
        let first = try prepareCoverageExport(destination: coverage, bytes: Data("new coverage".utf8))
        defer { XCTAssertTrue(closeCoverageExport(first).isEmpty) }
        try FileManager.default.moveItem(at: parent, to: relocated)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let companion = parent.appendingPathComponent("coverage.performance.json")
        let previousCompanion = Data("prior companion in replacement directory".utf8)
        try previousCompanion.write(to: companion)
        let second = try prepareCoverageExport(destination: companion, bytes: Data("new companion".utf8))
        defer { XCTAssertTrue(closeCoverageExport(second).isEmpty) }
        XCTAssertThrowsError(try validateCoverageExportParents([first, second])) { error in
            XCTAssertTrue(error.localizedDescription.contains("different directory identities"))
            XCTAssertTrue(error.localizedDescription.contains("Neither output file was changed"))
        }
        XCTAssertEqual(try Data(contentsOf: relocated.appendingPathComponent("coverage.json")), previousCoverage)
        XCTAssertEqual(try Data(contentsOf: companion), previousCompanion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocated.appendingPathComponent("coverage.performance.json").path))
        let retainedFirst = relocated.appendingPathComponent(first.recoveryURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: retainedFirst.appendingPathComponent("replacement")), first.replacement.bytes)
        XCTAssertEqual(try Data(contentsOf: second.recoveryURL.appendingPathComponent("replacement")), second.replacement.bytes)
    }

    func testRecoveryDirectorySubstitutionRefusesCleanupBeforeRemovingBackup() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        let previous = Data("prior output".utf8)
        try previous.write(to: destination)
        let export = try prepareCoverageExport(destination: destination, bytes: Data("published output".utf8))
        defer { XCTAssertTrue(closeCoverageExport(export).isEmpty) }
        try publishCoverageExport(export)
        let retained = directory.appendingPathComponent("relocated-recovery")
        try FileManager.default.moveItem(at: export.recoveryURL, to: retained)
        try FileManager.default.createDirectory(at: export.recoveryURL, withIntermediateDirectories: false)
        var replacement = stat()
        XCTAssertEqual(lstat(export.recoveryURL.path, &replacement), 0)
        XCTAssertThrowsError(try removePreparedCoverageExport(export)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery directory pathname changed identity"))
        }
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("original")), previous)
        XCTAssertEqual(try Data(contentsOf: destination), export.replacement.bytes)
        var unchanged = stat()
        XCTAssertEqual(lstat(export.recoveryURL.path, &unchanged), 0)
        XCTAssertEqual(unchanged.st_ino, replacement.st_ino)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: export.recoveryURL.path).isEmpty)
    }

    func testInvalidCoverageDestinationsPreserveExistingPathBeforePreparation() throws {
        let directory = try exportRecoveryDirectory()
        defer { removeExportRecoveryDirectory(directory) }
        let destination = directory.appendingPathComponent("coverage.json")
        let retained = Data("existing destination must remain untouched".utf8)
        try retained.write(to: destination)
        let nulURL = try XCTUnwrap(URL(string: destination.absoluteString + "%00-suffix"))
        XCTAssertTrue(nulURL.path(percentEncoded: false).contains("\0"))
        let nonfileURL = try XCTUnwrap(URL(string: "https://example.invalid/coverage.json"))
        var before = stat()
        XCTAssertEqual(lstat(destination.path, &before), 0)
        for invalid in [nulURL, nonfileURL, URL(fileURLWithPath: "/")] {
            XCTAssertThrowsError(try prepareCoverageExport(destination: invalid, bytes: Data("replacement".utf8))) { error in
                XCTAssertTrue(error.localizedDescription.contains("nonempty filename and no NUL"))
                XCTAssertFalse(error.localizedDescription.contains("\0"))
            }
        }
        var after = stat()
        XCTAssertEqual(lstat(destination.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(try Data(contentsOf: destination), retained)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["coverage.json"])
    }

    private func exportRecoveryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExportRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        guard chmod(directory.path, 0o700) == 0 else { throw ManualToolError(message: "Cannot protect owned export fixture: errno \(errno).") }
        return directory
    }

    private func denyExportDirectoryWrites(_ directory: URL) throws {
        guard geteuid() != 0, chmod(directory.path, 0o555) == 0 else {
            throw ManualToolError(message: "Export integration requires a non-root identity and owned directory mode0555 (errno \(errno)).")
        }
        XCTAssertNotEqual(access(directory.path, W_OK), 0)
    }

    private func removeExportRecoveryDirectory(_ directory: URL) {
        if chmod(directory.path, 0o700) != 0 { XCTFail("Cannot restore owned export fixture permissions: errno \(errno).") }
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Cannot remove owned export fixture: \(error)") }
    }

    func testRecursiveRealManualsAliasesVersionsAndCoverage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Discovery-\(UUID().uuidString)")
        let nested = directory.appendingPathComponent(".hidden/Tool.app/Contents/Resources/fr/man1")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove discovery integration files: \(error)") }
        }
        let launchctl = URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1")
        let ping = URL(fileURLWithPath: "/usr/share/man/man8/ping.8")
        try FileManager.default.copyItem(at: launchctl, to: nested.appendingPathComponent("launchctl.1"))
        try FileManager.default.copyItem(at: launchctl, to: nested.appendingPathComponent("duplicate.1"))
        try FileManager.default.copyItem(at: ping, to: directory.appendingPathComponent("network-reference"))
        try FileManager.default.copyItem(at: ping, to: directory.appendingPathComponent("ping.8special"))
        let gzip = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c", launchctl.path], directory: directory, input: nil)
        try gzip.write(to: nested.appendingPathComponent("compressed.1.gz"))
        try gzip.write(to: directory.appendingPathComponent("documentation.gz"))
        try gzip.write(to: directory.appendingPathComponent("renamed-gzip-documentation"))
        let bzip = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/bzip2"), arguments: ["-c", launchctl.path], directory: directory, input: nil)
        let renamed = directory.appendingPathComponent("renamed-bzip-documentation")
        try bzip.write(to: renamed)
        let compressedDescription = try await manualDescription(source: renamed)
        XCTAssertEqual(compressedDescription, "Interfaces with launchd")
        let legacyCompress = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/compress"), arguments: ["-c", launchctl.path], directory: directory, input: nil)
        let legacySource = directory.appendingPathComponent("renamed-compress-documentation")
        try legacyCompress.write(to: legacySource)
        let legacyDescription = try await manualDescription(source: legacySource)
        let legacyHTML = try await manualHTML(source: legacySource)
        XCTAssertEqual(legacyDescription, "Interfaces with launchd")
        XCTAssertTrue(legacyHTML.contains("bootstrap"))
        try ".so compressed.1.gz\n".write(to: nested.appendingPathComponent("alias.1"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("link.1"), withDestinationURL: launchctl)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("loop"), withDestinationURL: directory)
        try Data("not a manual".utf8).write(to: directory.appendingPathComponent("fake.1"))
        try Data("bad gzip".utf8).write(to: directory.appendingPathComponent("broken.1.gz"))
        try Data("unsupported".utf8).write(to: directory.appendingPathComponent("unknown.1.xz"))
        let version = directory.appendingPathComponent("other/man1")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        var revised = try Data(contentsOf: launchctl)
        revised.append(Data("\n.\\\" Distinct package revision for integration verification\n".utf8))
        try revised.write(to: version.appendingPathComponent("launchctl.1"))
        let plan = DiscoveryPlan(roots: [directory, nested, directory.appendingPathComponent("missing")], allowedNetworkRoots: [], exclusions: [])
        let scan = try await discoverLibrary(plan: plan, previous: [], progress: { _ in })
        XCTAssertFalse(scan.cancelled)
        XCTAssertEqual(scan.pages.count, 5)
        let sourceNames = Set(scan.pages.flatMap(\.locations).map { $0.source.lastPathComponent })
        XCTAssertTrue(sourceNames.contains("renamed-gzip-documentation"))
        XCTAssertTrue(sourceNames.contains("renamed-bzip-documentation"))
        XCTAssertTrue(sourceNames.contains("renamed-compress-documentation"))
        let localized = try XCTUnwrap(scan.pages.first { $0.language == "fr" })
        XCTAssertEqual(localized.locations.count, 5)
        XCTAssertEqual(Set(localized.locations.map(\.name)), ["alias", "compressed", "duplicate", "launchctl", "link"])
        XCTAssertTrue(scan.pages.contains { $0.name.lowercased() == "ping" && $0.source.lastPathComponent == "network-reference" })
        XCTAssertTrue(scan.pages.contains { $0.section == "8special" })
        XCTAssertEqual(Set(scan.coverage.flatMap(\.issues).map(\.kind)), [.excluded, .failed, .unsupported])
        XCTAssertTrue(scan.coverage.flatMap(\.issues).contains { $0.path.hasSuffix("loop") })
        XCTAssertEqual(rankedManuals(pages: scan.pages, query: "launchctl", section: "1", root: nil, fullText: []).count, 3)
        XCTAssertEqual(rankedManuals(pages: scan.pages, query: "compressed", section: "1", root: nil, fullText: []).first?.page.name, "compressed")
        XCTAssertEqual(rankedManuals(pages: scan.pages, query: "launchctl", section: "1", root: nested.path, fullText: []).count, 1)
        let selected = try XCTUnwrap(localized.locations.first { $0.name == "alias" })
        let description = try await manualDescription(source: selected.source)
        XCTAssertEqual(description, "Interfaces with launchd")
        let html = try await manualHTML(source: selected.source)
        XCTAssertTrue(html.contains("bootstrap"))
        let pdf = directory.appendingPathComponent("export.pdf")
        try await renderManual(source: selected.source, destination: pdf)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: pdf)?.string).contains("bootstrap"))
        let refreshed = try await discoverLibrary(plan: plan, previous: scan.pages, progress: { _ in })
        XCTAssertEqual(Set(scan.pages.map(\.id)), Set(refreshed.pages.map(\.id)))
        XCTAssertEqual(refreshed.pages.first { $0.language == "fr" }?.locations.count, 5)
        // A target edit must invalidate a whole-file alias even though the alias metadata is unchanged.
        let revisedGzip = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c", version.appendingPathComponent("launchctl.1").path], directory: directory, input: nil)
        try revisedGzip.write(to: nested.appendingPathComponent("compressed.1.gz"))
        let changed = try await discoverLibrary(plan: plan, previous: scan.pages, progress: { _ in })
        let changedAlias = try XCTUnwrap(changed.pages.first { $0.locations.contains { $0.name == "alias" } })
        XCTAssertNotEqual(changedAlias.fingerprint, localized.fingerprint)
        XCTAssertEqual(changedAlias.locations.count, 2)
        try FileManager.default.removeItem(at: version.appendingPathComponent("launchctl.1"))
        let removed = try await discoverLibrary(plan: plan, previous: scan.pages, progress: { _ in })
        XCTAssertFalse(mergingDiscovery(previous: scan.pages, scan: removed).contains { $0.source.path.hasPrefix(version.path) })
    }

    func testCancellationReachesRunningFilesystemTraversal() async throws {
        let (stream, continuation) = AsyncStream<DiscoveryProgress>.makeStream()
        let worker = Task.detached {
            try await discoverLibrary(plan: DiscoveryPlan(roots: [URL(fileURLWithPath: "/usr/share/man")], allowedNetworkRoots: [], exclusions: []), previous: []) { progress in
                continuation.yield(progress)
            }
        }
        for await progress in stream {
            XCTAssertGreaterThan(progress.directories, 0)
            worker.cancel()
            break
        }
        continuation.finish()
        let result = try await worker.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(try XCTUnwrap(result.coverage.first).completed)
    }

    func testExcludedMeasurementOutputAliasesAndDurableResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryOutput-\(UUID().uuidString)")
        let output = directory.appendingPathComponent("measurement")
        let ordinary = directory.appendingPathComponent("manuals")
        let neighbor = directory.appendingPathComponent("measurement-other")
        for folder in [output, ordinary, neighbor] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove excluded-output integration files: \(error)") }
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: ordinary.appendingPathComponent("launchctl.1"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/ls.1"), to: neighbor.appendingPathComponent("ls.1"))
        let excludedManual = output.appendingPathComponent("du.1")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/du.1"), to: excludedManual)
        let directoryAlias = directory.appendingPathComponent("output-alias")
        let fileAlias = directory.appendingPathComponent("output-file.1")
        let manualAlias = directory.appendingPathComponent("output-manual.1")
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: output)
        try FileManager.default.createSymbolicLink(at: fileAlias, withDestinationURL: excludedManual)
        try ".so \(excludedManual.path)\n".write(to: manualAlias, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("loop"), withDestinationURL: directory)
        let excludedPath = output.resolvingSymlinksInPath().path
        let plan = DiscoveryPlan(roots: [directory], allowedNetworkRoots: [], exclusions: [], traversalExclusions: [
            DiscoveryIssue(path: excludedPath, kind: .excluded, reason: "Owned measurement output.")
        ])
        let checkpointURL = output.appendingPathComponent("checkpoint.json")
        let file = DiscoveryCheckpointFile(url: checkpointURL)
        let request = UUID()
        await file.activate(request)
        let initial = try newDiscoveryCheckpoint(plan: plan, title: "Output exclusion integration")
        let worker = Task.detached {
            try await continueDiscovery(checkpoint: initial, previous: [], progress: { value in
                if value.files > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }, save: { try await file.save($0, request: request) })
        }
        let paused = try await worker.value
        XCTAssertTrue(paused.cancelled)
        let loaded = try await DiscoveryCheckpointFile(url: checkpointURL).load()
        let reopened = try XCTUnwrap(loaded)
        XCTAssertEqual(reopened.plan.traversalExclusions?.map(\.path), [excludedPath])
        let resumed = try await continueDiscovery(checkpoint: reopened, previous: paused.pages, progress: { _ in },
            save: { try await file.save($0, request: request) })
        let fresh = try await discoverLibrary(plan: plan, previous: [], progress: { _ in })
        XCTAssertFalse(resumed.cancelled)
        XCTAssertEqual(resumed.coverage.reduce(0) { $0 + $1.files }, 3)
        XCTAssertEqual(resumed.coverage.reduce(0) { $0 + $1.directories }, 3)
        XCTAssertEqual(Set(resumed.pages.map(\.id)), Set(fresh.pages.map(\.id)))
        XCTAssertEqual(Set(resumed.pages.flatMap(\.locations)), Set(fresh.pages.flatMap(\.locations)))
        XCTAssertEqual(Set(resumed.pages.map(\.name)), ["launchctl", "ls"])
        let issues = resumed.coverage.flatMap(\.issues)
        for path in [output.path, directoryAlias.path, fileAlias.path, manualAlias.path] {
            XCTAssertTrue(issues.contains { $0.path == path && $0.kind == .excluded && $0.reason.contains("Owned measurement output") }, path)
        }
        XCTAssertTrue(issues.contains { $0.path == directory.appendingPathComponent("loop").path && $0.kind == .excluded })
        XCTAssertFalse(issues.contains { $0.kind == .pending || $0.kind == .failed })
        let exported = output.appendingPathComponent("coverage.json")
        try JSONEncoder().encode(resumed.coverage).write(to: exported, options: .atomic)
        let coverage = try JSONDecoder().decode([SourceCoverage].self, from: Data(contentsOf: exported))
        XCTAssertEqual(coverage.flatMap(\.issues), issues)
    }

    func testExplicitChildSelectionSurvivesInformationalParentGap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoverySelected-\(UUID().uuidString)")
        let selected = directory.appendingPathComponent("selected-manuals")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove selected-child integration files: \(error)") }
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/ls.1"), to: selected.appendingPathComponent("ls.1"))
        let plan = DiscoveryPlan(roots: [selected], allowedNetworkRoots: [selected], exclusions: [
            DiscoveryIssue(path: directory.path, kind: .excluded, reason: "Parent volume outside explicitly selected child folders.")
        ])
        let scan = try await discoverLibrary(plan: plan, previous: [], progress: { _ in })
        XCTAssertFalse(scan.cancelled)
        XCTAssertEqual(scan.pages.map(\.name), ["ls"])
        XCTAssertEqual(scan.coverage.first?.files, 1)
        XCTAssertTrue(try XCTUnwrap(scan.coverage.first).issues.isEmpty)
        XCTAssertTrue(scan.coverage.flatMap(\.issues).contains { $0.path == directory.path && $0.kind == .excluded })
    }

    @MainActor
    func testDirectoryAliasesLinkCoverageAcrossPauseAndLegacyResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DirectoryAliases-\(UUID().uuidString)")
        let corpus = directory.appendingPathComponent("corpus")
        let canonical = corpus.appendingPathComponent("canonical")
        let section = canonical.appendingPathComponent("man1")
        let alias = corpus.appendingPathComponent("alternate-man")
        let secondAlias = corpus.appendingPathComponent("second-man")
        let cycle = canonical.appendingPathComponent("ancestor-cycle")
        let library = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove directory-alias integration files: \(error)") }
        }
        for name in ["ls", "du"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/\(name).1"), to: section.appendingPathComponent("\(name).1"))
        }
        for target in [alias, secondAlias] { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: canonical) }
        try FileManager.default.createSymbolicLink(at: cycle, withDestinationURL: canonical)
        let plan = DiscoveryPlan(roots: [canonical, alias, corpus], allowedNetworkRoots: [], exclusions: [])
        let checkpointURL = library.appendingPathComponent("checkpoint.json")
        let checkpointFile = DiscoveryCheckpointFile(url: checkpointURL)
        let request = UUID()
        await checkpointFile.activate(request)
        let worker = Task.detached {
            try await continueDiscovery(checkpoint: newDiscoveryCheckpoint(plan: plan, title: "Directory alias integration"), previous: [],
                progress: { value in if value.files > 0 { withUnsafeCurrentTask { $0?.cancel() } } },
                save: { try await checkpointFile.save($0, request: request) })
        }
        let paused = try await worker.value
        XCTAssertTrue(paused.cancelled)
        let saved = try await checkpointFile.load()
        let reopened = try XCTUnwrap(saved)
        XCTAssertEqual(reopened.visitedRootIndices?.count, reopened.visited.count)
        let resumed = try await continueDiscovery(checkpoint: reopened, previous: paused.pages, progress: { _ in },
            save: { try await checkpointFile.save($0, request: request) })
        let fresh = try await discoverLibrary(plan: plan, previous: [], progress: { _ in })
        XCTAssertFalse(resumed.cancelled)
        XCTAssertEqual(resumed.coverage.reduce(0) { $0 + $1.files }, 2)
        XCTAssertEqual(resumed.coverage.reduce(0) { $0 + $1.directories }, 3)
        XCTAssertEqual(Set(resumed.pages.flatMap(\.locations)), Set(fresh.pages.flatMap(\.locations)))
        XCTAssertEqual(Set(resumed.coverage.flatMap(\.issues)), Set(fresh.coverage.flatMap(\.issues)))
        let issues = resumed.coverage.flatMap(\.issues)
        for path in [alias.path, secondAlias.path] {
            let reference = try XCTUnwrap(issues.first { $0.path == path }?.directoryReference)
            XCTAssertEqual(reference.directory.path, canonical.path)
            XCTAssertEqual(reference.root, canonical)
            XCTAssertEqual(reference.identity, try materializedFileState(canonical).identity)
        }
        let finalCheckpoint = try await checkpointFile.load()
        let completed = try XCTUnwrap(finalCheckpoint)
        try validateDiscoveryCursors(completed)
        let inventoryURL = library.appendingPathComponent("inventory.json")
        try JSONEncoder().encode(resumed).write(to: inventoryURL)
        XCTAssertEqual(try loadDiscovery(inventoryURL).coverage.flatMap(\.issues), issues)
        let exportURL = library.appendingPathComponent("coverage.json")
        try JSONEncoder().encode(resumed.coverage).write(to: exportURL)
        let exported = try JSONDecoder().decode([SourceCoverage].self, from: Data(contentsOf: exportURL))
        try validateCoverageDirectoryReferences(exported)
        XCTAssertEqual(exported.flatMap(\.issues), issues)

        var legacy = reopened
        legacy.visitedRootIndices = nil
        legacy.roots = reopened.roots.map { state in
            var root = state
            root.issues = state.issues.map { DiscoveryIssue(path: $0.path, kind: $0.kind, reason: $0.reason) }
            return root
        }
        let legacyURL = library.appendingPathComponent("legacy-checkpoint.json")
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        let loadedLegacy = try await DiscoveryCheckpointFile(url: legacyURL).load()
        let legacyReopened = try XCTUnwrap(loadedLegacy)
        XCTAssertNil(legacyReopened.visitedRootIndices)
        let legacyResumed = try await continueDiscovery(checkpoint: legacyReopened, previous: paused.pages, progress: { _ in }, save: { _ in })
        XCTAssertEqual(Set(legacyResumed.pages.flatMap(\.locations)), Set(fresh.pages.flatMap(\.locations)))
        let historicalReference = try XCTUnwrap(legacyResumed.coverage.flatMap(\.issues).first { $0.path == alias.path }?.directoryReference)
        XCTAssertEqual(historicalReference.directory.path, canonical.path)
        XCTAssertNil(historicalReference.root)

        let aliasIssue = try XCTUnwrap(issues.first { $0.path == alias.path })
        let renderer = ImageRenderer(content: CoverageIssueView(issue: aliasIssue).padding().frame(width: 660, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor)))
        let image = try XCTUnwrap(renderer.nsImage)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let pixels = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
        attachment.name = "Rendered directory-alias coverage reference"
        attachment.lifetime = .keepAlways
        add(attachment)
        try pixels.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ManPagesCatalog-directory-alias-render.png"), options: .atomic)

        let changedTarget = corpus.appendingPathComponent("changed-target/man1")
        try FileManager.default.createDirectory(at: changedTarget, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: changedTarget.appendingPathComponent("launchctl.1"))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: changedTarget.deletingLastPathComponent())
        let reconciled = try await discoverLibrary(plan: plan, previous: [], progress: { _ in })
        let changedLocation = try XCTUnwrap(reconciled.pages.first { $0.name == "launchctl" }?.locations.first { pathContains(root: alias.path, path: $0.source.path) })
        XCTAssertEqual(changedLocation.root, alias)
        XCTAssertEqual(reconciled.coverage.reduce(0) { $0 + $1.files }, 3)
    }

    func testDirectoryAliasRootOwnershipAndMalformedReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AliasOwnership-\(UUID().uuidString)")
        let corpus = directory.appendingPathComponent("corpus")
        let nested = corpus.appendingPathComponent("man1")
        let alias = directory.appendingPathComponent("installed-man-link")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove alias-ownership integration files: \(error)") }
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/ls.1"), to: nested.appendingPathComponent("ls.1"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/usr/share/man/man1"))
        for roots in [[corpus, nested], [nested, corpus]] {
            let scan = try await scanLibrary(roots: roots)
            XCTAssertFalse(scan.cancelled)
            let issue = try XCTUnwrap(scan.coverage.flatMap(\.issues).first { $0.path == nested.path && $0.directoryReference != nil })
            XCTAssertEqual(issue.directoryReference?.root, roots[0])
            XCTAssertEqual(scan.coverage.reduce(0) { $0 + $1.files }, 1)
            XCTAssertEqual(scan.coverage.reduce(0) { $0 + $1.directories }, 2)
            try validateCoverageDirectoryReferences(scan.coverage)
        }
        let scan = try await scanLibrary(roots: [URL(fileURLWithPath: "/usr/share/man/man1"), alias])
        let reference = try XCTUnwrap(scan.coverage.last?.issues.first?.directoryReference)
        XCTAssertEqual(reference.directory.path, "/usr/share/man/man1")
        XCTAssertEqual(reference.root?.path, "/usr/share/man/man1")
        XCTAssertEqual(scan.coverage.last?.directories, 0)
        XCTAssertEqual(scan.coverage.last?.files, 0)
        let invalidReferences: [DiscoveryDirectoryReference] = [
            DiscoveryDirectoryReference(directory: directory, identity: reference.identity, root: reference.root),
            DiscoveryDirectoryReference(directory: alias, identity: reference.identity, root: alias),
            DiscoveryDirectoryReference(directory: directory, identity: reference.identity, root: nil)
        ]
        for (index, invalidReference) in invalidReferences.enumerated() {
            let invalidIssue = DiscoveryIssue(path: alias.path, kind: .excluded, reason: "Invalid imported reference", directoryReference: invalidReference)
            let invalidCoverage = [scan.coverage[0], SourceCoverage(root: alias, count: 0, directories: 0, files: 0, completed: true, issues: [invalidIssue])]
            let invalidInventory = directory.appendingPathComponent("invalid-reference-\(index).json")
            try JSONEncoder().encode(LibraryScan(pages: scan.pages, coverage: invalidCoverage, cancelled: false)).write(to: invalidInventory)
            XCTAssertThrowsError(try loadDiscovery(invalidInventory))
        }
        var checkpoint = try newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: [nested], allowedNetworkRoots: [], exclusions: []), title: "Malformed ownership")
        let checkpointFile = DiscoveryCheckpointFile(url: directory.appendingPathComponent("completed.json"))
        let request = UUID()
        await checkpointFile.activate(request)
        _ = try await continueDiscovery(checkpoint: checkpoint, previous: [], progress: { _ in }, save: { try await checkpointFile.save($0, request: request) })
        let saved = try await checkpointFile.load()
        checkpoint = try XCTUnwrap(saved)
        let inventoryURL = directory.appendingPathComponent("discovery-v1.json")
        let inventoryBytes = try JSONEncoder().encode(scan)
        try inventoryBytes.write(to: inventoryURL, options: .atomic)
        let planIssue = DiscoveryIssue(path: alias.path, kind: .excluded, reason: "Plan exclusions cannot claim measured aliases", directoryReference: reference)
        let malformedPlans = [
            DiscoveryPlan(roots: checkpoint.plan.roots, allowedNetworkRoots: [], exclusions: [planIssue]),
            DiscoveryPlan(roots: checkpoint.plan.roots, allowedNetworkRoots: [], exclusions: [], traversalExclusions: [planIssue])
        ]
        for plan in malformedPlans {
            let malformed = DiscoveryCheckpoint(version: checkpoint.version, title: checkpoint.title, started: checkpoint.started,
                bootReference: checkpoint.bootReference, bootReferenceClock: checkpoint.bootReferenceClock, plan: plan,
                updated: checkpoint.updated, roots: checkpoint.roots, visited: checkpoint.visited,
                visitedRootIndices: checkpoint.visitedRootIndices, pages: checkpoint.pages, peakPending: checkpoint.peakPending)
            let malformedBytes = try JSONEncoder().encode(malformed)
            let checkpointURL = directory.appendingPathComponent("completed.json")
            try malformedBytes.write(to: checkpointURL, options: .atomic)
            do {
                _ = try await checkpointFile.load()
                XCTFail("A plan exclusion cannot carry a measured directory reference")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Cannot resume"), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: checkpointURL), malformedBytes)
            XCTAssertEqual(try Data(contentsOf: inventoryURL), inventoryBytes)
        }
        let identity = try XCTUnwrap(checkpoint.visited.keys.first)
        checkpoint.visitedRootIndices?[identity] = 1
        XCTAssertThrowsError(try validateDiscoveryCursors(checkpoint))
    }

    func testDirectoryAliasOwnershipAfterInaccessibleParent() async throws {
        guard geteuid() != 0 else { throw XCTSkip("A non-root test host is required to exercise directory access denial.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AliasPermission-\(UUID().uuidString)")
        let parent = directory.appendingPathComponent("parent")
        let nested = parent.appendingPathComponent("man1")
        let alias = directory.appendingPathComponent("nested-alias")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/ls.1"), to: nested.appendingPathComponent("ls.1"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
                try FileManager.default.removeItem(at: directory)
            } catch { XCTFail("Cannot restore and remove alias-permission integration files: \(error)") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: parent.path)
        let plan = DiscoveryPlan(roots: [parent, nested, alias], allowedNetworkRoots: [], exclusions: [])
        let scan = try await discoverLibrary(plan: plan, previous: [], progress: { value in
            if value.path == parent.path {
                do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
                catch { XCTFail("Cannot restore test-owned parent access: \(error)") }
            }
        })
        XCTAssertEqual(scan.coverage[0].directories, 0)
        XCTAssertEqual(scan.coverage[0].issues.first?.kind, .inaccessible)
        XCTAssertEqual(scan.coverage[1].directories, 1)
        XCTAssertEqual(scan.coverage[1].files, 1)
        let reference = try XCTUnwrap(scan.coverage[2].issues.first?.directoryReference)
        XCTAssertEqual(reference.directory.path, nested.path)
        XCTAssertEqual(reference.root, nested)
        try validateCoverageDirectoryReferences(scan.coverage)
    }

    @MainActor
    func testStoreCancellationFailureRetentionAndPersistentIncrementalRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryStore-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("manuals")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("launchctl.1")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: source)
        let suite = "DiscoveryStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set([root.path], forKey: "manualRoots")
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            try XCTUnwrap(UserDefaults(suiteName: suite)).removePersistentDomain(forName: suite)
            do { try await fixture.remove() }
            catch { XCTFail("Cannot remove discovery store integration files: \(error)") }
        }
        let store = LibraryStore(directory: directory.appendingPathComponent("index"), defaults: defaults)
        fixture.track(store)
        store.scanSelectedRoots()
        try await finished(store)
        let first = try XCTUnwrap(store.pages.first)
        XCTAssertEqual(first.description, "Interfaces with launchd")
        XCTAssertEqual(store.sourceRoots, [root.path])
        let export = directory.appendingPathComponent("coverage.json")
        try store.exportCoverage(to: export)
        let legacy = try JSONDecoder().decode([SourceCoverage].self, from: Data(contentsOf: export))
        XCTAssertEqual(legacy.first?.files, 1)
        let performance = try JSONDecoder().decode(ScanPerformanceReport.self, from: Data(contentsOf: directory.appendingPathComponent("coverage.performance.json")))
        XCTAssertEqual(performance.state, .completed)
        XCTAssertEqual(performance.discovery.files, 1)
        XCTAssertEqual(performance.indexing?.succeeded, 1)
        XCTAssertEqual(performance.indexing?.failed, 0)
        let companion = directory.appendingPathComponent("coverage.performance.json")
        let coverageBytes = try Data(contentsOf: export)
        let performanceBytes = try Data(contentsOf: companion)
        try store.exportCoverage(to: export)
        XCTAssertEqual(try Data(contentsOf: export), coverageBytes)
        XCTAssertEqual(try Data(contentsOf: companion), performanceBytes)
        XCTAssertEqual(try loadScanPerformance(companion).scanID, store.performanceReport?.scanID)

        let unmeasured = LibraryStore(directory: directory.appendingPathComponent("unmeasured"), defaults: defaults)
        fixture.track(unmeasured)
        XCTAssertThrowsError(try unmeasured.exportCoverage(to: export)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no measured scan diagnostics"))
            XCTAssertTrue(error.localizedDescription.contains("Neither output file was changed"))
        }
        XCTAssertEqual(try Data(contentsOf: export), coverageBytes)
        XCTAssertEqual(try Data(contentsOf: companion), performanceBytes)

        let retainedCompanion = directory.appendingPathComponent("retained-performance.json")
        try FileManager.default.moveItem(at: companion, to: retainedCompanion)
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: false)
        let marker = companion.appendingPathComponent("owned-conflict.txt")
        let markerBytes = Data("Retained companion-path directory contents.".utf8)
        try markerBytes.write(to: marker)
        XCTAssertThrowsError(try store.exportCoverage(to: export)) { error in
            XCTAssertTrue(error.localizedDescription.contains(companion.path))
            XCTAssertTrue(error.localizedDescription.contains("Neither output file was changed"))
        }
        XCTAssertEqual(try Data(contentsOf: export), coverageBytes)
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        XCTAssertEqual(try Data(contentsOf: retainedCompanion), performanceBytes)
        try FileManager.default.removeItem(at: companion)
        try FileManager.default.moveItem(at: retainedCompanion, to: companion)
        try store.exportCoverage(to: export)
        XCTAssertEqual(try Data(contentsOf: export), coverageBytes)
        XCTAssertEqual(try Data(contentsOf: companion), performanceBytes)
        let oversizedBackup = directory.appendingPathComponent("retained-before-oversized-performance.json")
        try FileManager.default.moveItem(at: companion, to: oversizedBackup)
        let sparseDescriptor = open(companion.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard sparseDescriptor >= 0 else { throw ManualToolError(message: "Cannot create owned oversized export fixture: errno \(errno).") }
        let oversizedLength: off_t = 64 * 1024 * 1024 + 1
        let truncated = ftruncate(sparseDescriptor, oversizedLength)
        let truncateError = errno
        let closed = close(sparseDescriptor)
        guard truncated == 0, closed == 0 else {
            throw ManualToolError(message: "Cannot prepare owned sparse export fixture: ftruncate=\(truncated), errno=\(truncateError), close=\(closed).")
        }
        var beforeOversizedCoverage = stat()
        var beforeOversizedCompanion = stat()
        XCTAssertEqual(lstat(export.path, &beforeOversizedCoverage), 0)
        XCTAssertEqual(lstat(companion.path, &beforeOversizedCompanion), 0)
        XCTAssertEqual(beforeOversizedCompanion.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(beforeOversizedCompanion.st_size, oversizedLength)
        XCTAssertLessThan(beforeOversizedCompanion.st_blocks * 512, oversizedLength, "The owned fixture must be sparse rather than consuming 64 MiB of storage.")
        XCTAssertThrowsError(try store.exportCoverage(to: export)) { error in
            XCTAssertTrue(error.localizedDescription.contains(companion.path))
            XCTAssertTrue(error.localizedDescription.contains("64 MiB"))
            XCTAssertTrue(error.localizedDescription.contains("Choose a new export destination"))
            XCTAssertTrue(error.localizedDescription.contains("Neither output file was changed"))
        }
        var afterOversizedCoverage = stat()
        var afterOversizedCompanion = stat()
        XCTAssertEqual(lstat(export.path, &afterOversizedCoverage), 0)
        XCTAssertEqual(lstat(companion.path, &afterOversizedCompanion), 0)
        XCTAssertEqual(try Data(contentsOf: export), coverageBytes)
        XCTAssertEqual(try Data(contentsOf: oversizedBackup), performanceBytes)
        XCTAssertEqual(afterOversizedCoverage.st_ino, beforeOversizedCoverage.st_ino)
        XCTAssertEqual(afterOversizedCompanion.st_ino, beforeOversizedCompanion.st_ino)
        XCTAssertEqual(afterOversizedCompanion.st_size, oversizedLength)
        try FileManager.default.removeItem(at: companion)
        try FileManager.default.moveItem(at: oversizedBackup, to: companion)
        let deniedFolder = directory.appendingPathComponent("write-denied")
        try FileManager.default.createDirectory(at: deniedFolder, withIntermediateDirectories: false)
        let deniedCoverage = deniedFolder.appendingPathComponent("coverage.json")
        let deniedCompanion = deniedFolder.appendingPathComponent("coverage.performance.json")
        try store.exportCoverage(to: deniedCoverage)
        guard geteuid() != 0, chmod(deniedFolder.path, 0o555) == 0 else {
            throw ManualToolError(message: "Coverage write-denial integration requires a non-root identity and an owned folder with mode0555 (errno \(errno)).")
        }
        defer {
            if chmod(deniedFolder.path, 0o700) != 0 { XCTFail("Cannot restore owned export folder permissions: errno \(errno).") }
        }
        XCTAssertNotEqual(access(deniedFolder.path, W_OK), 0, "Verify actual parent-directory write denial under this identity.")
        var beforeDenied = stat()
        var beforeCompanion = stat()
        XCTAssertEqual(lstat(deniedCoverage.path, &beforeDenied), 0)
        XCTAssertEqual(lstat(deniedCompanion.path, &beforeCompanion), 0)
        XCTAssertThrowsError(try store.exportCoverage(to: deniedCoverage)) { error in
            XCTAssertTrue(error.localizedDescription.contains(deniedCoverage.path))
            XCTAssertTrue(error.localizedDescription.contains("Neither output file was changed"))
            XCTAssertFalse(error.localizedDescription.contains("Restoration failed"))
        }
        XCTAssertEqual(try Data(contentsOf: deniedCoverage), coverageBytes)
        XCTAssertEqual(try Data(contentsOf: deniedCompanion), performanceBytes)
        var afterDenied = stat()
        var afterCompanion = stat()
        XCTAssertEqual(lstat(deniedCoverage.path, &afterDenied), 0)
        XCTAssertEqual(lstat(deniedCompanion.path, &afterCompanion), 0)
        XCTAssertEqual(afterDenied.st_ino, beforeDenied.st_ino, "A failed first replacement must not rewrite the original.")
        XCTAssertEqual(afterCompanion.st_ino, beforeCompanion.st_ino, "An unattempted companion must not be rewritten.")
        let saved = try Data(contentsOf: directory.appendingPathComponent("index/discovery-v1.json"))
        store.scanSelectedRoots()
        store.stop()
        try await finished(store)
        XCTAssertEqual(store.pages.first?.id, first.id)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index/discovery-v1.json")), saved)
        let moved = directory.appendingPathComponent("temporarily-unavailable")
        try FileManager.default.moveItem(at: root, to: moved)
        store.scanSelectedRoots()
        try await finished(store)
        XCTAssertEqual(store.pages.first?.id, first.id)
        XCTAssertTrue(store.coverage.flatMap(\.issues).contains { $0.kind == .failed })
        XCTAssertEqual(store.sourceRoots, [root.path])
        try FileManager.default.moveItem(at: moved, to: root)
        let reopened = LibraryStore(directory: directory.appendingPathComponent("index"), defaults: defaults)
        fixture.track(reopened)
        reopened.scanSelectedRoots()
        try await finished(reopened)
        XCTAssertEqual(reopened.pages.first?.id, first.id)
        XCTAssertEqual(reopened.indexedCount, 1)
        XCTAssertEqual(reopened.sourceRoots, [root.path])
        reopened.scanSelectedRoots()
        reopened.scanSelectedRoots()
        try await finished(reopened)
        XCTAssertEqual(reopened.pages.count, 1)
        XCTAssertNil(reopened.errorMessage)
        let inventory = directory.appendingPathComponent("index/discovery-v1.json")
        let priorScan = try loadDiscovery(inventory)
        let priorReportID = try XCTUnwrap(reopened.performanceReport?.scanID)
        try FileManager.default.moveItem(at: inventory, to: directory.appendingPathComponent("before-indexing-only.json"))
        reopened.continueIndexing()
        try await finished(reopened)
        XCTAssertNil(reopened.errorMessage)
        let rewritten = try loadDiscovery(inventory)
        XCTAssertEqual(Set(rewritten.pages.map(\.id)), Set(priorScan.pages.map(\.id)))
        XCTAssertTrue(try XCTUnwrap(rewritten.pages.first).indexed)
        XCTAssertNotEqual(reopened.performanceReport?.scanID, priorReportID)
        XCTAssertEqual(reopened.performanceReport?.indexing?.total, 0)
        XCTAssertEqual(reopened.sourceRoots, [root.path])
        reopened.fullText = true
        reopened.query = "bootstrap"
        let retained = await reopened.firstResultForCurrentSearch()
        XCTAssertEqual(retained?.id, first.id)
    }

    @MainActor
    func testLegacyCheckpointRetainsRealInventoryAndSearchIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryLegacy-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("manuals")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"),
                                        to: root.appendingPathComponent("launchctl.1"))
        let suite = "DiscoveryLegacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set([root.path], forKey: "manualRoots")
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            try XCTUnwrap(UserDefaults(suiteName: suite)).removePersistentDomain(forName: suite)
            do { try await fixture.remove() }
            catch { XCTFail("Cannot remove legacy-checkpoint integration files: \(error)") }
        }
        let library = directory.appendingPathComponent("index")
        let store = LibraryStore(directory: library, defaults: defaults)
        fixture.track(store)
        store.scanSelectedRoots()
        try await finished(store)
        let page = try XCTUnwrap(store.pages.first)
        XCTAssertEqual(store.indexedCount, 1)
        let pause = store.$scanProgress.compactMap { $0 }.first { $0.files > 0 }.sink { _ in store.stop() }
        defer { pause.cancel() }
        store.scanSelectedRoots()
        try await finished(store)
        XCTAssertEqual(store.phase, .paused)
        let inventoryURL = library.appendingPathComponent("discovery-v1.json")
        let checkpointURL = library.appendingPathComponent("scan-checkpoint-v1.json")
        let inventory = try Data(contentsOf: inventoryURL)
        let checkpoint = try Data(contentsOf: checkpointURL)
        XCTAssertEqual(try JSONDecoder().decode(DiscoveryCheckpoint.self, from: checkpoint).version, 2)
        let text = try XCTUnwrap(String(data: checkpoint, encoding: .utf8))
        let version = try XCTUnwrap(text.range(of: "\"version\":2"))
        let legacy = Data(text.replacingCharacters(in: version, with: "\"version\":1").utf8)
        XCTAssertEqual(legacy.count, checkpoint.count)
        try legacy.write(to: checkpointURL, options: .atomic)
        let reopened = LibraryStore(directory: library, defaults: defaults)
        fixture.track(reopened)
        reopened.openLibrary()
        for _ in 0..<1000 {
            if reopened.errorMessage != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let error = try XCTUnwrap(reopened.errorMessage).lowercased()
        XCTAssertTrue(error.contains("version 1"))
        XCTAssertTrue(error.contains("fresh scan"))
        XCTAssertEqual(try Data(contentsOf: checkpointURL), legacy)
        XCTAssertEqual(try Data(contentsOf: inventoryURL), inventory)
        XCTAssertEqual(reopened.pages.first?.id, page.id)
        let retained = await reopened.firstResultForCurrentSearch()
        XCTAssertEqual(retained?.id, page.id, "Loaded manuals remain searchable when their scan checkpoint cannot resume")
        reopened.fullText = true
        reopened.query = "bootstrap"
        let indexed = await reopened.firstResultForCurrentSearch()
        XCTAssertEqual(indexed?.id, page.id)
    }

    func testDurablePauseResumeAndStaleCheckpointIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryResume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = await LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            do { try await fixture.remove() }
            catch { XCTFail("Cannot remove resume integration files: \(error)") }
        }
        let url = directory.appendingPathComponent("scan-checkpoint-v1.json")
        let file = DiscoveryCheckpointFile(url: url)
        let request = UUID()
        await file.activate(request)
        let initial = try newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: [URL(fileURLWithPath: "/usr/share/man")], allowedNetworkRoots: [], exclusions: []), title: "Integration Scan")
        let (stream, continuation) = AsyncStream<DiscoveryProgress>.makeStream()
        let worker = Task.detached {
            try await continueDiscovery(checkpoint: initial, previous: [], progress: { value in
                if value.manuals > 0 { continuation.yield(value) }
            }, save: { try await file.save($0, request: request) })
        }
        for await value in stream {
            XCTAssertGreaterThan(value.manuals, 0)
            worker.cancel()
            break
        }
        continuation.finish()
        let partial = try await worker.value
        XCTAssertTrue(partial.cancelled)
        XCTAssertFalse(partial.pages.isEmpty)
        XCTAssertTrue(partial.coverage.flatMap(\.issues).contains { $0.kind == .pending })
        // Reopen from disk as a new process would, rather than using the live worker's state.
        let reopenedFile = DiscoveryCheckpointFile(url: url)
        let loaded = try await reopenedFile.load()
        let checkpoint = try XCTUnwrap(loaded)
        XCTAssertGreaterThan(checkpoint.pendingCount, 0)
        let resumed = try await continueDiscovery(checkpoint: checkpoint, previous: partial.pages, progress: { _ in }, save: { _ in })
        let fresh = try await scanLibrary(roots: initial.plan.roots)
        XCTAssertFalse(resumed.cancelled)
        XCTAssertEqual(Set(resumed.pages.map(\.id)), Set(fresh.pages.map(\.id)))
        XCTAssertEqual(Set(resumed.pages.flatMap(\.locations).map(\.source)), Set(fresh.pages.flatMap(\.locations).map(\.source)))
        XCTAssertEqual(resumed.coverage.first?.files, fresh.coverage.first?.files)
        XCTAssertFalse(resumed.coverage.flatMap(\.issues).contains { $0.kind == .pending })
        let newer = UUID()
        await file.activate(newer)
        try await file.save(initial, request: newer)
        try await file.save(checkpoint, request: request)
        let latest = try await file.load()
        XCTAssertEqual(latest?.pendingCount, 1, "A stale worker must not overwrite the new checkpoint")
        let retainedCheckpoint = try Data(contentsOf: url)
        guard geteuid() != 0, chmod(directory.path, 0o555) == 0 else {
            throw ManualToolError(message: "Checkpoint write-denial verification requires a non-root identity and an owned mode0555 folder (errno \(errno)).")
        }
        defer {
            if chmod(directory.path, 0o700) != 0 { XCTFail("Cannot restore owned checkpoint folder permissions: errno \(errno).") }
        }
        XCTAssertNotEqual(access(directory.path, W_OK), 0)
        do {
            try await file.save(checkpoint, request: newer)
            XCTFail("Checkpoint replacement must report verified parent-directory write denial")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(url.path), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Cannot save resumable discovery checkpoint"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Check available storage and write access"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: url), retainedCheckpoint)
        guard chmod(directory.path, 0o700) == 0 else { throw ManualToolError(message: "Cannot restore owned checkpoint directory: errno \(errno).") }
        try JSONEncoder().encode(partial).write(to: directory.appendingPathComponent("discovery-v1.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DiscoveryResume.\(UUID().uuidString)"))
        let store = await LibraryStore(directory: directory, defaults: defaults)
        await fixture.track(store)
        await store.openLibrary()
        for _ in 0..<1000 {
            if await store.resumableScan { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let restored = await store.pages
        let phase = await store.phase
        let busy = await store.isIndexing
        XCTAssertFalse(restored.isEmpty)
        XCTAssertEqual(phase, .paused)
        XCTAssertFalse(busy, "Opening the app must not discard or restart a paused scan")
    }

    func testStreamedWideDirectoryCancellationAndDurableResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryWide-\(UUID().uuidString)")
        let root = try wideDirectory(directory)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove streamed discovery integration files: \(error)") }
        }
        let (partial, checkpoint) = try await pausedWideDirectory(root, directory.appendingPathComponent("checkpoint.json"))
        let partialCoverage = try XCTUnwrap(partial.coverage.first)
        XCTAssertTrue(partial.cancelled)
        XCTAssertGreaterThan(partialCoverage.files, 0)
        XCTAssertLessThan(partialCoverage.files, 257)
        XCTAssertEqual(partialCoverage.directories, 1)
        XCTAssertGreaterThan(checkpoint.pendingCount, 0)
        XCTAssertLessThanOrEqual(checkpoint.pendingCount, 2, "A single directory must not queue every sibling URL")
        XCTAssertEqual(checkpoint.snapshot.coverage.first?.files, partialCoverage.files)
        XCTAssertTrue(partial.coverage.flatMap(\.issues).contains { $0.kind == .pending })
        let resumed = try await continueDiscovery(checkpoint: checkpoint, previous: partial.pages, progress: { _ in }, save: { _ in })
        let fresh = try await scanLibrary(roots: [root])
        XCTAssertFalse(resumed.cancelled)
        XCTAssertEqual(resumed.coverage.first?.files, 257)
        XCTAssertEqual(resumed.coverage.first?.directories, 1)
        XCTAssertEqual(resumed.coverage.first?.files, fresh.coverage.first?.files)
        XCTAssertEqual(Set(resumed.pages.map(\.id)), Set(fresh.pages.map(\.id)))
        XCTAssertEqual(resumed.pages.flatMap(\.locations).map(\.source), [root.appendingPathComponent("launchctl.1")])
        XCTAssertFalse(resumed.coverage.flatMap(\.issues).contains { $0.kind == .pending })
    }

    func testMetadataOnlyDirectoryChangePreservesStreamedResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryWideMetadata-\(UUID().uuidString)")
        let root = try wideDirectory(directory)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove directory-metadata integration files: \(error)") }
        }
        let (partial, checkpoint) = try await pausedWideDirectory(root, directory.appendingPathComponent("checkpoint.json"))
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ManualToolError(message: "Cannot open owned directory \(root.path) for metadata verification: \(String(cString: strerror(errno))) (errno \(errno)).")
        }
        defer {
            if close(descriptor) != 0 { XCTFail("Cannot close owned directory descriptor: \(String(cString: strerror(errno))) (errno \(errno)).") }
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw ManualToolError(message: "Cannot inspect owned directory before its metadata change: \(String(cString: strerror(errno))) (errno \(errno)).")
        }
        let attribute = "org.ManPagesCatalog.IntegrationTest"
        let value = Data("Benign metadata-only resume integration case.".utf8)
        let status = value.withUnsafeBytes { bytes in
            setxattr(root.path, attribute, bytes.baseAddress, bytes.count, 0, XATTR_CREATE)
        }
        guard status == 0 else {
            throw ManualToolError(message: "Cannot set benign owned-directory attribute \(attribute) at \(root.path): \(String(cString: strerror(errno))) (errno \(errno)).")
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw ManualToolError(message: "Cannot inspect owned directory after its metadata change: \(String(cString: strerror(errno))) (errno \(errno)).")
        }
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertTrue(before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec,
                      "The benign attribute must establish an actual ctime-only change")
        let resumed = try await continueDiscovery(checkpoint: checkpoint, previous: partial.pages, progress: { _ in }, save: { _ in })
        let fresh = try await scanLibrary(roots: [root])
        XCTAssertFalse(resumed.cancelled)
        XCTAssertTrue(try XCTUnwrap(resumed.coverage.first).completed)
        XCTAssertEqual(resumed.coverage.first?.files, 257)
        XCTAssertEqual(resumed.coverage.first?.files, fresh.coverage.first?.files)
        XCTAssertEqual(Set(resumed.pages.map(\.id)), Set(fresh.pages.map(\.id)))
        XCTAssertEqual(Set(resumed.pages.flatMap(\.locations).map(\.source)), Set(fresh.pages.flatMap(\.locations).map(\.source)))
        XCTAssertEqual(resumed.pages.flatMap(\.locations).map(\.source), [root.appendingPathComponent("launchctl.1")])
        XCTAssertFalse(resumed.coverage.flatMap(\.issues).contains { $0.kind == .pending })
    }

    func testOpenedDirectoryStreamRejectsReboundPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryWideRebound-\(UUID().uuidString)")
        let root = try wideDirectory(directory)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove rebound-directory integration files: \(error)") }
        }
        let initial = try materializedFileState(root)
        let stream = try DiscoveryDirectoryStream(directory: root, expectedIdentity: initial.identity, allowedNetworkRoots: [])
        defer {
            do { try stream.close() }
            catch { XCTFail("Cannot close rebound-directory integration stream: \(error)") }
        }
        let moved = directory.appendingPathComponent("moved-manuals")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var movedState = stat()
        guard lstat(moved.path, &movedState) == 0 else {
            throw ManualToolError(message: "Cannot inspect moved owned directory \(moved.path): \(String(cString: strerror(errno))) (errno \(errno)).")
        }
        XCTAssertTrue(sameDiscoveryDirectoryNamespace(current: discoveryDirectoryMetadata(movedState), saved: stream.metadata),
                      "Moving the owned directory must leave its opened inode and entry mtime unchanged")
        XCTAssertNotEqual(try materializedFileState(root).identity, stream.metadata.identity)
        XCTAssertThrowsError(try stream.verifyUnchanged()) { error in
            XCTAssertEqual((error as? DiscoveryAccessError)?.kind, .failed)
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains(root.path.lowercased()), message)
            XCTAssertTrue(message.contains("fresh scan"), message)
        }
    }

    func testChangedStreamedDirectoryRejectsResumeWithoutReplacingCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryWideChanged-\(UUID().uuidString)")
        let root = try wideDirectory(directory)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove changed-directory integration files: \(error)") }
        }
        let checkpointURL = directory.appendingPathComponent("checkpoint.json")
        let (partial, checkpoint) = try await pausedWideDirectory(root, checkpointURL)
        let saved = try Data(contentsOf: checkpointURL)
        try Data("New nonmanual content after the pause.\n".utf8).write(to: root.appendingPathComponent("added.data"))
        let file = DiscoveryCheckpointFile(url: checkpointURL)
        let request = UUID()
        await file.activate(request)
        do {
            _ = try await continueDiscovery(checkpoint: checkpoint, previous: partial.pages, progress: { _ in },
                                            save: { try await file.save($0, request: request) })
            XCTFail("A changed directory must require a fresh scan rather than accepting an old enumeration cursor")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("fresh scan"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: checkpointURL), saved, "A failed resume must preserve the durable checkpoint")
        let loaded = try await file.load()
        let retained = try XCTUnwrap(loaded)
        XCTAssertEqual(retained.snapshot.coverage.first?.files, partial.coverage.first?.files)
        XCTAssertEqual(Set(retained.snapshot.pages.map(\.id)), Set(partial.pages.map(\.id)))
        XCTAssertGreaterThan(retained.pendingCount, 0)
    }

    func testBootClockProvenanceAndMismatchPreserveDurableResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryBootClock-\(UUID().uuidString)")
        let root = try wideDirectory(directory)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove boot-clock integration files: \(error)") }
        }
        let checkpointURL = directory.appendingPathComponent("checkpoint.json")
        let inventoryURL = directory.appendingPathComponent("discovery-v1.json")
        let (partial, checkpoint) = try await pausedWideDirectory(root, checkpointURL)
        XCTAssertTrue(partial.cancelled)
        XCTAssertGreaterThan(checkpoint.pendingCount, 0)
        XCTAssertEqual(checkpoint.bootReferenceClock, .continuous)
        let file = DiscoveryCheckpointFile(url: checkpointURL)
        let request = UUID()
        await file.activate(request)
        try await file.saveInventory(partial, request: request)
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        let inventoryBytes = try Data(contentsOf: inventoryURL)
        let references: [(clock: DiscoveryBootReferenceClock?, reference: Date)] = [
            (.continuous, checkpoint.bootReference),
            (nil, Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime))
        ]
        for reference in references {
            let compatible = DiscoveryCheckpoint(version: checkpoint.version, title: checkpoint.title, started: checkpoint.started,
                bootReference: reference.reference, bootReferenceClock: reference.clock, plan: checkpoint.plan,
                updated: checkpoint.updated, roots: checkpoint.roots, visited: checkpoint.visited,
                visitedRootIndices: checkpoint.visitedRootIndices, pages: checkpoint.pages, peakPending: checkpoint.peakPending)
            try JSONEncoder().encode(compatible).write(to: checkpointURL, options: .atomic)
            let loaded = try await file.load()
            XCTAssertEqual(try XCTUnwrap(loaded).bootReferenceClock, reference.clock)
            let changed = DiscoveryCheckpoint(version: compatible.version, title: compatible.title, started: compatible.started,
                bootReference: reference.reference.addingTimeInterval(-3600), bootReferenceClock: reference.clock,
                plan: compatible.plan, updated: compatible.updated, roots: compatible.roots, visited: compatible.visited,
                visitedRootIndices: compatible.visitedRootIndices, pages: compatible.pages, peakPending: compatible.peakPending)
            let incompatibleBytes = try JSONEncoder().encode(changed)
            try incompatibleBytes.write(to: checkpointURL, options: .atomic)
            do {
                _ = try await file.load()
                XCTFail("A mismatched boot reference must refuse resume for both continuous and legacy clocks")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("boot"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("fresh scan"), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: checkpointURL), incompatibleBytes)
            XCTAssertEqual(try Data(contentsOf: inventoryURL), inventoryBytes)
        }
        let encoded = try XCTUnwrap(String(data: checkpointBytes, encoding: .utf8))
        let unsupported = encoded.replacingOccurrences(of: "\"bootReferenceClock\":\"continuous\"", with: "\"bootReferenceClock\":\"unsupported\"")
        XCTAssertNotEqual(unsupported, encoded)
        let unsupportedBytes = Data(unsupported.utf8)
        try unsupportedBytes.write(to: checkpointURL, options: .atomic)
        do {
            _ = try await file.load()
            XCTFail("An unsupported boot clock must not be interpreted as a continuous or legacy clock")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cannot resume"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: checkpointURL), unsupportedBytes)
        XCTAssertEqual(try Data(contentsOf: inventoryURL), inventoryBytes)
        try checkpointBytes.write(to: checkpointURL, options: .atomic)
        let reopened = try await file.load()
        let resumed = try await continueDiscovery(checkpoint: try XCTUnwrap(reopened), previous: partial.pages,
            progress: { _ in }, save: { try await file.save($0, request: request) })
        let fresh = try await scanLibrary(roots: [root])
        XCTAssertFalse(resumed.cancelled)
        XCTAssertEqual(Set(resumed.pages.flatMap(\.locations)), Set(fresh.pages.flatMap(\.locations)))
        XCTAssertEqual(resumed.coverage.first?.files, fresh.coverage.first?.files)
        XCTAssertEqual(try Data(contentsOf: inventoryURL), inventoryBytes)
    }

    func testReplacedRootRejectsDurableResumeAndFreshScanReconcilesContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryRootReplacement-\(UUID().uuidString)")
        let root = try wideDirectory(directory)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove root-replacement integration files: \(error)") }
        }
        let prior = try await scanLibrary(roots: [root])
        let priorManual = try XCTUnwrap(prior.pages.first)
        XCTAssertEqual(priorManual.name, "launchctl")
        let checkpointURL = directory.appendingPathComponent("checkpoint.json")
        let inventoryURL = directory.appendingPathComponent("discovery-v1.json")
        let (partial, checkpoint) = try await pausedWideDirectory(root, checkpointURL)
        XCTAssertTrue(partial.cancelled)
        XCTAssertGreaterThan(checkpoint.pendingCount, 0)
        let retained = LibraryScan(pages: mergingDiscovery(previous: prior.pages, scan: partial), coverage: partial.coverage, cancelled: true)
        try JSONEncoder().encode(retained).write(to: inventoryURL, options: .atomic)
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        let inventoryBytes = try Data(contentsOf: inventoryURL)
        let oldIdentity = try materializedFileState(root).identity
        let moved = directory.appendingPathComponent("original-root")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/ls.1"), to: root.appendingPathComponent("ls.1"))
        XCTAssertEqual(try materializedFileState(moved).identity, oldIdentity)
        XCTAssertNotEqual(try materializedFileState(root).identity, oldIdentity)

        let file = DiscoveryCheckpointFile(url: checkpointURL)
        let loaded = try await file.load()
        let reopened = try XCTUnwrap(loaded)
        let request = UUID()
        await file.activate(request)
        do {
            _ = try await continueDiscovery(checkpoint: reopened, previous: retained.pages, progress: { _ in },
                                            save: { try await file.save($0, request: request) })
            XCTFail("A different root at the saved path must not reuse the original directory cursor")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(root.path), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.lowercased().contains("fresh scan"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.lowercased().contains("identity"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointBytes)
        XCTAssertEqual(try Data(contentsOf: inventoryURL), inventoryBytes)
        let reopenedInventory = try loadDiscovery(inventoryURL)
        XCTAssertEqual(Set(reopenedInventory.pages.map(\.id)), Set(retained.pages.map(\.id)))
        XCTAssertEqual(reopenedInventory.coverage.first?.files, retained.coverage.first?.files)
        XCTAssertEqual(rankedManuals(pages: reopenedInventory.pages, query: "launchctl", section: nil, root: nil, fullText: []).first?.page.id, priorManual.id)

        let fresh = try await discoverLibrary(plan: reopened.plan, previous: reopenedInventory.pages, progress: { _ in })
        XCTAssertFalse(fresh.cancelled)
        XCTAssertEqual(fresh.coverage.first?.files, 1)
        XCTAssertEqual(fresh.coverage.first?.directories, 1)
        XCTAssertTrue(try XCTUnwrap(fresh.coverage.first).completed)
        XCTAssertTrue(try XCTUnwrap(fresh.coverage.first).issues.isEmpty)
        XCTAssertEqual(fresh.pages.map(\.name), ["ls"])
        XCTAssertEqual(mergingDiscovery(previous: reopenedInventory.pages, scan: fresh).map(\.name), ["ls"])
        XCTAssertNotEqual(fresh.pages.first?.id, priorManual.id)
        XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointBytes, "An independent fresh scan does not replace the retained checkpoint")
        XCTAssertEqual(try Data(contentsOf: inventoryURL), inventoryBytes)
    }

    func testIncrementalCoverageKeepsFormatterDiagnosticsSeparate() async throws {
        let source = URL(fileURLWithPath: "/usr/share/man/man1/atos.1")
        let scan = try await scanLibrary(roots: [source])
        var page = try XCTUnwrap(scan.pages.first)
        let formatted = try await formattedManualText(source: source)
        page.description = descriptionFromFormattedManual(formatted.text)
        page.indexed = true
        page.problem = formatted.diagnostic.isEmpty ? nil : formatted.diagnostic
        let refreshed = try await discoverLibrary(plan: DiscoveryPlan(roots: [source], allowedNetworkRoots: [], exclusions: []), previous: [page], progress: { _ in })
        XCTAssertTrue(try XCTUnwrap(refreshed.pages.first).indexed)
        XCTAssertEqual(refreshed.pages.first?.problem, page.problem)
        XCTAssertTrue(refreshed.coverage.flatMap(\.issues).isEmpty, "Usable formatter diagnostics are not unsupported discovery locations")
    }

    private func wideDirectory(_ directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("manuals")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"),
                                        to: root.appendingPathComponent("launchctl.1"))
        let payload = Data("Ordinary integration data without manual content.\n".utf8)
        for index in 0..<256 { try payload.write(to: root.appendingPathComponent("entry-\(index).data")) }
        return root
    }

    private func pausedWideDirectory(_ root: URL, _ checkpointURL: URL) async throws -> (LibraryScan, DiscoveryCheckpoint) {
        let file = DiscoveryCheckpointFile(url: checkpointURL)
        let request = UUID()
        await file.activate(request)
        let initial = try newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: [root], allowedNetworkRoots: [], exclusions: []),
                                             title: "Streamed integration scan")
        let worker = Task.detached {
            try await continueDiscovery(checkpoint: initial, previous: [], progress: { value in
                if value.files > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }, save: { try await file.save($0, request: request) })
        }
        let partial = try await worker.value
        let reopened = DiscoveryCheckpointFile(url: checkpointURL)
        let loaded = try await reopened.load()
        return (partial, try XCTUnwrap(loaded))
    }

    private func finished(_ store: LibraryStore) async throws {
        for _ in 0..<1000 {
            if await !store.isIndexing { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Discovery did not finish within ten seconds")
    }
}
