import XCTest
import PDFKit
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
        try FileManager.default.moveItem(at: moved, to: root)
        let reopened = LibraryStore(directory: directory.appendingPathComponent("index"), defaults: defaults)
        reopened.scanSelectedRoots()
        try await finished(reopened)
        XCTAssertEqual(reopened.pages.first?.id, first.id)
        XCTAssertEqual(reopened.indexedCount, 1)
        reopened.scanSelectedRoots()
        reopened.scanSelectedRoots()
        try await finished(reopened)
        XCTAssertEqual(reopened.pages.count, 1)
        XCTAssertNil(reopened.errorMessage)
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

    private func finished(_ store: LibraryStore) async throws {
        for _ in 0..<1000 {
            if await !store.isIndexing { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Discovery did not finish within ten seconds")
    }
}
