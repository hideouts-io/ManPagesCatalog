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
    var indexedCount: Int { pages.filter(\.indexed).count }
    var problemPages: [ManualPage] { pages.filter { $0.problem != nil } }

    func scan() {
        indexingTask?.cancel()
        let request = UUID()
        operationID = request
        errorMessage = nil
        isIndexing = true
        status = "Discovering manual directories…"
        indexingTask = Task {
            do {
                if index == nil { index = try ManualSearchIndex(url: directory.appendingPathComponent("search.sqlite")) }
                guard let index else { throw ManualToolError(message: "Search index was not initialized.") }
                let roots = try await systemLibraryRoots(environment: ProcessInfo.processInfo.environment, additional: additionalRoots)
                let scan = try await Task.detached(priority: .utility) { try scanLibrary(roots: roots) }.value
                let cache = Dictionary(try await index.metadata().map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
                guard request == operationID else { return }
                pages = scan.pages.map { page in
                    var updated = page
                    if let cached = cache[page.id], !page.fingerprint.isEmpty, cached.fingerprint == page.fingerprint, page.problem == nil {
                        updated.description = cached.description
                        updated.indexed = true
                        updated.problem = cached.diagnostic.isEmpty ? nil : cached.diagnostic
                    }
                    return updated
                }
                coverage = scan.coverage
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
                status = "\(pages.count) manuals • \(indexedCount) indexed • \(problemPages.count) manuals with issues"
                search()
            } catch is CancellationError {
                guard request == operationID else { return }
                isIndexing = false
                status = "Indexing stopped • \(indexedCount) of \(pages.count) manuals indexed"
                search()
            } catch {
                guard request == operationID else { return }
                isIndexing = false
                errorMessage = error.localizedDescription
                status = "Library refresh failed; available results remain searchable"
            }
        }
    }

    func stop() { indexingTask?.cancel() }

    func addRoot(_ url: URL) {
        if !additionalRoots.contains(url.path) { additionalRoots.append(url.path) }
        defaults.set(additionalRoots, forKey: "manualRoots")
        scan()
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
        let matches = pages.filter { $0.name == name && $0.section == section }
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
