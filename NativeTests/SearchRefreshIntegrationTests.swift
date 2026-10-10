import XCTest
@testable import Man_Page_Catalog

final class SearchRefreshIntegrationTests: XCTestCase {
    @MainActor
    func testFullTextRefreshSubmissionAndChangedQueryDuringRealIndexing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchRefresh-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("manuals/man1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installed = try Data(contentsOf: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"))
        for ordinal in 0..<256 {
            let name = String(format: "refresh-%03d.1", ordinal)
            let revision = Data("\n.Sh REFRESH REFERENCE\nrefreshcatalogtopic documents installed-source revision \(ordinal).\n".utf8)
            try (installed + revision).write(to: root.appendingPathComponent(name))
        }
        let pingRoot = directory.appendingPathComponent("manuals/man8")
        try FileManager.default.createDirectory(at: pingRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man8/ping.8"),
                                         to: pingRoot.appendingPathComponent("ping.8"))
        let scan = try await scanLibrary(roots: [directory.appendingPathComponent("manuals")])
        XCTAssertEqual(scan.pages.count, 257)
        let output = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONEncoder().encode(scan).write(to: output.appendingPathComponent("discovery-v1.json"), options: .atomic)
        let suite = "SearchRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove owned search-refresh integration files: \(error)") }
        }
        try await verifyActiveFullTextRefresh(directory: output, defaults: defaults)
    }

    @MainActor
    private func verifyActiveFullTextRefresh(directory: URL, defaults: UserDefaults) async throws {
        let store = LibraryStore(directory: directory, defaults: defaults)
        store.continueIndexing()
        do {
            let publicationDeadline = ProcessInfo.processInfo.systemUptime + 30
            while store.indexCompleted < 64 && store.isIndexing && ProcessInfo.processInfo.systemUptime < publicationDeadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertGreaterThanOrEqual(store.indexCompleted, 64, store.errorMessage ?? store.status)
            XCTAssertTrue(store.isIndexing, "The full-text submission must exercise active metadata publication.")
            store.fullText = true
            store.query = "refreshcatalogtopic"
            let submitted = await store.firstResultForCurrentSearch()
            XCTAssertTrue(try XCTUnwrap(submitted).name.hasPrefix("refresh-"))
            XCTAssertTrue(store.isIndexing, "Background refresh must not defer submitted results until all indexing finishes.")
            XCTAssertGreaterThan(store.results.count, 0)
            XCTAssertTrue(store.results.allSatisfy { $0.reason == "Full text" && $0.page.indexed })

            store.query = "ping"
            let (submissionStarts, startedContinuation) = AsyncStream<Void>.makeStream()
            let oldSubmission = Task {
                startedContinuation.yield(())
                startedContinuation.finish()
                return await store.firstResultForCurrentSearch()
            }
            for await _ in submissionStarts { break }
            store.query = "refreshcatalogtopic"
            store.query = "ping"
            let changedResult = await oldSubmission.value
            XCTAssertNil(changedResult, "Changing away and back must supersede the older caller, even when the final query is identical.")
            let newestResult = await store.firstResultForCurrentSearch()
            XCTAssertEqual(newestResult?.name, "ping")
            XCTAssertEqual(store.query, "ping")
            XCTAssertEqual(store.results.first?.page.name, "ping")

            store.query = "refreshcatalogtopic"
            try await waitForRefreshIndexing(store)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.indexedCount, 257)
            let finalResult = await store.firstResultForCurrentSearch()
            XCTAssertTrue(try XCTUnwrap(finalResult).name.hasPrefix("refresh-"))
            XCTAssertEqual(store.results.count, 256, "The final queued metadata refresh must not be lost.")
            XCTAssertEqual(Set(store.results.map(\.page.id)).count, 256)
            XCTAssertTrue(store.results.allSatisfy { $0.reason == "Full text" && $0.page.indexed })
            let retained = try loadDiscovery(directory.appendingPathComponent("discovery-v1.json"))
            XCTAssertEqual(Set(store.results.map(\.page.id)),
                           Set(retained.pages.filter { $0.name.hasPrefix("refresh-") }.map(\.id)))
        } catch {
            store.stop()
            try await waitForRefreshIndexing(store)
            throw error
        }
    }

    @MainActor
    private func waitForRefreshIndexing(_ store: LibraryStore) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while store.isIndexing && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.isIndexing, store.errorMessage ?? store.status)
    }
}
