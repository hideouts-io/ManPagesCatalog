import Foundation
import Combine

enum LibraryPhase: String {
    case ready = "Ready"
    case discovering = "Discovering files"
    case indexing = "Indexing descriptions & full text"
    case paused = "Paused"
    case needsAttention = "Needs attention"
}

struct ManualIndexOutcome: Sendable {
    let id: String
    let description: String
    let problem: String?
    let indexed: Bool
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var pages: [ManualPage] = [] {
        didSet { sourceRoots = manualSourceRoots(pages: pages, coverage: coverage) }
    }
    @Published private(set) var coverage: [SourceCoverage] = [] {
        didSet { sourceRoots = manualSourceRoots(pages: pages, coverage: coverage) }
    }
    private(set) var sourceRoots: [String] = []
    @Published private(set) var results: [ManualSearchResult] = []
    @Published private(set) var status = "Ready to discover installed manuals"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isIndexing = false
    @Published private(set) var phase: LibraryPhase = .ready
    @Published private(set) var resumableScan = false
    @Published private(set) var pendingLocations = 0
    @Published private(set) var checkpointDate: Date?
    @Published private(set) var indexCompleted = 0
    @Published private(set) var indexTotal = 0
    @Published var query = "" { didSet { search() } }
    @Published var section: String? { didSet { search() } }
    @Published var root: String? { didSet { search() } }
    @Published var fullText = false { didSet { search() } }
    @Published private(set) var scanProgress: DiscoveryProgress?
    @Published private(set) var performanceReport: ScanPerformanceReport?
    private var performanceRecorder: ScanPerformanceRecorder?
    private var performanceSampling: Task<Void, Never>?
    private var cancellationRequested: Double?
    @Published private(set) var scanMode = "Standard Scan"
    @Published private(set) var additionalRoots: [String]
    private var index: ManualSearchIndex?
    private var indexingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var operationID = UUID()
    private var searchID = UUID()
    private var resultsID: UUID?
    private let directory: URL
    private let defaults: UserDefaults
    private let checkpointFile: DiscoveryCheckpointFile
    private var opened = false

    init(directory: URL, defaults: UserDefaults) {
        self.directory = directory
        self.defaults = defaults
        checkpointFile = DiscoveryCheckpointFile(url: directory.appendingPathComponent("scan-checkpoint-v1.json"))
        additionalRoots = defaults.stringArray(forKey: "manualRoots") ?? []
    }

    var sections: [String] { Set(pages.map(\.section)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var indexedCount: Int { pages.filter(\.indexed).count }
    var problemPages: [ManualPage] { pages.filter { $0.problem != nil } }

    /// Opening a saved library must not silently replace an interrupted Deep Scan with a Standard Scan.
    func openLibrary() {
        guard !opened else { return }
        opened = true
        let request = operationID
        indexingTask = Task {
            do {
                try initializeLibrary()
                let saved = try await checkpointFile.load()
                guard request == operationID else { return }
                if let saved {
                    resumableScan = saved.pendingCount > 0
                    pendingLocations = saved.pendingCount
                    checkpointDate = saved.updated
                    scanMode = saved.title
                    coverage = saved.snapshot.coverage
                    let retained = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    pages = mergingDiscovery(previous: pages, scan: saved.snapshot).map { page in
                        var value = page
                        if let old = retained[page.id] {
                            value.description = old.description; value.indexed = old.indexed; value.problem = old.problem
                        }
                        return value
                    }
                    phase = saved.pendingCount > 0 ? .paused : .ready
                    status = saved.pendingCount > 0 ? "Saved \(saved.title) • \(pendingLocations) queued locations • Resume in Scan & Sources" : "Discovery saved • \(pages.count) manuals ready • Continue indexing in Scan & Sources"
                    search()
                } else if pages.isEmpty { scan() }
                else {
                    status = "\(pages.count) manuals ready • \(indexedCount) indexed • Scan to refresh"
                    search()
                }
            } catch {
                guard request == operationID else { return }
                errorMessage = error.localizedDescription
                status = "Library needs attention; review Scan & Sources"
            }
        }
    }

    private func initializeLibrary() throws {
        if index == nil { index = try ManualSearchIndex(url: directory.appendingPathComponent("search.sqlite")) }
        if pages.isEmpty {
            let inventory = directory.appendingPathComponent("discovery-v1.json")
            if FileManager.default.fileExists(atPath: inventory.path) {
                let saved = try loadDiscovery(inventory)
                pages = saved.pages
                coverage = saved.coverage
                search()
            }
        }
        if performanceReport == nil {
            let report = directory.appendingPathComponent("scan-performance-v1.json")
            if FileManager.default.fileExists(atPath: report.path) { performanceReport = try loadScanPerformance(report) }
        }
    }

    func scan() {
        startScan(checkpoint: {
            newDiscoveryCheckpoint(plan: try await standardDiscoveryPlan(environment: ProcessInfo.processInfo.environment, additional: self.additionalRoots), title: "Standard Scan")
        })
    }

    func deepScan() {
        startScan(checkpoint: { newDiscoveryCheckpoint(plan: try deepDiscoveryPlan(additional: self.additionalRoots), title: "Deep Scan") })
    }

    func scanSelectedRoots() {
        startScan(checkpoint: {
            newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: self.additionalRoots.map { URL(fileURLWithPath: $0) }, allowedNetworkRoots: self.additionalRoots.map { URL(fileURLWithPath: $0) }, exclusions: []), title: "Selected Folders")
        })
    }

    func resumeScan() {
        startScan(checkpoint: {
            guard let saved = try await self.checkpointFile.load() else {
                throw ManualToolError(message: "No saved scan exists. Start a Standard or Deep Scan.")
            }
            return saved
        })
    }

    private func startScan(checkpoint: @escaping () async throws -> DiscoveryCheckpoint) {
        indexingTask?.cancel()
        performanceSampling?.cancel()
        performanceRecorder = nil
        cancellationRequested = nil
        let request = UUID()
        operationID = request
        errorMessage = nil
        isIndexing = true
        phase = .discovering
        scanProgress = nil
        status = "Preparing discovery…"
        indexingTask = Task {
            do {
                try Task.checkCancellation()
                try initializeLibrary()
                guard let index else { throw ManualToolError(message: "Search index was not initialized.") }
                let selected = try await checkpoint()
                try Task.checkCancellation()
                guard request == operationID else { return }
                scanMode = selected.title
                await checkpointFile.activate(request)
                let cache = Dictionary(try await index.metadata().map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
                try Task.checkCancellation()
                guard request == operationID else { return }
                let recorder = ScanPerformanceRecorder(scanID: request, mode: selected.title, roots: selected.plan.roots,
                    initialDirectories: selected.roots.reduce(0) { $0 + $1.directories }, initialFiles: selected.roots.reduce(0) { $0 + $1.files }, initialManualLocations: selected.pages.count)
                performanceRecorder = recorder
                await recorder.recordDiscovery(directories: selected.roots.reduce(0) { $0 + $1.directories }, files: selected.roots.reduce(0) { $0 + $1.files }, manualLocations: selected.pages.count, pending: selected.pendingCount, path: "Preparing discovery")
                try Task.checkCancellation()
                guard request == operationID else { return }
                beginPerformanceSampling(recorder: recorder, request: request)
                let previous = pages
                let file = checkpointFile
                let worker = Task.detached(priority: .utility) {
                    try await continueDiscovery(checkpoint: selected, previous: previous, progress: { value in
                        await self.discoveryProgress(value, request: request)
                    }, save: { saved in
                        try await file.save(saved, request: request)
                        let snapshot = saved.snapshot
                        let discovered = mergingDiscovery(previous: previous, scan: snapshot).map { page in
                            var updated = page
                            if let cached = cache[page.id], cached.fingerprint == page.fingerprint, page.problem == nil {
                                updated.description = cached.description
                                updated.indexed = true
                                updated.problem = cached.diagnostic.isEmpty ? nil : cached.diagnostic
                            }
                            return updated
                        }
                        try await self.acceptDiscovery(saved: saved, snapshot: snapshot, pages: discovered, request: request)
                    })
                }
                let scan = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard request == operationID else { return }
                scanProgress = nil
                if scan.cancelled || Task.isCancelled { throw CancellationError() }
                await recorder.finishDiscovery()
                try await checkpointFile.remove(request: request)
                try Task.checkCancellation()
                guard request == operationID else { return }
                resumableScan = false
                try await finishIndexing(request: request, index: index)
                await finishPerformance(state: .completed, request: request, durability: "Discovery inventory and search index saved")
                guard request == operationID else { return }
                isIndexing = false
            } catch is CancellationError {
                guard request == operationID else { return }
                scanProgress = nil
                let wasIndexing = phase == .indexing
                phase = .paused
                await finishPerformance(state: .cancelled, request: request, durability: "Worker stopped; latest checkpoint and retained inventory saved")
                guard request == operationID else { return }
                isIndexing = false
                status = wasIndexing ? "Indexing paused • \(indexedCount) of \(pages.count) manuals indexed • reading and name search are ready" : "\(scanMode) paused • \(pages.count) manuals retained • \(pendingLocations) queued locations"
                search()
            } catch {
                guard request == operationID else { return }
                scanProgress = nil
                phase = .needsAttention
                await finishPerformance(state: .failed, request: request, durability: "Failure; inspect error and last successful checkpoint")
                guard request == operationID else { return }
                isIndexing = false
                errorMessage = "Library refresh failed: \(error.localizedDescription)"
                status = "Available results remain searchable; review Scan & Sources"
            }
        }
    }

    private func acceptDiscovery(saved: DiscoveryCheckpoint, snapshot: LibraryScan, pages: [ManualPage], request: UUID) async throws {
        guard request == operationID else { return }
        let inventory = LibraryScan(pages: pages, coverage: snapshot.coverage, cancelled: saved.pendingCount > 0)
        try await checkpointFile.saveInventory(inventory, request: request)
        guard request == operationID else { return }
        self.pages = pages
        coverage = snapshot.coverage
        pendingLocations = saved.pendingCount
        checkpointDate = saved.updated
        resumableScan = saved.pendingCount > 0
        search()
    }

    func continueIndexing() {
        guard !isIndexing else { return }
        let request = UUID()
        operationID = request
        isIndexing = true
        errorMessage = nil
        performanceSampling?.cancel()
        performanceRecorder = nil
        cancellationRequested = nil
        indexingTask = Task {
            do {
                try Task.checkCancellation()
                guard request == operationID else { return }
                try initializeLibrary()
                guard let index else { throw ManualToolError(message: "Search index was not initialized.") }
                await checkpointFile.activate(request)
                try Task.checkCancellation()
                guard request == operationID else { return }
                let recorder = ScanPerformanceRecorder(scanID: request, mode: "Indexing Only", roots: coverage.map(\.root),
                    initialDirectories: 0, initialFiles: 0, initialManualLocations: 0)
                performanceRecorder = recorder
                await recorder.finishDiscovery()
                try Task.checkCancellation()
                guard request == operationID else { return }
                beginPerformanceSampling(recorder: recorder, request: request)
                try await finishIndexing(request: request, index: index)
                await finishPerformance(state: .completed, request: request, durability: "Retained inventory and search index saved")
                guard request == operationID else { return }
                isIndexing = false
            } catch is CancellationError {
                guard request == operationID else { return }
                phase = .paused
                await finishPerformance(state: .cancelled, request: request, durability: "Indexing stopped; retained inventory and completed index writes saved")
                guard request == operationID else { return }
                isIndexing = false
                status = "Indexing paused • \(indexedCount) of \(pages.count) manuals indexed • reading and name search are ready"
            } catch {
                guard request == operationID else { return }
                phase = .needsAttention
                await finishPerformance(state: .failed, request: request, durability: "Indexing failed; inspect error and retained inventory")
                guard request == operationID else { return }
                isIndexing = false
                errorMessage = "Indexing failed: \(error.localizedDescription)"
            }
        }
    }

    private func finishIndexing(request: UUID, index: ManualSearchIndex) async throws {
        try Task.checkCancellation()
        guard request == operationID else { throw CancellationError() }
        let recorder = performanceRecorder
        phase = .indexing
        let pending = pages.filter { !$0.indexed && $0.problem == nil }.sorted { left, right in
            let leftCommand = ["1", "8"].contains(String(left.section.prefix(1)))
            let rightCommand = ["1", "8"].contains(String(right.section.prefix(1)))
            if leftCommand != rightCommand { return leftCommand }
            if (left.root.path == "/usr/share/man") != (right.root.path == "/usr/share/man") { return left.root.path == "/usr/share/man" }
            return left.id < right.id
        }
        indexCompleted = 0
        indexTotal = pending.count
        await recorder?.beginIndexing(total: pending.count)
        try Task.checkCancellation()
        guard request == operationID else { throw CancellationError() }
        do { try await enrich(pending: pending, request: request, index: index, recorder: recorder) }
        catch {
            if request == operationID {
                try await saveDiscovery(request: request)
                guard request == operationID else { throw CancellationError() }
                search()
            }
            throw error
        }
        guard request == operationID else { return }
        await recorder?.finishIndexing()
        guard request == operationID else { return }
        try await saveDiscovery(request: request)
        try Task.checkCancellation()
        guard request == operationID else { throw CancellationError() }
        phase = .ready
        let issues = coverage.reduce(0) { $0 + $1.issues.count }
        status = "\(pages.count) unique manuals • \(indexedCount) indexed • \(issues) coverage notices; review Scan & Sources"
        search()
    }

    private func discoveryProgress(_ value: DiscoveryProgress, request: UUID) async {
        guard request == operationID else { return }
        let recorder = performanceRecorder
        await recorder?.recordDiscovery(directories: value.directories, files: value.files, manualLocations: value.manuals, pending: value.pending, path: value.path)
        await recorder?.recordPendingPeak(value.peakPending)
        guard request == operationID else { return }
        scanProgress = value
        status = "\(scanMode): \(value.directories) folders • \(value.files) files checked • \(value.manuals) manual locations"
    }

    private func saveDiscovery(request: UUID) async throws {
        guard request == operationID else { throw CancellationError() }
        let snapshot = LibraryScan(pages: pages, coverage: coverage, cancelled: resumableScan)
        try await checkpointFile.saveInventory(snapshot, request: request)
        guard request == operationID else { throw CancellationError() }
    }

    func stop() {
        if cancellationRequested == nil { cancellationRequested = ProcessInfo.processInfo.systemUptime }
        indexingTask?.cancel()
    }

    /// Legacy coverage remains an array; timing diagnostics are a named companion export.
    func exportCoverage(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(coverage).write(to: url, options: .atomic)
        guard let performanceReport else { throw ManualToolError(message: "Coverage was saved, but this catalog has no measured scan diagnostics. Run a scan before exporting performance.") }
        try encoder.encode(performanceReport).write(to: url.deletingPathExtension().appendingPathExtension("performance.json"), options: .atomic)
    }

    private func beginPerformanceSampling(recorder: ScanPerformanceRecorder, request: UUID) {
        performanceSampling?.cancel()
        performanceSampling = Task {
            do {
                while !Task.isCancelled, request == operationID {
                    try await recorder.sampleMemory()
                    await recorder.sampleResponsiveness()
                    let report = await recorder.snapshot()
                    guard !Task.isCancelled, request == operationID else { return }
                    performanceReport = report
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch is CancellationError { return }
            catch { if request == operationID { errorMessage = "Local scan diagnostics failed: \(error.localizedDescription)" } }
        }
    }

    private func finishPerformance(state: ScanPerformanceState, request: UUID, durability: String) async {
        guard request == operationID, let recorder = performanceRecorder else { return }
        let sampler = performanceSampling
        sampler?.cancel()
        await sampler?.value
        guard request == operationID else { return }
        if let cancellationRequested { await recorder.requestCancellation(atUptime: cancellationRequested) }
        await recorder.finish(state: state, durability: durability)
        let report = await recorder.snapshot()
        guard request == operationID else { return }
        performanceReport = report
        do { try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("scan-performance-v1.json"), options: .atomic) }
        catch { errorMessage = "Cannot preserve local scan diagnostics: \(error.localizedDescription)" }
    }

    func addRoot(_ url: URL) {
        if !additionalRoots.contains(url.path) { additionalRoots.append(url.path) }
        defaults.set(additionalRoots, forKey: "manualRoots")
        scanSelectedRoots()
    }

    func removeRoot(_ path: String) {
        additionalRoots.removeAll { $0 == path }
        defaults.set(additionalRoots, forKey: "manualRoots")
        scan()
    }

    func searchAll() { section = nil; root = nil }

    /// Return commits the current query only after its debounced results are ready.
    func firstResultForCurrentSearch() async -> ManualPage? {
        let request = searchID
        await searchTask?.value
        guard request == searchID, request == resultsID else { return nil }
        return results.first?.page
    }

    func reference(name: String, section: String, preferredRoot: URL?) -> ManualPage? {
        let matches = pages.compactMap { page -> ManualPage? in
            let locations = page.locations.filter { $0.name == name && $0.section == section }
            guard let location = locations.first(where: { $0.root == preferredRoot }) ?? locations.first else { return nil }
            return page.at(location)
        }
        return matches.first(where: { $0.root == preferredRoot }) ?? matches.first
    }

    private func enrich(pending: [ManualPage], request: UUID, index: ManualSearchIndex, recorder: ScanPerformanceRecorder?) async throws {
        // Four formatter jobs keep indexing bounded while the main window stays responsive.
        var succeeded = 0
        var failed = 0
        for offset in stride(from: 0, to: pending.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(pending[offset..<min(offset + 4, pending.count)])
            await recorder?.recordIndexing(completed: offset, queued: max(0, pending.count - offset - batch.count), active: batch.count, succeeded: succeeded, failed: failed)
            guard request == operationID else { throw CancellationError() }
            let outcomes = await withTaskGroup(of: ManualIndexOutcome?.self) { group in
                for page in batch {
                    group.addTask {
                        do {
                            let formatted = try await formattedManualText(source: page.source)
                            let description = descriptionFromFormattedManual(formatted.text)
                            try await index.store(page: page, text: formatted.text, description: description, diagnostic: formatted.diagnostic)
                            return ManualIndexOutcome(id: page.id, description: description, problem: formatted.diagnostic.isEmpty ? nil : formatted.diagnostic, indexed: true)
                        } catch is CancellationError { return nil }
                        catch { return ManualIndexOutcome(id: page.id, description: "", problem: "\(page.source.path): \(error.localizedDescription)", indexed: false) }
                    }
                }
                var values: [ManualIndexOutcome] = []
                for await value in group { if let value { values.append(value) } }
                return values
            }
            guard request == operationID else { throw CancellationError() }
            succeeded += outcomes.filter(\.indexed).count
            failed += outcomes.filter { !$0.indexed }.count
            let updates = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.id, $0) })
            pages = pages.map { page in
                guard let value = updates[page.id] else { return page }
                var updated = page
                updated.description = value.description
                updated.problem = value.problem
                updated.indexed = value.indexed
                return updated
            }
            let completed = succeeded + failed
            await recorder?.recordIndexing(completed: completed, queued: pending.count - completed, active: 0, succeeded: succeeded, failed: failed)
            guard request == operationID else { throw CancellationError() }
            indexCompleted = completed
            status = "Indexing descriptions & full text: \(min(offset + 4, pending.count)) of \(pending.count) changed manuals • names are searchable now"
            if Task.isCancelled || outcomes.count != batch.count { throw CancellationError() }
            if offset % 128 == 124 {
                try await saveDiscovery(request: request)
                guard request == operationID else { throw CancellationError() }
                search()
            }
        }
    }

    private func search() {
        searchTask?.cancel()
        let request = UUID()
        searchID = request
        let query = query, section = section, root = root, pages = pages, fullText = fullText, index = index
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
                let matches: Set<String>
                if fullText, let index { matches = try await index.matchingIDs(query: query) }
                else { matches = [] }
                let found = await Task.detached(priority: .userInitiated) {
                    rankedManuals(pages: pages, query: query, section: section, root: root, fullText: matches)
                }.value
                guard !Task.isCancelled, request == searchID else { return }
                results = found
                resultsID = request
            } catch is CancellationError { return }
            catch {
                guard request == searchID else { return }
                errorMessage = "Search failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Source filters depend on inventory changes, not high-frequency progress or search updates.
func manualSourceRoots(pages: [ManualPage], coverage: [SourceCoverage]) -> [String] {
    Set(pages.flatMap(\.locations).map { $0.root.path } + coverage.map { $0.root.path }).sorted()
}
