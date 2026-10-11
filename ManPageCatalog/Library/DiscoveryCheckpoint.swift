import Foundation
import CryptoKit
import Darwin

let maximumDiscoveryDirectoryDepth: Int = 128

enum DiscoveryBootReferenceClock: String, Codable, Sendable { case continuous }

struct DiscoveryDirectoryMetadata: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    var identity: String { "\(device):\(inode)" }
}

/// An ordinal and ordered prefix fingerprint are verified by replay; DIR cookies are never persisted.
struct DiscoveryDirectoryCursor: Codable, Sendable {
    let directory: URL
    let metadata: DiscoveryDirectoryMetadata
    var consumedEntries: Int
    var prefixDigest: String
    var pendingEntry: String?
}

struct DiscoveryRootState: Codable, Sendable {
    let root: URL
    var pending: [URL]
    var directoriesInProgress: [DiscoveryDirectoryCursor]
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
    /// Missing on legacy checkpoints, whose awake-time reference must not be reinterpreted.
    let bootReferenceClock: DiscoveryBootReferenceClock?
    let plan: DiscoveryPlan
    var updated: Date
    var roots: [DiscoveryRootState]
    var visited: [String: String]
    /// Captured only when a directory opens successfully; absent ownership stays unknown on legacy resume.
    var visitedRootIndices: [String: Int]?
    var pages: [ManualPage]
    var peakPending: Int?

    /// Frames stand for unfinished enumeration, not a count of unknown descendant files.
    var pendingCount: Int { roots.reduce(0) { total, root in
        total + root.pending.count + root.directoriesInProgress.reduce(0) { $0 + 1 + ($1.pendingEntry == nil ? 0 : 1) }
    } }
    var snapshot: LibraryScan {
        let coverage = roots.map { state in
            SourceCoverage(root: state.root, count: state.manuals, directories: state.directories, files: state.files,
                           completed: state.pending.isEmpty && state.directoriesInProgress.isEmpty, issues: state.issues + state.pending.map {
                DiscoveryIssue(path: $0.path, kind: .pending, reason: "Queued for inspection; descendants have not yet been counted.")
            } + state.directoriesInProgress.flatMap { cursor in
                [DiscoveryIssue(path: cursor.directory.path, kind: .pending, reason: "Directory enumeration is unfinished; \(cursor.consumedEntries) entries committed. Remaining descendants have not been counted.")] + (cursor.pendingEntry.map {
                    [DiscoveryIssue(path: cursor.directory.appendingPathComponent($0).path, kind: .pending, reason: "Entry processing was interrupted and will be retried; it has not been counted.")]
                } ?? [])
            })
        } + (plan.exclusions + (plan.traversalExclusions ?? [])).map {
            SourceCoverage(root: URL(fileURLWithPath: $0.path), count: 0, directories: 0, files: 0, completed: false, issues: [$0])
        }
        return LibraryScan(pages: groupedManuals(pages), coverage: coverage, cancelled: pendingCount > 0)
    }
}

/// The continuous Darwin clock includes sleep; awake-time uptime would falsely imply a restart after waking.
func continuousDiscoveryBootReference() throws -> Date {
    var elapsed = timespec()
    guard clock_gettime(CLOCK_MONOTONIC_RAW, &elapsed) == 0 else {
        let failure = errno
        throw ManualToolError(message: "Cannot read the continuous clock for resumable discovery: \(String(cString: strerror(failure))) (errno \(failure)). The scan cannot establish a safe boot reference.")
    }
    guard elapsed.tv_sec >= 0, elapsed.tv_nsec >= 0, elapsed.tv_nsec < 1_000_000_000 else {
        throw ManualToolError(message: "The continuous clock returned an invalid interval for resumable discovery. The scan cannot establish a safe boot reference.")
    }
    return Date().addingTimeInterval(-(Double(elapsed.tv_sec) + Double(elapsed.tv_nsec) / 1_000_000_000))
}

func newDiscoveryCheckpoint(plan: DiscoveryPlan, title: String) throws -> DiscoveryCheckpoint {
    DiscoveryCheckpoint(version: 2, title: title, started: Date(), bootReference: try continuousDiscoveryBootReference(), bootReferenceClock: .continuous, plan: plan, updated: Date(), roots: plan.roots.map {
        DiscoveryRootState(root: $0, pending: [$0], directoriesInProgress: [], directories: 0, files: 0, manuals: 0, issues: [])
    }, visited: [:], visitedRootIndices: [:], pages: [], peakPending: plan.roots.count)
}

/// The request identity serializes checkpoint/inventory writes and rejects superseded workers.
actor DiscoveryCheckpointFile {
    private let url: URL
    private var request: UUID?

    init(url: URL) { self.url = url }

    func activate(_ request: UUID) { self.request = request }

    func save(_ checkpoint: DiscoveryCheckpoint, request: UUID) throws {
        guard self.request == request else { return }
        do {
            try autoreleasepool {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
            }
        } catch {
            throw ManualToolError(message: "Cannot save resumable discovery checkpoint \(url.path): \(error.localizedDescription) Check available storage and write access to the app's library folder. The last successfully saved checkpoint is retained.")
        }
    }

    /// Encoding large retained catalogs runs off MainActor and releases temporary bridged objects.
    func saveInventory(_ inventory: LibraryScan, request: UUID) throws {
        guard self.request == request else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent("discovery-v1.json")
        do {
            try autoreleasepool {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(inventory).write(to: destination, options: .atomic)
            }
        } catch {
            throw ManualToolError(message: "Cannot save retained discovery inventory \(destination.path): \(error.localizedDescription) Check available storage and write access to the app's library folder.")
        }
    }

    func remove(request: UUID) throws {
        guard self.request == request else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func load() throws -> DiscoveryCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let bytes = try Data(contentsOf: url)
            let header = try JSONDecoder().decode(DiscoveryCheckpointVersion.self, from: bytes)
            guard header.version == 2 else {
                throw ManualToolError(message: "Checkpoint version \(header.version) cannot resume with bounded directory traversal. Start a fresh scan when ready; this checkpoint and your existing inventory have not been changed.")
            }
            let saved = try JSONDecoder().decode(DiscoveryCheckpoint.self, from: bytes)
            let currentBootReference: Date
            switch saved.bootReferenceClock {
            case .continuous: currentBootReference = try continuousDiscoveryBootReference()
            case nil: currentBootReference = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
            }
            guard abs(saved.bootReference.timeIntervalSince(currentBootReference)) < 10 else {
                if saved.bootReferenceClock == nil {
                    throw ManualToolError(message: "This legacy checkpoint uses an awake-time boot estimate that no longer matches. Sleep, a restart, or a clock change can invalidate that estimate. Start a fresh scan; the saved checkpoint and your existing library are retained.")
                }
                throw ManualToolError(message: "The Mac restarted or its clock changed since this scan. Start a fresh scan; inode identities from an earlier boot cannot be reused safely.")
            }
            guard saved.version == 2, saved.roots.map(\.root) == saved.plan.roots,
                  saved.plan.roots.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
                  saved.plan.allowedNetworkRoots.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
                  saved.plan.exclusions.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") && !$0.reason.isEmpty && $0.kind != .pending && $0.directoryReference == nil }),
                  (saved.plan.traversalExclusions ?? []).allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") && !$0.reason.isEmpty && $0.kind == .excluded && $0.directoryReference == nil }),
                  saved.peakPending.map({ $0 >= saved.pendingCount }) ?? false,
                  saved.roots.allSatisfy({ state in
                      state.files >= state.manuals && state.directories >= state.directoriesInProgress.count && state.manuals >= 0 &&
                      state.pending.count <= 1 && state.pending.allSatisfy { $0 == state.root } &&
                      (state.pending.isEmpty || state.directoriesInProgress.isEmpty)
                  }) else { throw ManualToolError(message: "Checkpoint has invalid roots, counters, or version.") }
            try validateDiscoveryCursors(saved)
            try validateManualPages(saved.pages)
            return saved
        } catch {
            throw ManualToolError(message: "Cannot resume \(url.path): \(error.localizedDescription) Start a fresh scan to replace this checkpoint. Your existing library is retained.")
        }
    }
}

struct DiscoveryCheckpointVersion: Decodable {
    let version: Int
}

func validateDiscoveryCursors(_ checkpoint: DiscoveryCheckpoint) throws {
    guard checkpoint.roots.reduce(0, { $0 + $1.directoriesInProgress.count }) <= maximumDiscoveryDirectoryDepth else {
        throw ManualToolError(message: "Checkpoint exceeds the \(maximumDiscoveryDirectoryDepth)-directory active traversal limit.")
    }
    var manualsRemaining = checkpoint.pages.count
    var totalFiles: Int = 0
    var totalDirectories: Int = 0
    let emptyPrefix = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
    for root in checkpoint.roots {
        guard root.manuals <= manualsRemaining,
              !totalFiles.addingReportingOverflow(root.files).overflow,
              !totalDirectories.addingReportingOverflow(root.directories).overflow else {
            throw ManualToolError(message: "Checkpoint manual counts disagree with the inventory or inspected counters overflow.")
        }
        manualsRemaining -= root.manuals
        totalFiles += root.files
        totalDirectories += root.directories
        let processed = root.files.addingReportingOverflow(root.directories)
        let bound = processed.partialValue.addingReportingOverflow(root.issues.count)
        guard !processed.overflow, !bound.overflow else {
            throw ManualToolError(message: "Checkpoint processed-entry counts overflow at \(root.root.path).")
        }
        var cursorEntries: Int = 0
        var parent: URL? = nil
        for (index, cursor) in root.directoriesInProgress.enumerated() {
            guard cursor.directory.isFileURL, pathContains(root: root.root.path, path: cursor.directory.path),
                  parent.map({ cursor.directory.deletingLastPathComponent().path == $0.path }) ?? (cursor.directory.path == root.root.path),
                  cursor.consumedEntries >= 0, cursor.metadata.inode > 0,
                  (0..<1_000_000_000).contains(cursor.metadata.modifiedNanoseconds),
                  (0..<1_000_000_000).contains(cursor.metadata.changedNanoseconds),
                  cursor.prefixDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  cursor.consumedEntries != 0 || cursor.prefixDigest == emptyPrefix,
                  checkpoint.visited[cursor.metadata.identity] == cursor.directory.path,
                  cursor.pendingEntry.map({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) ?? true,
                  index == root.directoriesInProgress.count - 1 || cursor.pendingEntry == nil else {
                throw ManualToolError(message: "Checkpoint has an invalid directory cursor at \(cursor.directory.path).")
            }
            let sum = cursorEntries.addingReportingOverflow(cursor.consumedEntries)
            guard !sum.overflow, sum.partialValue <= bound.partialValue else {
                throw ManualToolError(message: "Checkpoint directory cursor skips more entries than its inspected counters at \(cursor.directory.path).")
            }
            cursorEntries = sum.partialValue
            parent = cursor.directory
        }
    }
    guard manualsRemaining == 0, checkpoint.visited.count == totalDirectories,
          checkpoint.visited.allSatisfy({ identity, path in
              let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
              return parts.count == 2 && Int32(parts[0]) != nil && UInt64(parts[1]).map({ $0 > 0 }) == true &&
                  checkpoint.plan.roots.contains { pathContains(root: $0.path, path: path) }
          }) else { throw ManualToolError(message: "Checkpoint manual counts or visited directory identities disagree with its inspected inventory.") }
    let owners = checkpoint.visitedRootIndices ?? [:]
    var ownedDirectories = [Int](repeating: 0, count: checkpoint.roots.count)
    for (identity, index) in owners {
        guard checkpoint.roots.indices.contains(index), let path = checkpoint.visited[identity],
              pathContains(root: checkpoint.roots[index].root.path, path: path) else {
            throw ManualToolError(message: "Checkpoint directory ownership does not identify a measured root.")
        }
        ownedDirectories[index] += 1
    }
    for index in checkpoint.roots.indices {
        guard ownedDirectories[index] <= checkpoint.roots[index].directories,
              owners.count != checkpoint.visited.count || ownedDirectories[index] == checkpoint.roots[index].directories else {
            throw ManualToolError(message: "Checkpoint directory ownership disagrees with inspected counts at \(checkpoint.roots[index].root.path).")
        }
        for issue in checkpoint.roots[index].issues {
            guard let reference = issue.directoryReference else { continue }
            let owner = owners[reference.identity].map { checkpoint.roots[$0].root }
            guard issue.kind == .excluded, pathContains(root: checkpoint.roots[index].root.path, path: issue.path),
                  !issue.path.contains("\0"), reference.directory.isFileURL,
                  checkpoint.visited[reference.identity] == reference.directory.path, reference.root == owner else {
                throw ManualToolError(message: "Checkpoint has an invalid directory reference at \(issue.path).")
            }
        }
    }
}
