import XCTest
@testable import Man_Page_Catalog

final class PerformanceIntegrationTests: XCTestCase {
    func testRealManualDiscoveryIndexingAndLocalPerformanceExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScanPerformance-\(UUID().uuidString)")
        let manuals = directory.appendingPathComponent("manuals")
        try FileManager.default.createDirectory(at: manuals, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove performance integration files: \(error)") }
        }
        let source = manuals.appendingPathComponent("launchctl.1")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: source)
        let recorder = ScanPerformanceRecorder(scanID: UUID(), mode: "Selected Folders", roots: [manuals],
                                               initialDirectories: 0, initialFiles: 0, initialManualLocations: 0)
        try await recorder.sampleMemory()
        await recorder.sampleResponsiveness()
        let scan = try await discoverLibrary(plan: DiscoveryPlan(roots: [manuals], allowedNetworkRoots: [], exclusions: []),
                                             previous: [], progress: { value in
            await recorder.recordDiscovery(directories: value.directories, files: value.files,
                                           manualLocations: value.manuals, pending: value.pending, path: value.path)
            await recorder.recordPendingPeak(value.peakPending)
        })
        let coverage = try XCTUnwrap(scan.coverage.first)
        await recorder.recordDiscovery(directories: coverage.directories, files: coverage.files,
                                       manualLocations: coverage.count, pending: 0, path: manuals.path)
        await recorder.finishDiscovery()
        await recorder.beginIndexing(total: scan.pages.count)
        let page = try XCTUnwrap(scan.pages.first)
        await recorder.recordIndexing(completed: 0, queued: 0, active: 1, succeeded: 0, failed: 0)
        let html = try await manualHTML(source: page.source)
        XCTAssertTrue(html.contains("bootstrap"))
        await recorder.recordIndexing(completed: 1, queued: 0, active: 0, succeeded: 1, failed: 0)
        await recorder.finishIndexing()
        try JSONEncoder().encode(scan).write(to: directory.appendingPathComponent("discovery.json"), options: .atomic)
        await recorder.finish(state: .completed, durability: "Integration inventory written atomically.")
        let report = await recorder.snapshot()
        let export = directory.appendingPathComponent("performance.json")
        try JSONEncoder().encode(report).write(to: export, options: .atomic)
        let saved = try loadScanPerformance(export)
        XCTAssertEqual(saved.state, .completed)
        XCTAssertEqual(saved.discovery.files, coverage.files)
        XCTAssertEqual(saved.discovery.manualLocations, coverage.count)
        XCTAssertGreaterThan(saved.discovery.cumulative.filesPerSecond, 0)
        XCTAssertGreaterThan(try XCTUnwrap(saved.indexing).manualsPerSecond, 0)
        XCTAssertGreaterThan(saved.observedPeakResidentBytes, 0)
        XCTAssertEqual(saved.responsivenessSampleCount, 1)
        XCTAssertTrue(saved.discovery.finished)
        XCTAssertEqual(saved.discovery.pendingQueue, 0)
        XCTAssertGreaterThan(saved.discovery.peakPendingQueue, 0)
        XCTAssertTrue(try XCTUnwrap(saved.indexing).finished)
        XCTAssertNil(saved.cancellationLatencySeconds)
        let invalid = directory.appendingPathComponent("invalid-performance.json")
        let encoded = String(decoding: try Data(contentsOf: export), as: UTF8.self)
        try encoded.replacingOccurrences(of: "\"files\":\(saved.discovery.files)", with: "\"files\":-1")
            .write(to: invalid, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try loadScanPerformance(invalid)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid discovery counters"))
        }
    }

    func testCancellationLatencyIncludesRealCheckpointPreservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScanPerformancePause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove cancellation performance files: \(error)") }
        }
        let request = UUID()
        let roots = [URL(fileURLWithPath: "/usr/share/man")]
        let recorder = ScanPerformanceRecorder(scanID: request, mode: "Standard Scan", roots: roots,
                                               initialDirectories: 0, initialFiles: 0, initialManualLocations: 0)
        let checkpointFile = DiscoveryCheckpointFile(url: directory.appendingPathComponent("checkpoint.json"))
        await checkpointFile.activate(request)
        let (stream, continuation) = AsyncStream<DiscoveryProgress>.makeStream()
        let worker = Task.detached {
            try await continueDiscovery(checkpoint: newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: roots, allowedNetworkRoots: [], exclusions: []),
                                                                           title: "Telemetry integration"), previous: [], progress: { value in
                if value.manuals > 0 { continuation.yield(value) }
            }, save: { try await checkpointFile.save($0, request: request) })
        }
        for await progress in stream {
            await recorder.recordDiscovery(directories: progress.directories, files: progress.files,
                                           manualLocations: progress.manuals, pending: progress.pending, path: progress.path)
            await recorder.recordPendingPeak(progress.peakPending)
            let requested = ProcessInfo.processInfo.systemUptime
            worker.cancel()
            await recorder.requestCancellation(atUptime: requested)
            break
        }
        continuation.finish()
        let partial = try await worker.value
        XCTAssertTrue(partial.cancelled)
        let checkpoint = try await checkpointFile.load()
        XCTAssertGreaterThan(try XCTUnwrap(checkpoint).pendingCount, 0)
        await recorder.finish(state: .cancelled, durability: "Cancelled worker returned and checkpoint reopened successfully.")
        let report = await recorder.snapshot()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report.cancellationLatencySeconds), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.cancellationLatencySeconds), report.elapsedSeconds)
        XCTAssertFalse(report.discovery.finished)
        XCTAssertNil(report.indexing)
    }
}
