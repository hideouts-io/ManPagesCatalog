import Foundation
import Combine
import Darwin

enum LibraryBenchmarkCommand: String { case scan, index }

struct LibraryBenchmarkOptions {
    let command: LibraryBenchmarkCommand
    let output: URL
    let root: URL?
    let cancelAfterIndexed: Int
    let deadlineSeconds: Double
}

struct LibraryBenchmarkOwnership: Codable {
    let owner: String
    let root: URL
}

struct LibraryBenchmarkSample: Codable {
    let seconds: Double
    let phase: String
    let manuals: Int
    let indexed: Int
    let completedAttempts: Int
    let residentBytes: UInt64
    let inventoryBytes: UInt64
}

struct LibraryBenchmarkSearch: Codable {
    let phase: String
    let query: String
    let fullText: Bool
    let milliseconds: Double
    let returnedName: String?
    let superseded: Bool
}

struct LibraryBenchmarkResult: Codable {
    let command: String
    let state: String
    let elapsedSeconds: Double
    let manuals: Int
    let indexed: Int
    let peakResidentBytes: UInt64
    let cancellationRequestedSeconds: Double?
    let cancellationToStoppedSeconds: Double?
    let samples: [LibraryBenchmarkSample]
    let searches: [LibraryBenchmarkSearch]
    let limitations: [String]
}

@main
struct LibraryBenchmark {
    static func main() async {
        do { try await run(options: libraryBenchmarkOptions(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            FileHandle.standardError.write(Data("Library benchmark failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func run(options: LibraryBenchmarkOptions) async throws {
        let ownershipURL = options.output.appendingPathComponent(".library-benchmark-owner.json")
        switch options.command {
        case .scan:
            guard let root = options.root, !FileManager.default.fileExists(atPath: options.output.path) else {
                throw ManualToolError(message: "Fresh library benchmark requires a root and a new output directory: \(options.output.path).")
            }
            try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
            try JSONEncoder().encode(LibraryBenchmarkOwnership(owner: "ManPagesCatalog LibraryBenchmark", root: root))
                .write(to: ownershipURL, options: .atomic)
        case .index:
            let owned = try JSONDecoder().decode(LibraryBenchmarkOwnership.self, from: Data(contentsOf: ownershipURL))
            guard owned.owner == "ManPagesCatalog LibraryBenchmark", owned.root.isFileURL else {
                throw ManualToolError(message: "Cannot index an unowned benchmark library at \(options.output.path).")
            }
            _ = try loadDiscovery(options.output.appendingPathComponent("discovery-v1.json"))
        }
        let suite = "ManPagesCatalog.LibraryBenchmark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ManualToolError(message: "Cannot create isolated benchmark defaults \(suite).") }
        defer { defaults.removePersistentDomain(forName: suite) }
        if let root = options.root { defaults.set([root.path], forKey: "manualRoots") }
        let store = LibraryStore(directory: options.output, defaults: defaults)
        let began = ProcessInfo.processInfo.systemUptime
        if options.command == .scan { store.scanSelectedRoots() }
        else { store.continueIndexing() }
        var samples: [LibraryBenchmarkSample] = []
        var searches: [LibraryBenchmarkSearch] = []
        var peak: UInt64 = 0
        var cancelAt: Double?
        var nextSearch: Double = 0
        var searchOrdinal: Int = 0
        while store.isIndexing {
            let now = ProcessInfo.processInfo.systemUptime
            let resident = try scanResidentMemory()
            peak = max(peak, resident)
            let inventory = options.output.appendingPathComponent("discovery-v1.json")
            let bytes: UInt64
            if FileManager.default.fileExists(atPath: inventory.path) {
                bytes = try inventory.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(UInt64.init) ?? 0
            } else { bytes = 0 }
            samples.append(LibraryBenchmarkSample(seconds: now - began, phase: store.phase.rawValue, manuals: store.pages.count,
                indexed: store.indexedCount, completedAttempts: store.indexCompleted, residentBytes: resident, inventoryBytes: bytes))
            if cancelAt == nil && (now - began >= options.deadlineSeconds || (options.cancelAfterIndexed > 0 && store.indexCompleted >= options.cancelAfterIndexed)) {
                cancelAt = now
                store.stop()
            }
            if cancelAt == nil, !store.pages.isEmpty, now >= nextSearch {
                let terms = ["launchctl", "ping", "catalogbench-000001", "catalogindex"]
                let query = terms[searchOrdinal % terms.count]
                let fullText = searchOrdinal % terms.count == 3
                let start = ProcessInfo.processInfo.systemUptime
                store.fullText = fullText
                store.query = query
                let phase = store.phase.rawValue
                let first = await store.firstResultForCurrentSearch()
                searches.append(LibraryBenchmarkSearch(phase: phase, query: query, fullText: fullText,
                    milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, returnedName: first?.name, superseded: first == nil))
                nextSearch = ProcessInfo.processInfo.systemUptime + 5
                searchOrdinal += 1
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let stopped = ProcessInfo.processInfo.systemUptime
        let report = try loadScanPerformance(options.output.appendingPathComponent("scan-performance-v1.json"))
        let saved = try loadDiscovery(options.output.appendingPathComponent("discovery-v1.json"))
        let result = LibraryBenchmarkResult(command: options.command.rawValue, state: report.state.rawValue,
            elapsedSeconds: stopped - began, manuals: saved.pages.count, indexed: saved.pages.filter(\.indexed).count,
            peakResidentBytes: max(peak, report.observedPeakResidentBytes), cancellationRequestedSeconds: cancelAt.map { $0 - began },
            cancellationToStoppedSeconds: cancelAt.map { stopped - $0 }, samples: samples, searches: searches,
            limitations: ["The production LibraryStore, discovery, formatter, FTS and persistence paths ran; this CLI does not render SwiftUI or WebKit.",
                "Search measurements start at model query assignment and end at committed results; they include the debounce and scheduling, not native input or pixels. A nil first result may indicate no indexed match or supersession.",
                "RSS is main-process sampling at a 250 ms target plus the production one-second sampler; time -l records a separate kernel high-water mark.",
                "Cancellation-to-stopped observation includes this harness polling interval; the exported production report contains its own durability boundary.",
                "The deadline requests ordinary cancellation and retains the isolated library. Cache state and other host activity are uncontrolled."])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = options.output.appendingPathComponent("library-result-\(UUID().uuidString).json")
        try encoder.encode(result).write(to: destination, options: .atomic)
        print("state=\(result.state) manuals=\(result.manuals) indexed=\(result.indexed) seconds=\(result.elapsedSeconds) result=\(destination.path)")
        if let error = store.errorMessage { throw ManualToolError(message: "\(error) Retained benchmark evidence: \(destination.path).") }
    }
}

func libraryBenchmarkOptions(_ arguments: [String]) throws -> LibraryBenchmarkOptions {
    let usage = "Usage: library-benchmark scan|index --output /isolated/library --cancel-after-indexed NUMBER --deadline-seconds NUMBER [--root /manual/corpus]."
    guard let first = arguments.first, let command = LibraryBenchmarkCommand(rawValue: first) else { throw ManualToolError(message: usage) }
    var output: URL?
    var root: URL?
    var cancel: Int?
    var deadline: Double?
    var position = 1
    while position < arguments.count {
        guard position + 1 < arguments.count else { throw ManualToolError(message: usage) }
        let value = arguments[position + 1]
        switch arguments[position] {
        case "--output":
            guard output == nil, value.hasPrefix("/") else { throw ManualToolError(message: usage) }
            output = URL(fileURLWithPath: value).standardizedFileURL
        case "--root":
            guard root == nil, value.hasPrefix("/") else { throw ManualToolError(message: usage) }
            root = URL(fileURLWithPath: value).standardizedFileURL
        case "--cancel-after-indexed":
            guard cancel == nil, let number = Int(value), number >= 0 else { throw ManualToolError(message: usage) }
            cancel = number
        case "--deadline-seconds":
            guard deadline == nil, let number = Double(value), number.isFinite, number > 0, number <= 3600 else { throw ManualToolError(message: usage) }
            deadline = number
        default: throw ManualToolError(message: "Unknown benchmark option \(arguments[position]). \(usage)")
        }
        position += 2
    }
    guard let output, let cancel, let deadline, (command == .scan ? root != nil : root == nil) else { throw ManualToolError(message: usage) }
    if let root, pathContains(root: root.resolvingSymlinksInPath().path, path: output.resolvingSymlinksInPath().path) || pathContains(root: output.resolvingSymlinksInPath().path, path: root.resolvingSymlinksInPath().path) {
        throw ManualToolError(message: "Benchmark output must be separate from the scanned manual corpus.")
    }
    return LibraryBenchmarkOptions(command: command, output: output, root: root, cancelAfterIndexed: cancel, deadlineSeconds: deadline)
}
