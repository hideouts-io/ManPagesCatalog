import XCTest
import PDFKit
import Combine
import Darwin
@testable import Man_Page_Catalog

final class DiscoveryIntegrationTests: XCTestCase {
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
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove discovery store integration files: \(error)") }
        }
        let store = LibraryStore(directory: directory.appendingPathComponent("index"), defaults: defaults)
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
            XCTAssertTrue(error.localizedDescription.contains("retains its previous bytes or absence"))
            XCTAssertTrue(error.localizedDescription.contains("Not written: \(deniedCompanion.path)"))
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
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove legacy-checkpoint integration files: \(error)") }
        }
        let library = directory.appendingPathComponent("index")
        let store = LibraryStore(directory: library, defaults: defaults)
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
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove resume integration files: \(error)") }
        }
        let url = directory.appendingPathComponent("scan-checkpoint-v1.json")
        let file = DiscoveryCheckpointFile(url: url)
        let request = UUID()
        await file.activate(request)
        let initial = newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: [URL(fileURLWithPath: "/usr/share/man")], allowedNetworkRoots: [], exclusions: []), title: "Integration Scan")
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
        try JSONEncoder().encode(partial).write(to: directory.appendingPathComponent("discovery-v1.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DiscoveryResume.\(UUID().uuidString)"))
        let store = await LibraryStore(directory: directory, defaults: defaults)
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
        let initial = newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: [root], allowedNetworkRoots: [], exclusions: []),
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
