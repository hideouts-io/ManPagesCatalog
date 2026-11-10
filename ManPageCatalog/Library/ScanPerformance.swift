import Foundation
import Darwin

enum ScanPerformanceState: String, Codable, Sendable {
    case running, completed, cancelled, failed
}

struct ScanPerformanceRates: Codable, Sendable {
    let seconds: Double
    let directoriesPerSecond: Double
    let filesPerSecond: Double
    let manualsPerSecond: Double
}

struct DiscoveryPerformance: Codable, Sendable {
    let startedElapsedSeconds: Double
    let endedElapsedSeconds: Double?
    let directories: Int
    let files: Int
    let manualLocations: Int
    let initialDirectories: Int
    let initialFiles: Int
    let initialManualLocations: Int
    let pendingQueue: Int
    let peakPendingQueue: Int
    let currentPath: String
    let cumulative: ScanPerformanceRates
    let lastInterval: ScanPerformanceRates
    let finished: Bool
}

struct IndexingPerformance: Codable, Sendable {
    let startedElapsedSeconds: Double
    let endedElapsedSeconds: Double?
    let total: Int
    let completed: Int
    let succeeded: Int
    let failed: Int
    let queued: Int
    let active: Int
    let peakQueued: Int
    let seconds: Double
    let manualsPerSecond: Double
    let finished: Bool
}

struct ScanMemorySample: Codable, Sendable {
    let elapsedSeconds: Double
    let residentBytes: UInt64
}

struct ScanResponsivenessSample: Codable, Sendable {
    let elapsedSeconds: Double
    let mainActorDelayMilliseconds: Double
}

struct IndexingCost: Codable, Sendable {
    let operations: Int
    let totalSeconds: Double
    let worstSeconds: Double

    static var empty: IndexingCost { IndexingCost(operations: 0, totalSeconds: 0, worstSeconds: 0) }

    func adding(seconds: Double) -> IndexingCost {
        IndexingCost(operations: operations + 1, totalSeconds: totalSeconds + seconds, worstSeconds: max(worstSeconds, seconds))
    }
}

struct IndexingWorkPerformance: Codable, Sendable {
    let formatterBatches: IndexingCost
    let indexTransactions: IndexingCost
    let metadataPublications: IndexingCost
    let inventoryWrites: IndexingCost
    let lastInventoryBytes: UInt64
    let peakInventoryBytes: UInt64
}

struct ScanPerformanceReport: Codable, Sendable {
    let schemaVersion: Int
    let scanID: UUID
    let mode: String
    let roots: [URL]
    let started: Date
    let ended: Date?
    let state: ScanPerformanceState
    let elapsedSeconds: Double
    let discovery: DiscoveryPerformance
    let indexing: IndexingPerformance?
    let indexingWork: IndexingWorkPerformance?
    let cancellationLatencySeconds: Double?
    let durability: String?
    let memorySamples: [ScanMemorySample]
    let observedPeakResidentBytes: UInt64
    let responsivenessSamples: [ScanResponsivenessSample]
    let worstMainActorDelayMilliseconds: Double
    let memorySampleCount: Int
    let responsivenessSampleCount: Int
    let limitations: [String]
}

enum ScanPerformanceError: LocalizedError {
    case memoryQuery(kern_return_t)

    var errorDescription: String? {
        switch self {
        case .memoryQuery(let status):
            return "Cannot sample local process resident memory: task_info returned Mach status \(status)."
        }
    }
}

/// A local process interface. Monotonic phase clocks never span a paused scan's resumed segment.
actor ScanPerformanceRecorder {
    private let scanID: UUID
    private let mode: String
    private let roots: [URL]
    private let started: Date
    private let began: Double
    private let initialDirectories: Int
    private let initialFiles: Int
    private let initialManualLocations: Int
    private var directories: Int
    private var files: Int
    private var manualLocations: Int
    private var pending: Int = 0
    private var peakPending: Int = 0
    private var path: String = ""
    private var intervalBegan: Double
    private var intervalDirectories: Int
    private var intervalFiles: Int
    private var intervalManuals: Int
    private var lastInterval = ScanPerformanceRates(seconds: 0, directoriesPerSecond: 0, filesPerSecond: 0, manualsPerSecond: 0)
    private var discoveryEnded: Double?
    private var indexingBegan: Double?
    private var indexingEnded: Double?
    private var indexingTotal: Int = 0
    private var indexed: Int = 0
    private var indexingSucceeded: Int = 0
    private var indexingFailed: Int = 0
    private var indexingQueued: Int = 0
    private var indexingActive: Int = 0
    private var peakIndexingQueued: Int = 0
    private var cancellationRequested: Double?
    private var finishedAt: Double?
    private var ended: Date?
    private var state: ScanPerformanceState = .running
    private var durability: String?
    private var memorySamples: [ScanMemorySample] = []
    private var responsivenessSamples: [ScanResponsivenessSample] = []
    private var peakResident: UInt64 = 0
    private var worstDelay: Double = 0
    private var memorySampleCount: Int = 0
    private var responsivenessSampleCount: Int = 0
    private var formatterBatches = IndexingCost.empty
    private var indexTransactions = IndexingCost.empty
    private var metadataPublications = IndexingCost.empty
    private var inventoryWrites = IndexingCost.empty
    private var lastInventoryBytes: UInt64 = 0
    private var peakInventoryBytes: UInt64 = 0

    init(scanID: UUID, mode: String, roots: [URL], initialDirectories: Int, initialFiles: Int, initialManualLocations: Int) {
        self.scanID = scanID
        self.mode = mode
        self.roots = roots
        self.started = Date()
        let clock = ProcessInfo.processInfo.systemUptime
        self.began = clock
        self.intervalBegan = clock
        self.initialDirectories = initialDirectories
        self.initialFiles = initialFiles
        self.initialManualLocations = initialManualLocations
        self.directories = initialDirectories
        self.files = initialFiles
        self.manualLocations = initialManualLocations
        self.intervalDirectories = initialDirectories
        self.intervalFiles = initialFiles
        self.intervalManuals = initialManualLocations
    }

    func recordDiscovery(directories: Int, files: Int, manualLocations: Int, pending: Int, path: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lastInterval = scanPerformanceRates(seconds: now - intervalBegan, directories: directories - intervalDirectories,
                                             files: files - intervalFiles, manuals: manualLocations - intervalManuals)
        self.directories = directories
        self.files = files
        self.manualLocations = manualLocations
        self.pending = pending
        self.peakPending = max(peakPending, pending)
        self.path = path
        intervalBegan = now
        intervalDirectories = directories
        intervalFiles = files
        intervalManuals = manualLocations
    }

    func finishDiscovery() { discoveryEnded = ProcessInfo.processInfo.systemUptime }

    /// Traversal tracks its exact queue high-water mark between throttled progress callbacks.
    func recordPendingPeak(_ peak: Int) { peakPending = max(peakPending, peak) }

    func beginIndexing(total: Int) {
        indexingBegan = ProcessInfo.processInfo.systemUptime
        indexingTotal = total
        indexingQueued = total
        peakIndexingQueued = total
    }

    func recordIndexing(completed: Int, queued: Int, active: Int, succeeded: Int, failed: Int) {
        indexed = completed
        indexingSucceeded = succeeded
        indexingFailed = failed
        indexingQueued = queued
        indexingActive = active
        peakIndexingQueued = max(peakIndexingQueued, queued)
    }

    func finishIndexing() { indexingEnded = ProcessInfo.processInfo.systemUptime }

    func recordFormatterBatch(seconds: Double) { formatterBatches = formatterBatches.adding(seconds: seconds) }
    func recordIndexTransaction(seconds: Double) { indexTransactions = indexTransactions.adding(seconds: seconds) }
    func recordMetadataPublication(seconds: Double) { metadataPublications = metadataPublications.adding(seconds: seconds) }
    func recordInventoryWrite(seconds: Double, bytes: UInt64) {
        inventoryWrites = inventoryWrites.adding(seconds: seconds)
        lastInventoryBytes = bytes
        peakInventoryBytes = max(peakInventoryBytes, bytes)
    }

    func requestCancellation(atUptime: Double) {
        if cancellationRequested == nil { cancellationRequested = atUptime }
    }

    func sampleMemory() throws {
        let sample = ScanMemorySample(elapsedSeconds: ProcessInfo.processInfo.systemUptime - began,
                                      residentBytes: try scanResidentMemory())
        peakResident = max(peakResident, sample.residentBytes)
        memorySampleCount += 1
        if memorySamples.count < 3600 { memorySamples.append(sample) }
    }

    /// MainActor scheduling delay measures the UI executor separately from discovery and RSS.
    func sampleResponsiveness() async {
        let scheduled = ProcessInfo.processInfo.systemUptime
        let serviced = await MainActor.run { ProcessInfo.processInfo.systemUptime }
        let sample = ScanResponsivenessSample(elapsedSeconds: serviced - began,
                                              mainActorDelayMilliseconds: (serviced - scheduled) * 1000)
        worstDelay = max(worstDelay, sample.mainActorDelayMilliseconds)
        responsivenessSampleCount += 1
        if responsivenessSamples.count < 3600 { responsivenessSamples.append(sample) }
    }

    /// Call only after the scan worker stops and its checkpoint or retained inventory is durable.
    func finish(state: ScanPerformanceState, durability: String) {
        finishedAt = ProcessInfo.processInfo.systemUptime
        ended = Date()
        self.state = state
        self.durability = durability
    }

    func snapshot() -> ScanPerformanceReport {
        let now = finishedAt ?? ProcessInfo.processInfo.systemUptime
        let discoverySeconds = (discoveryEnded ?? now) - began
        let discovery = DiscoveryPerformance(startedElapsedSeconds: 0, endedElapsedSeconds: discoveryEnded.map { $0 - began },
                                             directories: directories, files: files, manualLocations: manualLocations,
                                             initialDirectories: initialDirectories, initialFiles: initialFiles,
                                             initialManualLocations: initialManualLocations, pendingQueue: pending,
                                             peakPendingQueue: peakPending, currentPath: path,
                                             cumulative: scanPerformanceRates(seconds: discoverySeconds,
                                                 directories: directories - initialDirectories, files: files - initialFiles,
                                                 manuals: manualLocations - initialManualLocations),
                                             lastInterval: lastInterval, finished: discoveryEnded != nil)
        let indexing = indexingBegan.map { start -> IndexingPerformance in
            let seconds = (indexingEnded ?? now) - start
            return IndexingPerformance(startedElapsedSeconds: start - began, endedElapsedSeconds: indexingEnded.map { $0 - began },
                                       total: indexingTotal, completed: indexed, succeeded: indexingSucceeded,
                                       failed: indexingFailed, queued: indexingQueued,
                                       active: indexingActive, peakQueued: peakIndexingQueued, seconds: seconds,
                                       manualsPerSecond: seconds > 0 ? Double(indexingSucceeded) / seconds : 0,
                                       finished: indexingEnded != nil)
        }
        let cancellation = cancellationRequested.flatMap { request in finishedAt.map { $0 - request } }
        var limitations = [
            "Rates use monotonic active-segment wall time, including filesystem waits and checkpoint writes; resumed scans start a new segment and subtract initial counters.",
            "Directories count opened unique directory identities, including partially enumerated folders. Files count inspected regular entries, including file aliases and unsupported candidates. manualLocations count validated locations before content grouping. Generated paths and pending descendants are not inspected counts.",
            "Pending traversal counts selected roots awaiting inspection, unfinished directory streams and interrupted entries; unknown children are not queued or counted. At most 128 directory streams are open across the traversal. Deeper and union-mounted directories are reported as unsupported. Version 2 checkpoints verify directory identity, entry modification time and the ordered consumed prefix on resume; status timestamps are diagnostic only. This is not a filesystem snapshot.",
            "Cumulative rates cover this segment; lastInterval rates cover only the latest progress callback interval.",
            "Indexing completed counts finished attempts; succeeded counts confirmed FTS entries and failed counts formatting/indexing failures. Indexing manualsPerSecond uses succeeded, not attempts.",
            "Optional indexingWork contains cumulative wall durations: each formatter batch runs at most four concurrent formatters; indexTransactions includes actor waiting and committed batch storage; metadataPublications is synchronous MainActor array publication; inventoryWrites includes actor waiting, encoding and atomic persistence. These costs are separate boundaries, not CPU attribution or pixel presentation. Formatter batch observations can include failed or cancelled manuals; transactions count committed batches, publications count applied metadata, and inventory writes count successfully measured persisted files. Incomplete manual attempts remain in the unfinished phase.",
            "Resident memory uses task_info(MACH_TASK_BASIC_INFO), sampled by the caller at a target interval of one second. Actual intervals may be longer. The observed peak is a sample maximum, not the kernel high-water mark or discovery-only allocation.",
            "MainActor delay is a scheduling probe, not click-to-render latency. Rendered interaction requires separate UI verification.",
            "Each sample series retains its first 3600 samples; sample counts and peak values continue for the entire segment. Actual sample spacing is recorded by elapsedSeconds.",
            "Cancellation latency ends when finish is called after durable preservation; it includes worker shutdown and preservation work."
        ]
        if discoveryEnded == nil { limitations.append("Discovery did not complete in this segment.") }
        if indexingBegan != nil && directories == initialDirectories && files == initialFiles {
            limitations.append("No directory or regular-file traversal was measured in this segment. Zero discovery counters/rates do not establish scan coverage; this may be an indexing-only continuation.")
        }
        if indexingBegan == nil { limitations.append("Indexing did not start in this segment.") }
        else if indexingEnded == nil { limitations.append("Indexing did not complete in this segment.") }
        return ScanPerformanceReport(schemaVersion: 1, scanID: scanID, mode: mode, roots: roots, started: started,
                                     ended: ended, state: state, elapsedSeconds: now - began,
                                     discovery: discovery, indexing: indexing, indexingWork: indexingBegan.map { _ in
                                         IndexingWorkPerformance(formatterBatches: formatterBatches, indexTransactions: indexTransactions,
                                             metadataPublications: metadataPublications, inventoryWrites: inventoryWrites,
                                             lastInventoryBytes: lastInventoryBytes, peakInventoryBytes: peakInventoryBytes)
                                     }, cancellationLatencySeconds: cancellation,
                                     durability: durability, memorySamples: memorySamples,
                                     observedPeakResidentBytes: peakResident, responsivenessSamples: responsivenessSamples,
                                     worstMainActorDelayMilliseconds: worstDelay, memorySampleCount: memorySampleCount,
                                     responsivenessSampleCount: responsivenessSampleCount, limitations: limitations)
    }
}

func scanPerformanceRates(seconds: Double, directories: Int, files: Int, manuals: Int) -> ScanPerformanceRates {
    ScanPerformanceRates(seconds: seconds, directoriesPerSecond: seconds > 0 ? Double(directories) / seconds : 0,
                         filesPerSecond: seconds > 0 ? Double(files) / seconds : 0,
                         manualsPerSecond: seconds > 0 ? Double(manuals) / seconds : 0)
}

func scanResidentMemory() throws -> UInt64 {
    var information = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw ScanPerformanceError.memoryQuery(status) }
    return UInt64(information.resident_size)
}

/// Local reports are external persisted input; reject invalid values before publishing diagnostics.
func loadScanPerformance(_ url: URL) throws -> ScanPerformanceReport {
    do {
        let report = try JSONDecoder().decode(ScanPerformanceReport.self, from: Data(contentsOf: url))
        try validateScanPerformance(report)
        return report
    } catch let error as DecodingError {
        throw ManualToolError(message: "Cannot load local scan diagnostics \(url.path): \(scanPerformanceDecodingReason(error)). Move this app-owned diagnostic file aside and run a new scan; manual sources and the retained catalog are separate.")
    } catch {
        throw ManualToolError(message: "Cannot load local scan diagnostics \(url.path): \(error.localizedDescription) Move this app-owned diagnostic file aside and run a new scan; manual sources and the retained catalog are separate.")
    }
}

func validateScanPerformance(_ report: ScanPerformanceReport) throws {
    guard report.schemaVersion == 1 else { throw ManualToolError(message: "Unsupported diagnostics schemaVersion \(report.schemaVersion); expected 1.") }
    guard !report.mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          report.roots.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
          report.started.timeIntervalSinceReferenceDate.isFinite,
          report.ended.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
          report.elapsedSeconds.isFinite, report.elapsedSeconds >= 0,
          (report.state == .running) == (report.ended == nil) else {
        throw ManualToolError(message: "Invalid scan identity, roots, start/end dates, state, or elapsedSeconds; roots must be absolute file URLs and elapsed time must be finite and nonnegative.")
    }
    let discovery = report.discovery
    let counts = [discovery.directories, discovery.files, discovery.manualLocations, discovery.initialDirectories,
                  discovery.initialFiles, discovery.initialManualLocations, discovery.pendingQueue, discovery.peakPendingQueue]
    guard counts.allSatisfy({ $0 >= 0 }), discovery.directories >= discovery.initialDirectories,
          discovery.files >= discovery.initialFiles, discovery.manualLocations >= discovery.initialManualLocations,
          discovery.manualLocations <= discovery.files, discovery.initialManualLocations <= discovery.initialFiles,
          discovery.peakPendingQueue >= discovery.pendingQueue,
          !discovery.finished || discovery.pendingQueue == 0,
          discovery.finished == (discovery.endedElapsedSeconds != nil),
          discovery.startedElapsedSeconds == 0 else {
        throw ManualToolError(message: "Invalid discovery counters or boundaries; counters cannot be negative or precede initial counters, peak pending must cover current pending, and finished must match the end boundary.")
    }
    try validatePerformanceBoundary(start: discovery.startedElapsedSeconds, end: discovery.endedElapsedSeconds,
                                    seconds: discovery.cumulative.seconds, elapsed: report.elapsedSeconds, phase: "discovery")
    for rates in [discovery.cumulative, discovery.lastInterval] {
        let values = [rates.seconds, rates.directoriesPerSecond, rates.filesPerSecond, rates.manualsPerSecond]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), rates.seconds <= report.elapsedSeconds + 0.000001 else {
            throw ManualToolError(message: "Invalid discovery rates; interval duration and rates must be finite, nonnegative, and inside the scan duration.")
        }
    }
    let expected = scanPerformanceRates(seconds: discovery.cumulative.seconds,
        directories: discovery.directories - discovery.initialDirectories, files: discovery.files - discovery.initialFiles,
        manuals: discovery.manualLocations - discovery.initialManualLocations)
    guard performanceRateMatches(discovery.cumulative.directoriesPerSecond, expected.directoriesPerSecond),
          performanceRateMatches(discovery.cumulative.filesPerSecond, expected.filesPerSecond),
          performanceRateMatches(discovery.cumulative.manualsPerSecond, expected.manualsPerSecond) else {
        throw ManualToolError(message: "Discovery cumulative rates disagree with this segment's inspected counters and duration.")
    }
    if let indexing = report.indexing {
        let counts = [indexing.total, indexing.completed, indexing.succeeded, indexing.failed,
                      indexing.queued, indexing.active, indexing.peakQueued]
        guard counts.allSatisfy({ $0 >= 0 }), indexing.completed <= indexing.total,
              indexing.succeeded <= indexing.completed, indexing.failed == indexing.completed - indexing.succeeded,
              indexing.queued <= indexing.total - indexing.completed,
              indexing.active == indexing.total - indexing.completed - indexing.queued,
              indexing.active <= 4, indexing.peakQueued >= indexing.queued, indexing.peakQueued <= indexing.total,
              indexing.finished == (indexing.endedElapsedSeconds != nil),
              !indexing.finished || indexing.completed == indexing.total,
              indexing.manualsPerSecond.isFinite, indexing.manualsPerSecond >= 0 else {
            throw ManualToolError(message: "Invalid indexing counters or rates; completed must equal succeeded plus failed, completed/queued/active must partition total, active cannot exceed four workers, and completed phases must have no unfinished manuals.")
        }
        try validatePerformanceBoundary(start: indexing.startedElapsedSeconds, end: indexing.endedElapsedSeconds,
                                        seconds: indexing.seconds, elapsed: report.elapsedSeconds, phase: "indexing")
        guard let discoveryEnd = discovery.endedElapsedSeconds, indexing.startedElapsedSeconds >= discoveryEnd else {
            throw ManualToolError(message: "Indexing starts before the recorded discovery phase ended.")
        }
        let expected = indexing.seconds > 0 ? Double(indexing.succeeded) / indexing.seconds : 0
        guard performanceRateMatches(indexing.manualsPerSecond, expected) else {
            throw ManualToolError(message: "Indexing throughput disagrees with confirmed successful entries and phase duration.")
        }
    }
    if report.state == .completed {
        guard discovery.finished, report.indexing?.finished ?? true else {
            throw ManualToolError(message: "Completed diagnostics contain an unfinished discovery or indexing phase.")
        }
    }
    if let work = report.indexingWork {
        guard report.indexing != nil, work.peakInventoryBytes >= work.lastInventoryBytes else {
            throw ManualToolError(message: "Indexing work diagnostics require an indexing phase and consistent inventory sizes.")
        }
        for cost in [work.formatterBatches, work.indexTransactions, work.metadataPublications, work.inventoryWrites] {
            guard cost.operations >= 0, cost.totalSeconds.isFinite, cost.totalSeconds >= 0, cost.totalSeconds <= report.elapsedSeconds + 0.000001,
                  cost.worstSeconds.isFinite, cost.worstSeconds >= 0, cost.worstSeconds <= cost.totalSeconds + 0.000001,
                  cost.worstSeconds <= report.elapsedSeconds + 0.000001,
                  cost.operations != 0 || (cost.totalSeconds == 0 && cost.worstSeconds == 0) else {
                throw ManualToolError(message: "Invalid indexing cost counters or monotonic durations.")
            }
        }
    }
    if let cancellation = report.cancellationLatencySeconds {
        guard report.state != .running, cancellation.isFinite, cancellation >= 0,
              cancellation <= report.elapsedSeconds + 0.000001 else {
            throw ManualToolError(message: "Invalid cancellationLatencySeconds; durable cancellation latency must be finite, nonnegative, and inside a stopped scan's duration.")
        }
    }
    guard report.memorySampleCount >= 0, report.responsivenessSampleCount >= 0,
          report.memorySamples.count == min(report.memorySampleCount, 3600),
          report.responsivenessSamples.count == min(report.responsivenessSampleCount, 3600),
          report.worstMainActorDelayMilliseconds.isFinite, report.worstMainActorDelayMilliseconds >= 0,
          report.memorySampleCount != 0 || report.observedPeakResidentBytes == 0,
          report.responsivenessSampleCount != 0 || report.worstMainActorDelayMilliseconds == 0,
          report.memorySamples.allSatisfy({ $0.residentBytes > 0 && $0.residentBytes <= report.observedPeakResidentBytes }),
          report.responsivenessSamples.allSatisfy({ $0.mainActorDelayMilliseconds.isFinite && $0.mainActorDelayMilliseconds >= 0 && $0.mainActorDelayMilliseconds <= report.worstMainActorDelayMilliseconds }) else {
        throw ManualToolError(message: "Invalid memory or responsiveness samples; series must retain at most 3600 samples, counts must match retained samples, and finite nonnegative measurements cannot exceed recorded peaks.")
    }
    try validatePerformanceSamples(times: report.memorySamples.map(\.elapsedSeconds), elapsed: report.elapsedSeconds, series: "memory")
    try validatePerformanceSamples(times: report.responsivenessSamples.map(\.elapsedSeconds), elapsed: report.elapsedSeconds, series: "responsiveness")
}

func validatePerformanceBoundary(start: Double, end: Double?, seconds: Double, elapsed: Double, phase: String) throws {
    let finish = end ?? elapsed
    guard start.isFinite, finish.isFinite, seconds.isFinite, start >= 0, finish >= start,
          finish <= elapsed + 0.000001, seconds >= 0, abs(seconds - (finish - start)) <= 0.000001 else {
        throw ManualToolError(message: "Invalid \(phase) timing boundary; finite nonnegative phase duration must equal end minus start and fit inside elapsedSeconds.")
    }
}

func validatePerformanceSamples(times: [Double], elapsed: Double, series: String) throws {
    guard times.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= elapsed + 0.000001 }),
          zip(times, times.dropFirst()).allSatisfy({ pair in pair.0 <= pair.1 }) else {
        throw ManualToolError(message: "Invalid \(series) sample timestamps; samples must be chronological, finite, nonnegative, and inside elapsedSeconds.")
    }
}

func performanceRateMatches(_ actual: Double, _ expected: Double) -> Bool {
    abs(actual - expected) <= max(1, abs(expected)) * 0.000001
}

func scanPerformanceDecodingReason(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, let context):
        return "Missing required field \((context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))"
    case .typeMismatch(let type, let context):
        return "Invalid field \(context.codingPath.map(\.stringValue).joined(separator: ".")); expected \(type): \(context.debugDescription)"
    case .valueNotFound(let type, let context):
        return "Missing required \(type) value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
    case .dataCorrupted(let context):
        return "Invalid JSON/value at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
    @unknown default:
        return error.localizedDescription
    }
}
