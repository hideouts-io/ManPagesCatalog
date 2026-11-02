import XCTest
import Darwin
@testable import Man_Page_Catalog

final class IndexingIntegrationTests: XCTestCase {
    @MainActor
    func testCancelledFixtureCleanupPreservesFilesUntilItsOwnerReleases() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IndexCleanupCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let marker = directory.appendingPathComponent("retained-marker")
        let retained = Data("preserve owned fixture\n".utf8)
        try retained.write(to: marker)
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            if FileManager.default.fileExists(atPath: directory.path) { try await fixture.remove() }
        }
        try await verifyCancelledCleanup(directory: directory, fixture: fixture)
        XCTAssertEqual(try Data(contentsOf: marker), retained)
        try await fixture.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    private func verifyCancelledCleanup(directory: URL, fixture: LibraryFixtureCleanup) async throws {
        let suite = "IndexCleanupCancellation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(directory: directory, defaults: defaults)
        fixture.track(store)
        let removal = Task { try await fixture.remove() }
        removal.cancel()
        do {
            try await removal.value
            XCTFail("Cancelled cleanup must preserve files while an owner is retained.")
        } catch is CancellationError {
            XCTAssertFalse(store.isIndexing)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("search.sqlite").path),
            "Owner retirement must guard deletion even before a database connection exists.")
    }

    func testLibraryFixtureRemovalRefusesAnOpenSQLiteConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IndexResourceLifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { () async throws -> Void in
            if FileManager.default.fileExists(atPath: directory.path) {
                try removeClosedLibraryFixture(at: directory)
            }
        }
        try await verifyOpenFixtureRefusal(directory: directory)
        try removeClosedLibraryFixture(at: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func verifyOpenFixtureRefusal(directory: URL) async throws {
        let database = directory.appendingPathComponent("search.sqlite")
        let index = try ManualSearchIndex(url: database)
        let metadata = try await index.metadata()
        XCTAssertTrue(metadata.isEmpty)
        let before = try Data(contentsOf: database)
        try withExtendedLifetime(index) {
            XCTAssertThrowsError(try removeClosedLibraryFixture(at: directory)) { error in
                XCTAssertTrue(error.localizedDescription.contains("open files"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(database.lastPathComponent), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: database), before, "Refusing removal must preserve exact database bytes.")
        }
    }

    func testLocalInteractionDiagnosticsAppendAndSymlinkRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualInteractionOutput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove owned interaction-output integration files: \(error)") }
        }
        let generation = UUID()
        let began = ProcessInfo.processInfo.systemUptime
        let span = InteractionSpan(schemaVersion: 1, id: UUID(), operation: .search, startedUptime: began,
            eventUptime: nil, startBoundary: .binding, query: "launchctl", queryTruncated: false,
            documentID: nil, documentGeneration: nil, generation: generation, section: nil, sourceRoot: nil,
            fullText: false, serviceFinishedUptime: began, viewAppliedUptime: nil, outcome: .completed,
            resultCount: 1, detail: nil)
        let session = UUID()
        let first = InteractionDiagnosticRecord(sequence: 1, sessionID: session, processID: ProcessInfo.processInfo.processIdentifier,
            phase: "service-finished", clock: "ProcessInfo.systemUptime", endpointLimit: "Binding to service completion", span: span)
        let second = InteractionDiagnosticRecord(sequence: 2, sessionID: session, processID: ProcessInfo.processInfo.processIdentifier,
            phase: "service-finished", clock: "ProcessInfo.systemUptime", endpointLimit: "Binding to service completion", span: span)
        let output = directory.appendingPathComponent("interactions.jsonl")
        let writer = InteractionDiagnosticWriter(destination: output)
        try await writer.append(first)
        let reopened = InteractionDiagnosticWriter(destination: output)
        try await reopened.append(second)
        let lines = String(decoding: try Data(contentsOf: output), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let records = try lines.map { try JSONDecoder().decode(InteractionDiagnosticRecord.self, from: Data($0.utf8)) }
        XCTAssertEqual(records.map(\.sequence), [1, 2])
        XCTAssertEqual(records.map(\.sessionID), [session, session])
        XCTAssertEqual(records.map(\.span.generation), [generation, generation])
        XCTAssertEqual(records.map(\.span.query), ["launchctl", "launchctl"])
        let target = directory.appendingPathComponent("retained-target.jsonl")
        let retained = Data("retained local data\n".utf8)
        try retained.write(to: target)
        let symlink = directory.appendingPathComponent("linked-output.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let rejected = InteractionDiagnosticWriter(destination: symlink)
        do {
            try await rejected.append(first)
            XCTFail("Interaction diagnostics must reject a symbolic-link destination")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("symlink"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: target), retained)
    }

    @MainActor
    func testManualRichPauseReopenAndIncrementalIndexParity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualIndexing-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("manuals/man1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installed = try Data(contentsOf: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"))
        for ordinal in 0..<132 {
            let name = String(format: "indexing-%03d.1", ordinal)
            try (installed + Data("\n.Sh INDEXING REFERENCE\ncatalogtest\(ordinal) documents a distinct installed-source revision.\n".utf8))
                .write(to: root.appendingPathComponent(name))
        }
        let suite = "ManualIndexing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set([root.path], forKey: "manualRoots")
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            try XCTUnwrap(UserDefaults(suiteName: suite)).removePersistentDomain(forName: suite)
            do { try await fixture.remove() }
            catch { XCTFail("Cannot remove owned indexing integration files: \(error)") }
        }
        let output = directory.appendingPathComponent("library")
        let first = LibraryStore(directory: output, defaults: defaults)
        fixture.track(first)
        first.scanSelectedRoots()
        for _ in 0..<4000 {
            if first.indexCompleted >= 64 { break }
            XCTAssertTrue(first.isIndexing, first.errorMessage ?? first.status)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(first.indexCompleted, 64)
        first.query = "indexing-000"
        let duringIndexing = await first.firstResultForCurrentSearch()
        XCTAssertEqual(duringIndexing?.name, "indexing-000")
        XCTAssertTrue(first.isIndexing, "Search submission must settle while metadata refresh continues")
        first.stop()
        try await waitForIndexing(first)
        XCTAssertNil(first.errorMessage)
        XCTAssertEqual(first.phase, .paused)
        let paused = try loadDiscovery(output.appendingPathComponent("discovery-v1.json"))
        let durable = paused.pages.filter(\.indexed).count
        XCTAssertGreaterThanOrEqual(durable, 64)
        XCTAssertLessThan(durable, 132)
        let reopened = LibraryStore(directory: output, defaults: defaults)
        fixture.track(reopened)
        reopened.continueIndexing()
        try await waitForIndexing(reopened)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.indexTotal, 132 - durable)
        XCTAssertEqual(reopened.indexedCount, 132)
        let work = try XCTUnwrap(reopened.performanceReport?.indexingWork)
        XCTAssertEqual(work.indexTransactions.operations, (reopened.indexTotal + 3) / 4)
        XCTAssertGreaterThan(work.metadataPublications.operations, 0)
        XCTAssertGreaterThan(work.inventoryWrites.operations, 0)
        XCTAssertEqual(work.lastInventoryBytes, UInt64(try Data(contentsOf: output.appendingPathComponent("discovery-v1.json")).count))
        XCTAssertEqual(Set(reopened.pages.map(\.id)), Set(paused.pages.map(\.id)))
        XCTAssertEqual(reopened.sourceRoots, [root.path])
        XCTAssertEqual(reopened.sections, ["1"])
        let index = try ManualSearchIndex(url: output.appendingPathComponent("search.sqlite"))
        let metadata = try await index.metadata()
        XCTAssertEqual(metadata.count, 132)
        for ordinal in [0, 65, 131] {
            let matches = try await index.matchingIDs(query: "catalogtest\(ordinal)")
            XCTAssertEqual(matches.count, 1)
        }
        reopened.query = "indexing-001"
        let cancelledSubmission = Task { await reopened.firstResultForCurrentSearch() }
        await Task.yield()
        cancelledSubmission.cancel()
        let cancelledResult = await cancelledSubmission.value
        XCTAssertNil(cancelledResult)
        reopened.query = "no-such-manual"
        reopened.query = "indexing-000"
        let submitted = await reopened.firstResultForCurrentSearch()
        XCTAssertEqual(submitted?.name, "indexing-000")
        reopened.scanSelectedRoots()
        try await waitForIndexing(reopened)
        XCTAssertEqual(reopened.indexTotal, 0)
        XCTAssertEqual(reopened.indexedCount, 132)
        XCTAssertNil(reopened.errorMessage)
    }

    @MainActor
    func testDuplicateGroupedInventoryReportsErrorWithoutReplacingData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualIndexDuplicate-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("manuals")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: root.appendingPathComponent("launchctl.1"))
        let scan = try await scanLibrary(roots: [root])
        let page = try XCTUnwrap(scan.pages.first)
        let malformed = LibraryScan(pages: [page, page], coverage: scan.coverage, cancelled: false)
        let output = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let inventory = output.appendingPathComponent("discovery-v1.json")
        let bytes = try JSONEncoder().encode(malformed)
        try bytes.write(to: inventory, options: .atomic)
        let suite = "ManualIndexDuplicate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            try XCTUnwrap(UserDefaults(suiteName: suite)).removePersistentDomain(forName: suite)
            do { try await fixture.remove() }
            catch { XCTFail("Cannot remove owned duplicate-inventory integration files: \(error)") }
        }
        XCTAssertThrowsError(try loadDiscovery(inventory)) { error in
            XCTAssertTrue(error is DiscoveryInventoryError)
            XCTAssertTrue(error.localizedDescription.contains("duplicate grouped manual ID"))
        }
        let store = LibraryStore(directory: output, defaults: defaults)
        fixture.track(store)
        store.continueIndexing()
        try await waitForIndexing(store)
        XCTAssertEqual(store.phase, .needsAttention)
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("duplicate grouped manual ID"))
        XCTAssertEqual(try Data(contentsOf: inventory), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("search.sqlite").path))
    }

    @MainActor
    func testChangedSourceCannotEnterIndexUnderAnOldFingerprint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualIndexVersion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("launchctl.1")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: source)
        let scan = try await scanLibrary(roots: [directory])
        let original = try XCTUnwrap(scan.pages.first)
        let output = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONEncoder().encode(scan).write(to: output.appendingPathComponent("discovery-v1.json"), options: .atomic)
        try (Data(contentsOf: source) + Data("\n.Sh CHANGED VERSION\nchangedindexversion\n".utf8)).write(to: source)
        let suite = "ManualIndexVersion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            try XCTUnwrap(UserDefaults(suiteName: suite)).removePersistentDomain(forName: suite)
            do { try await fixture.remove() }
            catch { XCTFail("Cannot remove owned version integration files: \(error)") }
        }
        let store = LibraryStore(directory: output, defaults: defaults)
        fixture.track(store)
        store.continueIndexing()
        try await waitForIndexing(store)
        XCTAssertEqual(store.pages.first?.id, original.id)
        XCTAssertEqual(store.indexedCount, 0)
        XCTAssertTrue(try XCTUnwrap(store.pages.first?.problem).contains("changed after discovery"))
        let index = try ManualSearchIndex(url: output.appendingPathComponent("search.sqlite"))
        let metadata = try await index.metadata()
        XCTAssertTrue(metadata.isEmpty)
    }

    @MainActor
    func testReadOnlyIndexReportsStorageErrorAndRetainsInventory() async throws {
        XCTAssertNotEqual(geteuid(), 0, "Permission behavior must run under the ordinary test identity.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualIndexReadOnly-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("manuals")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: root.appendingPathComponent("launchctl.1"))
        let suite = "ManualIndexReadOnly.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set([root.path], forKey: "manualRoots")
        let output = directory.appendingPathComponent("library")
        let database = output.appendingPathComponent("search.sqlite")
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            try XCTUnwrap(UserDefaults(suiteName: suite)).removePersistentDomain(forName: suite)
            if chmod(database.path, 0o600) != 0 { XCTFail("Cannot restore owned index permissions: errno \(errno)") }
            do { try await fixture.remove() }
            catch { XCTFail("Cannot remove owned read-only integration files: \(error)") }
        }
        let initial = LibraryStore(directory: output, defaults: defaults)
        fixture.track(initial)
        initial.scanSelectedRoots()
        try await waitForIndexing(initial)
        XCTAssertEqual(initial.indexedCount, 1)
        let prior = try XCTUnwrap(initial.pages.first)
        guard chmod(database.path, 0o444) == 0 else { throw ManualToolError(message: "Cannot set owned index read-only: errno \(errno).") }
        XCTAssertNotEqual(access(database.path, W_OK), 0, "Verify actual write denial under this identity.")
        let reopened = LibraryStore(directory: output, defaults: defaults)
        fixture.track(reopened)
        reopened.continueIndexing()
        try await waitForIndexing(reopened)
        XCTAssertEqual(reopened.phase, .needsAttention)
        XCTAssertEqual(reopened.pages.first?.id, prior.id)
        XCTAssertEqual(reopened.indexedCount, 1)
        let message = try XCTUnwrap(reopened.errorMessage)
        XCTAssertTrue(message.contains("search.sqlite"), message)
        XCTAssertTrue(message.lowercased().contains("read-only"), message)
        reopened.query = "launchctl"
        let retained = await reopened.firstResultForCurrentSearch()
        XCTAssertEqual(retained?.id, prior.id)
    }

    @MainActor
    private func waitForIndexing(_ store: LibraryStore) async throws {
        for _ in 0..<4000 where store.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isIndexing, store.errorMessage ?? store.status)
    }
}

/// Refuses to unlink an owned fixture while this process still has a regular file open beneath it.
func removeClosedLibraryFixture(at directory: URL) throws {
    let prefix = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    var retained: [String] = []
    for descriptor: Int32 in 0..<getdtablesize() {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            if errno == EBADF { continue }
            throw ManualToolError(message: "Cannot inspect fixture file descriptor \(descriptor): errno \(errno). The owned library remains at \(directory.path).")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { continue }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else {
            if errno == EBADF { continue }
            throw ManualToolError(message: "Cannot resolve fixture file descriptor \(descriptor): errno \(errno). The owned library remains at \(directory.path).")
        }
        let resolved = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().standardizedFileURL.path
        if resolved.hasPrefix(prefix) { retained.append("\(descriptor): \(resolved)") }
    }
    guard retained.isEmpty else {
        throw ManualToolError(message: "Refusing to remove the owned library with open files: \(retained.prefix(10).joined(separator: "; ")). Release its owners before removing \(directory.path).")
    }
    try FileManager.default.removeItem(at: directory)
}

private struct LibraryFixtureOwner {
    weak var store: LibraryStore?
}

/// Coordinates test-owned filesystem cleanup; any retirement or descriptor failure prevents deletion.
@MainActor
final class LibraryFixtureCleanup {
    private let directory: URL
    private var owners: [LibraryFixtureOwner] = []

    init(directory: URL) { self.directory = directory }

    func track(_ store: LibraryStore) {
        owners.append(LibraryFixtureOwner(store: store))
    }

    func remove() async throws {
        for owner in owners { owner.store?.stop() }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while owners.contains(where: { $0.store != nil }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ManualToolError(message: "The owned library still has an active owner after stopping its work. Preserve \(directory.path) and inspect its unfinished search or indexing tasks.")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try removeClosedLibraryFixture(at: directory)
    }
}
