import Foundation

struct DiscoveryRootState: Codable, Sendable {
    let root: URL
    var pending: [URL]
    var directories: Int
    var files: Int
    var manuals: Int
    var issues: [DiscoveryIssue]
}

/// A traversal snapshot, not a filesystem change journal. A fresh scan revisits already checked folders.
struct DiscoveryCheckpoint: Codable, Sendable {
    let version: Int
    let title: String
    let started: Date
    let bootReference: Date
    let plan: DiscoveryPlan
    var updated: Date
    var roots: [DiscoveryRootState]
    var visited: [String: String]
    var pages: [ManualPage]

    var pendingCount: Int { roots.reduce(0) { $0 + $1.pending.count } }
    var snapshot: LibraryScan {
        let coverage = roots.map { state in
            SourceCoverage(root: state.root, count: state.manuals, directories: state.directories, files: state.files,
                           completed: state.pending.isEmpty, issues: state.issues + state.pending.map {
                DiscoveryIssue(path: $0.path, kind: .pending, reason: "Queued for inspection; descendants have not yet been counted.")
            })
        } + plan.exclusions.map {
            SourceCoverage(root: URL(fileURLWithPath: $0.path), count: 0, directories: 0, files: 0, completed: false, issues: [$0])
        }
        return LibraryScan(pages: groupedManuals(pages), coverage: coverage, cancelled: pendingCount > 0)
    }
}

func newDiscoveryCheckpoint(plan: DiscoveryPlan, title: String) -> DiscoveryCheckpoint {
    DiscoveryCheckpoint(version: 1, title: title, started: Date(), bootReference: Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime), plan: plan, updated: Date(), roots: plan.roots.map {
        DiscoveryRootState(root: $0, pending: [$0], directories: 0, files: 0, manuals: 0, issues: [])
    }, visited: [:], pages: [])
}

/// The request identity serializes writes and prevents a cancelled worker from replacing newer progress.
actor DiscoveryCheckpointFile {
    private let url: URL
    private var request: UUID?

    init(url: URL) { self.url = url }

    func activate(_ request: UUID) { self.request = request }

    func save(_ checkpoint: DiscoveryCheckpoint, request: UUID) throws {
        guard self.request == request else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }

    func remove(request: UUID) throws {
        guard self.request == request else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func load() throws -> DiscoveryCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let saved = try JSONDecoder().decode(DiscoveryCheckpoint.self, from: Data(contentsOf: url))
            guard abs(saved.bootReference.timeIntervalSince(Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime))) < 10 else {
                throw ManualToolError(message: "The Mac restarted or its clock changed since this scan. Start a fresh scan; inode identities from an earlier boot cannot be reused safely.")
            }
            guard saved.version == 1, saved.roots.map(\.root) == saved.plan.roots,
                  saved.plan.roots.allSatisfy(\.isFileURL), saved.plan.allowedNetworkRoots.allSatisfy(\.isFileURL),
                  saved.roots.allSatisfy({ state in
                      state.files >= 0 && state.directories >= 0 && state.manuals >= 0 &&
                      state.pending.allSatisfy { $0.isFileURL && pathContains(root: state.root.path, path: $0.path) }
                  }) else { throw ManualToolError(message: "Checkpoint has invalid roots, counters, or version.") }
            try validateManualPages(saved.pages)
            return saved
        } catch {
            throw ManualToolError(message: "Cannot resume \(url.path): \(error.localizedDescription) Start a fresh scan to replace this checkpoint. Your existing library is retained.")
        }
    }
}
