import Foundation
import Darwin
import CryptoKit

struct StorageRecoveryOwnership: Codable {
    let owner: String
    let token: String
    let volume: String
}

struct StorageRecoveryResult: Codable {
    let operation: String
    let processID: Int32
    let startedUptime: Double
    let finishedUptime: Double
    let manuals: Int
    let indexed: Int
    let inventorySHA256: String?
    let error: String?
}

/// Runs actual app persistence on a separately mounted, capacity-limited harness volume.
/// The controller owns volume creation, pressure and exact-PID interruption; this worker never fills storage.
@main
struct StorageRecovery {
    static func main() async {
        let began = ProcessInfo.processInfo.systemUptime
        var operation = "invalid"
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let usage = "Usage: storage-recovery prepare|inspect|resume|resume-large|inventory-write|checkpoint-write|index-write|export-write /owned/volume TOKEN LIBRARY-NAME; prepare-large additionally requires /reference/library."
            guard [4, 5].contains(arguments.count) else { throw ManualToolError(message: usage) }
            operation = arguments[0]
            guard arguments.count == (operation == "prepare-large" ? 5 : 4) else { throw ManualToolError(message: usage) }
            let volume = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let ownership = try JSONDecoder().decode(StorageRecoveryOwnership.self, from: Data(contentsOf: volume.appendingPathComponent(".manpages-storage-owner.json")))
            guard ownership.owner == "ManPagesCatalog StorageRecovery", ownership.token == arguments[2], ownership.volume == volume.path,
                  arguments[3].range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
                throw ManualToolError(message: "Storage recovery refuses an unowned volume or invalid library name: \(volume.path).")
            }
            var filesystem = statfs()
            guard statfs(volume.path, &filesystem) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let mount = withUnsafeBytes(of: filesystem.f_mntonname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            let capacity = UInt64(filesystem.f_blocks) * UInt64(filesystem.f_bsize)
            guard mount == volume.path, capacity <= 1_024 * 1_024 * 1_024,
                  volume.path.hasPrefix("/Volumes/"), !volume.path.contains("/../") else {
                throw ManualToolError(message: "Storage recovery requires its isolated /Volumes mount: \(volume.path).")
            }
            let library = volume.appendingPathComponent(arguments[3])
            switch operation {
            case "prepare": try await prepare(library: library, volume: volume)
            case "prepare-large":
                guard arguments[4].hasPrefix("/") else { throw ManualToolError(message: usage) }
                try await prepareLarge(library: library, reference: URL(fileURLWithPath: arguments[4]))
            case "inspect":
                let reopened = try ManualSearchIndex(url: library.appendingPathComponent("search.sqlite"))
                _ = try await reopened.metadata()
            case "resume": try await resume(library: library)
            case "resume-large": try await resumeLarge(library: library)
            case "inventory-write": try await writeInventory(library: library)
            case "checkpoint-write": try await writeCheckpoint(library: library)
            case "index-write": try await writeIndex(library: library)
            case "export-write": try await writeExport(library: library, volume: volume)
            default: throw ManualToolError(message: "Unknown storage recovery operation: \(operation).")
            }
            let retained = try loadDiscovery(library.appendingPathComponent("discovery-v1.json"))
            try emit(StorageRecoveryResult(operation: operation, processID: getpid(), startedUptime: began,
                finishedUptime: ProcessInfo.processInfo.systemUptime, manuals: retained.pages.count,
                indexed: retained.pages.filter(\.indexed).count,
                inventorySHA256: try hashFile(library.appendingPathComponent("discovery-v1.json")), error: nil))
        } catch {
            do {
                try emit(StorageRecoveryResult(operation: operation, processID: getpid(), startedUptime: began,
                    finishedUptime: ProcessInfo.processInfo.systemUptime, manuals: 0, indexed: 0, inventorySHA256: nil,
                    error: error.localizedDescription))
            } catch { FileHandle.standardError.write(Data("Cannot encode storage-recovery result: \(error.localizedDescription)\n".utf8)) }
            exit(1)
        }
    }

    /// Only dated benchmark evidence is read; user catalogs and source manuals are never rewritten.
    static func prepareLarge(library: URL, reference: URL) async throws {
        guard !FileManager.default.fileExists(atPath: library.path) else { throw ManualToolError(message: "Large preparation requires a new harness library: \(library.path).") }
        let retained = try loadDiscovery(reference.appendingPathComponent("discovery-v1.json"))
        guard retained.pages.count == 10_006, retained.pages.flatMap(\.locations).count == 10_010 else {
            throw ManualToolError(message: "Expected the validated 10,006-group / 10,010-location reference catalog at \(reference.path).")
        }
        let pending = retained.pages.map { page in
            var updated = page
            updated.description = ""
            updated.indexed = false
            updated.problem = nil
            return updated
        }
        let checkpoint = DiscoveryCheckpointFile(url: library.appendingPathComponent("scan-checkpoint-v1.json"))
        let request = UUID()
        await checkpoint.activate(request)
        try await checkpoint.saveInventory(LibraryScan(pages: pending, coverage: retained.coverage, cancelled: false), request: request)
        let initialized = try ManualSearchIndex(url: library.appendingPathComponent("search.sqlite"))
        guard try await initialized.metadata().isEmpty else { throw ManualToolError(message: "New large recovery index is not empty.") }
    }

    @MainActor
    static func resumeLarge(library: URL) async throws {
        let suite = "ManPagesCatalog.StorageRecovery.Large.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ManualToolError(message: "Cannot create isolated large-recovery preferences.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(directory: library, defaults: defaults)
        store.continueIndexing()
        let deadline = ProcessInfo.processInfo.systemUptime + 300
        while store.isIndexing {
            guard ProcessInfo.processInfo.systemUptime < deadline else { store.stop(); throw ManualToolError(message: "Large recovery exceeded the 300-second harness limit.") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if let error = store.errorMessage { throw ManualToolError(message: error) }
        guard store.pages.count == 10_006, store.indexedCount == 10_006 else {
            throw ManualToolError(message: "Large recovery retained \(store.pages.count) groups / \(store.indexedCount) indexed; expected 10,006.")
        }
        let index = try ManualSearchIndex(url: library.appendingPathComponent("search.sqlite"))
        guard try await index.metadata().count == 10_006 else { throw ManualToolError(message: "Large recovery contains missing or duplicate index rows.") }
    }

    static func prepare(library: URL, volume: URL) async throws {
        guard !FileManager.default.fileExists(atPath: library.path) else { throw ManualToolError(message: "Preparation requires a new harness library: \(library.path).") }
        let root = volume.appendingPathComponent("fixtures/man1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installed = try Data(contentsOf: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"))
        for ordinal in 0..<132 {
            let target = root.appendingPathComponent(String(format: "storage-%03d.1", ordinal))
            guard !FileManager.default.fileExists(atPath: target.path) else { throw ManualToolError(message: "Preparation will not overwrite fixture \(target.path).") }
            try (installed + Data("\n.Sh STORAGE RECOVERY\nstoragerecovery\(ordinal) identifies this installed-source revision.\n".utf8)).write(to: target)
        }
        let scan = try await scanLibrary(roots: [root])
        guard scan.pages.count == 132 else { throw ManualToolError(message: "Expected 132 distinct installed-source revisions; discovered \(scan.pages.count).") }
        let file = DiscoveryCheckpointFile(url: library.appendingPathComponent("scan-checkpoint-v1.json"))
        let request = UUID()
        await file.activate(request)
        try await file.save(newDiscoveryCheckpoint(plan: DiscoveryPlan(roots: [root], allowedNetworkRoots: [], exclusions: []), title: "Storage recovery fixtures"), request: request)
        let index = try ManualSearchIndex(url: library.appendingPathComponent("search.sqlite"))
        var pages = scan.pages
        for ordinal in 0..<64 {
            let input = try await manualInput(source: pages[ordinal].source)
            let formatted = try await formattedManualText(input: input)
            let description = descriptionFromFormattedManual(formatted.text)
            try await index.store(page: pages[ordinal], text: formatted.text, description: description, diagnostic: formatted.diagnostic)
            pages[ordinal].description = description
            pages[ordinal].indexed = true
            pages[ordinal].problem = formatted.diagnostic.isEmpty ? nil : formatted.diagnostic
        }
        try await file.saveInventory(LibraryScan(pages: pages, coverage: scan.coverage, cancelled: false), request: request)
        let recorder = ScanPerformanceRecorder(scanID: request, mode: "Storage recovery preparation", roots: [root], initialDirectories: 0, initialFiles: 0, initialManualLocations: 0)
        await recorder.recordDiscovery(directories: scan.coverage.reduce(0) { $0 + $1.directories }, files: scan.coverage.reduce(0) { $0 + $1.files }, manualLocations: 132, pending: 0, path: root.path)
        await recorder.finishDiscovery()
        await recorder.beginIndexing(total: 64)
        await recorder.recordIndexing(completed: 64, queued: 0, active: 0, succeeded: 64, failed: 0)
        await recorder.finishIndexing()
        await recorder.finish(state: .completed, durability: "132 actual manuals discovered; initial 64 records committed for recovery tests")
        try JSONEncoder().encode(await recorder.snapshot()).write(to: library.appendingPathComponent("scan-performance-v1.json"), options: .atomic)
    }

    @MainActor
    static func resume(library: URL) async throws {
        let suite = "ManPagesCatalog.StorageRecovery.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ManualToolError(message: "Cannot create isolated recovery preferences.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(directory: library, defaults: defaults)
        store.continueIndexing()
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while store.isIndexing {
            guard ProcessInfo.processInfo.systemUptime < deadline else { store.stop(); throw ManualToolError(message: "Recovery exceeded the 180-second harness limit.") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if let error = store.errorMessage { throw ManualToolError(message: error) }
        guard store.indexedCount == 132 else { throw ManualToolError(message: "Recovery retained \(store.indexedCount) indexed groups; expected 132.") }
        let index = try ManualSearchIndex(url: library.appendingPathComponent("search.sqlite"))
        guard try await index.metadata().count == 132 else { throw ManualToolError(message: "Recovered index contains duplicate or missing records.") }
        for ordinal in 0..<132 {
            guard try await index.matchingIDs(query: "storagerecovery\(ordinal)").count == 1 else { throw ManualToolError(message: "Recovered record marker storagerecovery\(ordinal) is missing or duplicated.") }
        }
    }

    static func writeInventory(library: URL) async throws {
        let old = try loadDiscovery(library.appendingPathComponent("discovery-v1.json"))
        var pages = old.pages
        pages[0].description = String(repeating: "bounded atomic inventory write observation ", count: 1_500_000)
        let file = DiscoveryCheckpointFile(url: library.appendingPathComponent("scan-checkpoint-v1.json"))
        let request = UUID()
        await file.activate(request)
        try await file.saveInventory(LibraryScan(pages: pages, coverage: old.coverage, cancelled: old.cancelled), request: request)
    }

    static func writeCheckpoint(library: URL) async throws {
        let file = DiscoveryCheckpointFile(url: library.appendingPathComponent("scan-checkpoint-v1.json"))
        guard var saved = try await file.load() else { throw ManualToolError(message: "Recovery requires an existing checkpoint.") }
        saved.roots[0].issues.append(DiscoveryIssue(path: saved.roots[0].root.path, kind: .unsupported,
            reason: String(repeating: "bounded atomic checkpoint write observation ", count: 1_500_000)))
        saved.updated = Date()
        let request = UUID()
        await file.activate(request)
        try await file.save(saved, request: request)
    }

    static func writeIndex(library: URL) async throws {
        let scan = try loadDiscovery(library.appendingPathComponent("discovery-v1.json"))
        let page = scan.pages[0]
        let index = try ManualSearchIndex(url: library.appendingPathComponent("search.sqlite"))
        try await index.store(records: [ManualIndexRecord(id: page.id, fingerprint: page.fingerprint,
            body: String(repeating: "boundeduncommittedsqlitewrite ", count: 1_500_000), description: "Controlled interrupted SQLite replacement", diagnostic: "")])
    }

    @MainActor
    static func writeExport(library: URL, volume: URL) async throws {
        let suite = "ManPagesCatalog.StorageRecovery.Export.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ManualToolError(message: "Cannot create isolated export preferences.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(directory: library, defaults: defaults)
        store.openLibrary()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while store.pages.isEmpty || store.performanceReport == nil {
            if let error = store.errorMessage { throw ManualToolError(message: error) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ManualToolError(message: "Export preparation did not load the retained test library.") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try store.exportCoverage(to: volume.appendingPathComponent("exports/coverage.json"))
    }

    static func hashFile(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func emit(_ result: StorageRecoveryResult) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
    }
}
