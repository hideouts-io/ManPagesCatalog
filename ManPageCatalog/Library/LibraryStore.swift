import Foundation
import Combine

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

    init(directory: URL, defaults: UserDefaults) {
        self.directory = directory
        self.defaults = defaults
        additionalRoots = defaults.stringArray(forKey: "manualRoots") ?? []
    }

    var sections: [String] { Set(pages.map(\.section)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var sourceRoots: [String] { Set(pages.flatMap(\.locations).map { $0.root.path } + coverage.map { $0.root.path }).sorted() }
    var indexedCount: Int { pages.filter(\.indexed).count }
    var problemPages: [ManualPage] { pages.filter { $0.problem != nil } }

    func scan() {
        startScan(plan: { try await standardDiscoveryPlan(environment: ProcessInfo.processInfo.environment, additional: self.additionalRoots) }, title: "Standard Scan")
    }

    func deepScan() {
        startScan(plan: { try deepDiscoveryPlan(additional: self.additionalRoots) }, title: "Deep Scan")
    }

    func scanSelectedRoots() {
        startScan(plan: { DiscoveryPlan(roots: self.additionalRoots.map { URL(fileURLWithPath: $0) }, allowedNetworkRoots: self.additionalRoots.map { URL(fileURLWithPath: $0) }, exclusions: []) }, title: "Selected Folders")
    }

    private func startScan(plan: @escaping () async throws -> DiscoveryPlan, title: String) {
        indexingTask?.cancel()
        let request = UUID()
        operationID = request
        errorMessage = nil
        isIndexing = true
        scanMode = title
        scanProgress = nil
        status = "\(title): discovering documentation…"
        indexingTask = Task {
            do {
                if index == nil { index = try ManualSearchIndex(url: directory.appendingPathComponent("search.sqlite")) }
                guard let index else { throw ManualToolError(message: "Search index was not initialized.") }
                if pages.isEmpty {
                    let inventory = directory.appendingPathComponent("discovery-v1.json")
                    if FileManager.default.fileExists(atPath: inventory.path) {
                        let saved = try loadDiscovery(inventory)
                        pages = saved.pages
                        coverage = saved.coverage
                        search()
                    }
                }
                let selectedPlan = try await plan()
                try Task.checkCancellation()
                let previous = pages
                let worker = Task.detached(priority: .utility) {
                    await discoverLibrary(plan: selectedPlan, previous: previous) { value in
                        await self.discoveryProgress(value, request: request)
                    }
                }
                let scan = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard request == operationID else { return }
                coverage = scan.coverage
                scanProgress = nil
                if scan.cancelled || Task.isCancelled { throw CancellationError() }
                let discovered = mergingDiscovery(previous: previous, scan: scan)
                let cache = Dictionary(try await index.metadata().map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
                guard request == operationID else { return }
                pages = discovered.map { page in
                    var updated = page
                    if let cached = cache[page.id], !page.fingerprint.isEmpty, cached.fingerprint == page.fingerprint, page.problem == nil {
                        updated.description = cached.description
                        updated.indexed = true
                        updated.problem = cached.diagnostic.isEmpty ? nil : cached.diagnostic
                    }
                    return updated
                }
                try saveDiscovery()
                search()
                let pending = pages.filter { !$0.indexed && $0.problem == nil }.sorted { left, right in
                    let leftCommand = ["1", "8"].contains(String(left.section.prefix(1)))
                    let rightCommand = ["1", "8"].contains(String(right.section.prefix(1)))
                    if leftCommand != rightCommand { return leftCommand }
                    let leftSystem = left.root.path == "/usr/share/man"
                    let rightSystem = right.root.path == "/usr/share/man"
                    if leftSystem != rightSystem { return leftSystem }
                    return left.id < right.id
                }
                try await enrich(pending: pending, request: request, index: index)
                guard request == operationID else { return }
                isIndexing = false
                try saveDiscovery()
                let issues = coverage.reduce(0) { $0 + $1.issues.count }
                status = "\(title) finished • \(pages.count) unique manuals • \(indexedCount) indexed • \(issues) coverage issues; review Sources"
                search()
            } catch is CancellationError {
                guard request == operationID else { return }
                isIndexing = false
                scanProgress = nil
                status = "\(title) stopped • previous discoveries retained • \(indexedCount) indexed"
                search()
            } catch {
                guard request == operationID else { return }
                isIndexing = false
                scanProgress = nil
                errorMessage = "\(title) could not refresh the library: \(error.localizedDescription)"
                status = "Library refresh failed; available results remain searchable"
            }
        }
    }

    private func discoveryProgress(_ value: DiscoveryProgress, request: UUID) {
        guard request == operationID else { return }
        scanProgress = value
        status = "\(scanMode): \(value.directories) folders • \(value.files) files checked • \(value.manuals) manual locations"
    }

    private func saveDiscovery() throws {
        let snapshot = LibraryScan(pages: pages, coverage: coverage, cancelled: false)
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
            status = "Indexing \(min(offset + 4, pending.count)) of \(pending.count) changed manuals • names are searchable now"
            if offset % 128 == 124 { search() }
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
