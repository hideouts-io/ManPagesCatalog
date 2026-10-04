import Foundation
import Darwin

enum BenchmarkCommand: String, Codable { case scan, resume }
enum BenchmarkTelemetry: String, Codable { case enabled, disabled }
enum BenchmarkCacheState: String, Codable { case cold, warm, unknown }

struct BenchmarkOptions {
    let command: BenchmarkCommand
    let output: URL
    let cancellationSeconds: Double
    let telemetry: BenchmarkTelemetry
    let cacheState: BenchmarkCacheState
    let roots: [URL]
}

struct BenchmarkOwnership: Codable {
    let owner: String
    let version: Int
    let created: Date
    let roots: [URL]
}

struct BenchmarkResult: Codable {
    let schemaVersion: Int
    let scanID: UUID
    let command: BenchmarkCommand
    let roots: [URL]
    let started: Date
    let ended: Date
    let state: ScanPerformanceState
    let stoppedPhase: String
    let elapsedSeconds: Double
    let discoverySeconds: Double
    let indexingSeconds: Double
    let initialDirectories: Int
    let initialFiles: Int
    let directories: Int
    let files: Int
    let manualLocations: Int
    let uniqueManuals: Int
    let indexedManuals: Int
    let indexAttempts: Int
    let indexSucceeded: Int
    let indexFailed: Int
    let pendingLocations: Int
    let cancellationLatencySeconds: Double?
    let telemetry: BenchmarkTelemetry
    let cacheState: BenchmarkCacheState
    let physicalMemoryBytes: UInt64
    let processorCount: Int
    let osVersion: String
    let indexingConcurrency: Int
    let samplingError: String?
    let operationError: String?
    let limitations: [String]
}

struct BenchmarkIndexOutcome: Sendable {
    let id: String
    let description: String
    let diagnostic: String?
    let indexed: Bool
}

/// Coordinates only this harness-owned run's production inventory and cancellation boundary.
actor BenchmarkProgress {
    private var checkpoint: DiscoveryCheckpoint
    private var pages: [ManualPage]
    private var phase: String = "discovery"
    private var discoverySeconds: Double = 0
    private var indexingSeconds: Double = 0
    private var attempts: Int = 0
    private var succeeded: Int = 0
    private var failed: Int = 0
    private var cancellationRequested: Double?

    init(checkpoint: DiscoveryCheckpoint, pages: [ManualPage]) {
        self.checkpoint = checkpoint
        self.pages = pages
    }

    func saved(_ value: DiscoveryCheckpoint) { checkpoint = value }

    func discovered(_ scan: LibraryScan, seconds: Double) {
        pages = scan.pages
        discoverySeconds = seconds
    }

    func beginIndexing() { phase = "indexing" }

    func indexed(_ result: BenchmarkIndexOutcome) {
        attempts += 1
        if result.indexed { succeeded += 1 } else { failed += 1 }
        updatePage(result)
    }

    func restoreCached(_ result: BenchmarkIndexOutcome) { updatePage(result) }

    private func updatePage(_ result: BenchmarkIndexOutcome) {
        if let position = pages.firstIndex(where: { $0.id == result.id }) {
            pages[position].description = result.description
            pages[position].problem = result.diagnostic
            pages[position].indexed = result.indexed
        }
    }

    func finishIndexing(seconds: Double) { indexingSeconds = seconds }
    func requestCancellation(atUptime: Double) { cancellationRequested = atUptime }
    func indexCounts() -> (attempts: Int, succeeded: Int, failed: Int) { (attempts, succeeded, failed) }
    func checkpointValue() -> DiscoveryCheckpoint { checkpoint }

    func inventory() -> LibraryScan {
        let snapshot = checkpoint.snapshot
        let originals = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let combined = snapshot.pages.map { originals[$0.id] ?? $0 }
        return LibraryScan(pages: combined, coverage: snapshot.coverage, cancelled: checkpoint.pendingCount > 0)
    }

    func result(scanID: UUID, options: BenchmarkOptions, started: Date, began: Double, finished: Double,
                initial: DiscoveryCheckpoint, samplingError: String?, operationError: String?) -> BenchmarkResult {
        let scan = inventory()
        let cancelled = cancellationRequested != nil || scan.cancelled
        let state: ScanPerformanceState = operationError != nil || samplingError != nil ? .failed : cancelled ? .cancelled : .completed
        return BenchmarkResult(schemaVersion: 1, scanID: scanID, command: options.command, roots: checkpoint.plan.roots,
            started: started, ended: Date(), state: state, stoppedPhase: phase,
            elapsedSeconds: finished - began, discoverySeconds: discoverySeconds,
            indexingSeconds: indexingSeconds, initialDirectories: initial.roots.reduce(0) { $0 + $1.directories },
            initialFiles: initial.roots.reduce(0) { $0 + $1.files },
            directories: scan.coverage.reduce(0) { $0 + $1.directories }, files: scan.coverage.reduce(0) { $0 + $1.files },
            manualLocations: scan.pages.flatMap(\.locations).count, uniqueManuals: scan.pages.count,
            indexedManuals: scan.pages.filter(\.indexed).count, indexAttempts: attempts, indexSucceeded: succeeded,
            indexFailed: failed, pendingLocations: checkpoint.pendingCount,
            cancellationLatencySeconds: cancellationRequested.map { finished - $0 }, telemetry: options.telemetry,
            cacheState: options.cacheState, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, indexingConcurrency: 4,
            samplingError: samplingError, operationError: operationError,
            limitations: ["Only explicitly supplied local roots were scanned; this is a bounded Deep Scan traversal benchmark, not whole-Mac coverage.",
                "Discovery uses the production scanner and checkpoints. Indexing uses production formattedManualText and ManualSearchIndex with at most four workers; the CLI does not render a reader window.",
                "Cache state is a caller annotation; this harness never flushes system caches or changes security settings.",
                "MainActor telemetry measures CLI executor scheduling; app interaction latency and app RSS require separate rendered-app measurements.",
                "Files are actual production scan counters, not generated-path counts; initial counts are excluded when computing a resumed segment's throughput."])
    }
}

@main
struct DiscoveryBenchmark {
    static func main() async {
        do { try await run(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("Discovery benchmark failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(arguments: [String]) async throws {
        let options = try benchmarkOptions(arguments: arguments)
        let started = Date()
        let request = UUID()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let ownershipURL = options.output.appendingPathComponent(".manpages-benchmark-run.json")
        let checkpointFile = DiscoveryCheckpointFile(url: options.output.appendingPathComponent("checkpoint.json"))
        let initial: DiscoveryCheckpoint
        let previous: [ManualPage]
        switch options.command {
        case .scan:
            guard !FileManager.default.fileExists(atPath: options.output.path) else {
                throw ManualToolError(message: "Fresh scan output already exists: \(options.output.path). Choose a new directory or use resume for a harness-owned interrupted run.")
            }
            try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
            try encoder.encode(BenchmarkOwnership(owner: "ManPagesCatalog DiscoveryBenchmark", version: 1, created: started,
                                                   roots: options.roots)).write(to: ownershipURL, options: .atomic)
            initial = newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: options.roots, allowedNetworkRoots: [], exclusions: []),
                                             title: "Bounded Deep Scan benchmark")
            previous = []
        case .resume:
            let owned = try JSONDecoder().decode(BenchmarkOwnership.self, from: Data(contentsOf: ownershipURL))
            guard owned.owner == "ManPagesCatalog DiscoveryBenchmark", owned.version == 1,
                  let checkpoint = try await checkpointFile.load(), checkpoint.plan.roots == owned.roots else {
                throw ManualToolError(message: "Cannot resume \(options.output.path): missing or invalid harness ownership/checkpoint.")
            }
            initial = checkpoint
            let inventoryURL = options.output.appendingPathComponent("inventory.json")
            previous = FileManager.default.fileExists(atPath: inventoryURL.path) ? try loadDiscovery(inventoryURL).pages : checkpoint.snapshot.pages
        }
        await checkpointFile.activate(request)
        let recorder: ScanPerformanceRecorder? = options.telemetry == .enabled ? ScanPerformanceRecorder(scanID: request,
            mode: initial.title, roots: initial.plan.roots, initialDirectories: initial.roots.reduce(0) { $0 + $1.directories },
            initialFiles: initial.roots.reduce(0) { $0 + $1.files }, initialManualLocations: initial.pages.count) : nil
        let progress = BenchmarkProgress(checkpoint: initial, pages: previous)
        await recorder?.recordDiscovery(directories: initial.roots.reduce(0) { $0 + $1.directories },
            files: initial.roots.reduce(0) { $0 + $1.files }, manualLocations: initial.pages.count,
            pending: initial.pendingCount, path: "Preparing benchmark discovery")
        let began = ProcessInfo.processInfo.systemUptime
        let worker = Task.detached(priority: .utility) {
            try await benchmarkOperation(initial: initial, previous: previous, file: checkpointFile, request: request,
                                         progress: progress, recorder: recorder, output: options.output)
        }
        let timer: Task<Void, Error>? = options.cancellationSeconds > 0 ? Task {
            try await Task.sleep(nanoseconds: UInt64(options.cancellationSeconds * 1_000_000_000))
            let requested = ProcessInfo.processInfo.systemUptime
            await progress.requestCancellation(atUptime: requested)
            await recorder?.requestCancellation(atUptime: requested)
            worker.cancel()
        } : nil
        let sampler: Task<Void, Error>? = recorder.map { value in Task {
            while !Task.isCancelled {
                try await value.sampleMemory()
                await value.sampleResponsiveness()
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } }
        var operationError: String?
        do { try await worker.value }
        catch is CancellationError { }
        catch { operationError = error.localizedDescription }
        timer?.cancel()
        sampler?.cancel()
        var samplingError: String?
        if let sampler {
            do { try await sampler.value }
            catch is CancellationError { }
            catch { samplingError = error.localizedDescription }
        }
        let inventory = await progress.inventory()
        try encoder.encode(inventory).write(to: options.output.appendingPathComponent("inventory.json"), options: .atomic)
        try encoder.encode(inventory.coverage).write(to: options.output.appendingPathComponent("coverage.json"), options: .atomic)
        let durable = ProcessInfo.processInfo.systemUptime
        let result = await progress.result(scanID: request, options: options, started: started, began: began, finished: durable,
            initial: initial, samplingError: samplingError, operationError: operationError)
        await recorder?.finish(state: result.state, durability: "Worker stopped; production checkpoint, retained inventory and coverage written atomically.")
        if let recorder {
            let report = await recorder.snapshot()
            try encoder.encode(report).write(to: options.output.appendingPathComponent("coverage.performance.json"), options: .atomic)
            try encoder.encode(report).write(to: options.output.appendingPathComponent("performance-\(request.uuidString).json"), options: .atomic)
        }
        try encoder.encode(result).write(to: options.output.appendingPathComponent("result.json"), options: .atomic)
        try encoder.encode(result).write(to: options.output.appendingPathComponent("result-\(request.uuidString).json"), options: .atomic)
        print("state=\(result.state.rawValue) seconds=\(result.elapsedSeconds) discoverySeconds=\(result.discoverySeconds) indexingSeconds=\(result.indexingSeconds) files=\(result.files) directories=\(result.directories) uniqueManuals=\(result.uniqueManuals) indexed=\(result.indexedManuals) pending=\(result.pendingLocations) output=\(options.output.path)")
        if let operationError { throw ManualToolError(message: "Benchmark operation failed; retained reports are in \(options.output.path): \(operationError)") }
        if let samplingError { throw ManualToolError(message: "Benchmark telemetry failed; retained reports are in \(options.output.path): \(samplingError)") }
    }
}

func benchmarkOperation(initial: DiscoveryCheckpoint, previous: [ManualPage], file: DiscoveryCheckpointFile,
                        request: UUID, progress: BenchmarkProgress, recorder: ScanPerformanceRecorder?, output: URL) async throws {
    let began = ProcessInfo.processInfo.systemUptime
    let scan = try await continueDiscovery(checkpoint: initial, previous: previous, progress: { value in
        await recorder?.recordDiscovery(directories: value.directories, files: value.files, manualLocations: value.manuals,
                                       pending: value.pending, path: value.path)
        await recorder?.recordPendingPeak(value.peakPending)
    }, save: { checkpoint in
        try await file.save(checkpoint, request: request)
        await progress.saved(checkpoint)
    })
    await progress.discovered(scan, seconds: ProcessInfo.processInfo.systemUptime - began)
    if scan.cancelled || Task.isCancelled { return }
    await recorder?.finishDiscovery()
    let index = try ManualSearchIndex(url: output.appendingPathComponent("search.sqlite"))
    let cache = Dictionary(try await index.metadata().map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
    for page in scan.pages {
        if let cached = cache[page.id], cached.fingerprint == page.fingerprint {
            await progress.restoreCached(BenchmarkIndexOutcome(id: page.id, description: cached.description,
                                                        diagnostic: cached.diagnostic.isEmpty ? nil : cached.diagnostic, indexed: true))
        }
    }
    let pending = scan.pages.filter { cache[$0.id]?.fingerprint != $0.fingerprint && $0.problem == nil }
    await progress.beginIndexing()
    await recorder?.beginIndexing(total: pending.count)
    let indexingBegan = ProcessInfo.processInfo.systemUptime
    do { try await benchmarkIndex(pages: pending, index: index, progress: progress, recorder: recorder) }
    catch {
        await progress.finishIndexing(seconds: ProcessInfo.processInfo.systemUptime - indexingBegan)
        throw error
    }
    await progress.finishIndexing(seconds: ProcessInfo.processInfo.systemUptime - indexingBegan)
    await recorder?.finishIndexing()
}

func benchmarkIndex(pages: [ManualPage], index: ManualSearchIndex, progress: BenchmarkProgress,
                    recorder: ScanPerformanceRecorder?) async throws {
    try await withThrowingTaskGroup(of: BenchmarkIndexOutcome.self) { group in
        var next = 0
        var active = 0
        while next < min(4, pages.count) {
            let page = pages[next]
            group.addTask { try await benchmarkIndexPage(page: page, index: index) }
            next += 1
            active += 1
        }
        let counts = await progress.indexCounts()
        await recorder?.recordIndexing(completed: counts.attempts, queued: pages.count - next, active: active,
                                        succeeded: counts.succeeded, failed: counts.failed)
        do {
            while let outcome = try await group.next() {
                active -= 1
                await progress.indexed(outcome)
                try Task.checkCancellation()
                if next < pages.count {
                    let page = pages[next]
                    group.addTask { try await benchmarkIndexPage(page: page, index: index) }
                    next += 1
                    active += 1
                }
                let counts = await progress.indexCounts()
                await recorder?.recordIndexing(completed: counts.attempts, queued: pages.count - next, active: active,
                                                succeeded: counts.succeeded, failed: counts.failed)
            }
        } catch is CancellationError {
            group.cancelAll()
            // Drain already committed outcomes before claiming durable cancellation preservation.
            while !group.isEmpty {
                do { if let outcome = try await group.next() { await progress.indexed(outcome) } }
                catch is CancellationError { }
            }
            let counts = await progress.indexCounts()
            await recorder?.recordIndexing(completed: counts.attempts, queued: pages.count - counts.attempts, active: 0,
                                            succeeded: counts.succeeded, failed: counts.failed)
            throw CancellationError()
        }
    }
}

func benchmarkIndexPage(page: ManualPage, index: ManualSearchIndex) async throws -> BenchmarkIndexOutcome {
    do {
        let formatted = try await formattedManualText(source: page.source)
        let description = descriptionFromFormattedManual(formatted.text)
        try await index.store(page: page, text: formatted.text, description: description, diagnostic: formatted.diagnostic)
        return BenchmarkIndexOutcome(id: page.id, description: description,
                                     diagnostic: formatted.diagnostic.isEmpty ? nil : formatted.diagnostic, indexed: true)
    } catch is CancellationError { throw CancellationError() }
    catch { return BenchmarkIndexOutcome(id: page.id, description: "", diagnostic: error.localizedDescription, indexed: false) }
}

func benchmarkOptions(arguments: [String]) throws -> BenchmarkOptions {
    let usage = "Usage: discovery-benchmark scan|resume --output /new/owned/output --cancel-seconds NUMBER --telemetry enabled|disabled --cache-state cold|warm|unknown [--root /local/tree ...]. Resume uses its saved roots."
    guard let first = arguments.first, let command = BenchmarkCommand(rawValue: first) else { throw ManualToolError(message: usage) }
    var output: URL?
    var seconds: Double?
    var telemetry: BenchmarkTelemetry?
    var cache: BenchmarkCacheState?
    var roots: [URL] = []
    var index = 1
    while index < arguments.count {
        guard index + 1 < arguments.count else { throw ManualToolError(message: "Missing value for \(arguments[index]). \(usage)") }
        let value = arguments[index + 1]
        switch arguments[index] {
        case "--output":
            guard output == nil, value.hasPrefix("/") else { throw ManualToolError(message: "Output must be one absolute path. \(usage)") }
            output = URL(fileURLWithPath: value).standardizedFileURL
        case "--cancel-seconds":
            guard seconds == nil, let parsed = Double(value), parsed.isFinite, parsed >= 0, parsed <= 86400 else {
                throw ManualToolError(message: "Cancellation seconds must be supplied once between 0 and 86400. \(usage)")
            }
            seconds = parsed
        case "--telemetry":
            guard telemetry == nil, let parsed = BenchmarkTelemetry(rawValue: value) else { throw ManualToolError(message: "Telemetry must be enabled or disabled, supplied once. \(usage)") }
            telemetry = parsed
        case "--cache-state":
            guard cache == nil, let parsed = BenchmarkCacheState(rawValue: value) else { throw ManualToolError(message: "Cache state must be cold, warm, or unknown, supplied once. \(usage)") }
            cache = parsed
        case "--root":
            guard value.hasPrefix("/") else { throw ManualToolError(message: "Root must be an absolute local path: \(value)") }
            roots.append(URL(fileURLWithPath: value).standardizedFileURL)
        default: throw ManualToolError(message: "Unknown option \(arguments[index]). \(usage)")
        }
        index += 2
    }
    guard let output, let seconds, let telemetry, let cache, command == .scan ? !roots.isEmpty : roots.isEmpty else {
        throw ManualToolError(message: usage)
    }
    let physicalOutput = output.resolvingSymlinksInPath().path
    guard !roots.contains(where: {
        let physicalRoot = $0.resolvingSymlinksInPath().path
        return pathContains(root: physicalRoot, path: physicalOutput) || pathContains(root: physicalOutput, path: physicalRoot)
    }) else {
        throw ManualToolError(message: "Output must be separate from every scan root; otherwise benchmark files would alter the measured tree.")
    }
    return BenchmarkOptions(command: command, output: output, cancellationSeconds: seconds, telemetry: telemetry,
                            cacheState: cache, roots: roots)
}
