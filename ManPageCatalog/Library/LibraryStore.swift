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
    @Published private(set) var pages: [ManualPage] = []
    @Published private(set) var coverage: [SourceCoverage] = []
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
    var sourceRoots: [String] { Set(pages.flatMap(\.locations).map { $0.root.path } + coverage.map { $0.root.path }).sorted() }
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
                try await checkpointFile.remove(request: request)
                resumableScan = false
                try await finishIndexing(request: request, index: index)
            } catch is CancellationError {
                guard request == operationID else { return }
                isIndexing = false
                scanProgress = nil
                let wasIndexing = phase == .indexing
                phase = .paused
                status = wasIndexing ? "Indexing paused • \(indexedCount) of \(pages.count) manuals indexed • reading and name search are ready" : "\(scanMode) paused • \(pages.count) manuals retained • \(pendingLocations) queued locations"
                search()
            } catch {
                guard request == operationID else { return }
                isIndexing = false
                scanProgress = nil
                phase = .needsAttention
                errorMessage = "Library refresh failed: \(error.localizedDescription)"
                status = "Available results remain searchable; review Scan & Sources"
            }
        }
    }

    private func acceptDiscovery(saved: DiscoveryCheckpoint, snapshot: LibraryScan, pages: [ManualPage], request: UUID) throws {
        guard request == operationID else { return }
        self.pages = pages
        coverage = snapshot.coverage
        pendingLocations = saved.pendingCount
        checkpointDate = saved.updated
        resumableScan = saved.pendingCount > 0
        try saveDiscovery()
        search()
    }

    func continueIndexing() {
        guard !isIndexing else { return }
        let request = UUID()
        operationID = request
        isIndexing = true
        errorMessage = nil
        indexingTask = Task {
            do {
                try initializeLibrary()
                guard let index else { throw ManualToolError(message: "Search index was not initialized.") }
                try await finishIndexing(request: request, index: index)
            } catch is CancellationError {
                guard request == operationID else { return }
                isIndexing = false
                phase = .paused
                status = "Indexing paused • \(indexedCount) of \(pages.count) manuals indexed • reading and name search are ready"
            } catch {
                guard request == operationID else { return }
                isIndexing = false
                phase = .needsAttention
                errorMessage = "Indexing failed: \(error.localizedDescription)"
            }
        }
    }

    private func finishIndexing(request: UUID, index: ManualSearchIndex) async throws {
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
        do { try await enrich(pending: pending, request: request, index: index) }
        catch {
            if request == operationID { try saveDiscovery(); search() }
            throw error
        }
        guard request == operationID else { return }
        isIndexing = false
        phase = .ready
        try saveDiscovery()
        let issues = coverage.reduce(0) { $0 + $1.issues.count }
        status = "\(pages.count) unique manuals • \(indexedCount) indexed • \(issues) coverage notices; review Scan & Sources"
        search()
    }

    private func discoveryProgress(_ value: DiscoveryProgress, request: UUID) {
        guard request == operationID else { return }
        scanProgress = value
        status = "\(scanMode): \(value.directories) folders • \(value.files) files checked • \(value.manuals) manual locations"
    }

    private func saveDiscovery() throws {
        let snapshot = LibraryScan(pages: pages, coverage: coverage, cancelled: resumableScan)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("discovery-v1.json"), options: .atomic)
    }

    func stop() { indexingTask?.cancel() }

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

    private func enrich(pending: [ManualPage], request: UUID, index: ManualSearchIndex) async throws {
        // Four formatter jobs keep indexing bounded while the main window stays responsive.
        for offset in stride(from: 0, to: pending.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(pending[offset..<min(offset + 4, pending.count)])
            let outcomes = try await withThrowingTaskGroup(of: ManualIndexOutcome.self) { group in
                for page in batch {
                    group.addTask {
                        do {
                            let formatted = try await formattedManualText(source: page.source)
                            let description = descriptionFromFormattedManual(formatted.text)
                            try await index.store(page: page, text: formatted.text, description: description, diagnostic: formatted.diagnostic)
                            return ManualIndexOutcome(id: page.id, description: description, problem: formatted.diagnostic.isEmpty ? nil : formatted.diagnostic, indexed: true)
                        } catch is CancellationError { throw CancellationError() }
                        catch { return ManualIndexOutcome(id: page.id, description: "", problem: "\(page.source.path): \(error.localizedDescription)", indexed: false) }
                    }
                }
                var values: [ManualIndexOutcome] = []
                for try await value in group { values.append(value) }
                return values
            }
            guard request == operationID else { throw CancellationError() }
            let updates = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.id, $0) })
            pages = pages.map { page in
                guard let value = updates[page.id] else { return page }
                var updated = page
                updated.description = value.description
                updated.problem = value.problem
                updated.indexed = value.indexed
                return updated
            }
            indexCompleted = min(offset + 4, pending.count)
            status = "Indexing descriptions & full text: \(min(offset + 4, pending.count)) of \(pending.count) changed manuals • names are searchable now"
            if offset % 128 == 124 { try saveDiscovery(); search() }
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
