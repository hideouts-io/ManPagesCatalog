import Foundation
import Darwin

enum HarnessError: LocalizedError {
    case invalid(String)
    case filesystem(String, Int32)
    case tool(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .filesystem(let path, let code): return "Filesystem operation failed at \(path): \(String(cString: strerror(code))) (errno \(code))."
        case .tool(let path, let status, let diagnostic): return "Compression tool \(path) exited \(status): \(diagnostic)"
        }
    }
}

struct GenerationOptions: Codable, Equatable {
    let seed: UInt64
    let files: Int
    let breadth: Int
    let filesPerDirectory: Int
    let batchSize: Int
    let maxFiles: Int
    let maxStorageBytes: UInt64
    let freeReserveBytes: UInt64
}

struct Ownership: Codable {
    let schema: Int
    let root: String
    let ownerToken: String
    let creatorUID: UInt32
    let created: Date
}

struct GenerationCheckpoint: Codable {
    let schema: Int
    let options: GenerationOptions
    let ordinaryFilesCreated: Int
    let fixturesComplete: Bool
    let initialFreeBytes: UInt64
    let updated: Date
}

struct ExpectedManual: Codable {
    let relativePath: String
    let name: String
    let section: String
    let language: String
    let contentSHA256: String
    let groupIdentity: String
    let kind: String
}

struct ExpectedIssue: Codable {
    let relativePath: String
    let kind: String
    let reason: String
}

struct FixtureManifest: Codable {
    let manuals: [ExpectedManual]
    let issues: [ExpectedIssue]
    let compressionTools: [String]
    let unavailableScenarios: [String]
    let inaccessibleVerified: Bool
    let inaccessibleErrno: Int32
}

struct TreeManifest: Codable {
    let schema: Int
    let ownership: Ownership
    let options: GenerationOptions
    let ordinaryFilesCreated: Int
    let emptyOrdinaryFiles: Int
    let payloadOrdinaryFiles: Int
    let payloadBytesPerNonemptyFile: Int
    let fixtures: FixtureManifest
    let generationComplete: Bool
    let filesystem: String
    let freeBytesAtStart: UInt64
    let freeBytesObserved: UInt64
    let wallClockUpdated: Date
    let interpretation: String
}

struct Verification: Codable {
    let schema: Int
    let root: String
    let ordinaryFilesInspected: Int
    let emptyOrdinaryFiles: Int
    let payloadOrdinaryFiles: Int
    let fixtureManualLocationsVerified: Int
    let uniqueExpectedGroups: Int
    let inaccessibleVerified: Bool
    let verified: Date
    let elapsedSeconds: Double
}

struct GenerationEvent: Codable {
    let event: String
    let ordinaryFilesCreated: Int
    let targetOrdinaryFiles: Int
    let elapsedSeconds: Double
    let freeBytes: UInt64
    let completed: Bool
}

struct VolumeState {
    let freeBytes: UInt64
    let filesystem: String
}

/// Validate persisted numeric values before any division, range construction, or file-count arithmetic.
func validatedGenerationOptions(_ options: GenerationOptions) throws -> GenerationOptions {
    guard options.files >= 0, options.files <= Int.max - 64,
          UInt64(options.files) <= UInt64.max / 4096,
          options.breadth > 0, options.filesPerDirectory > 0, options.batchSize > 0,
          options.breadth <= Int.max / options.filesPerDirectory,
          options.files <= options.breadth * options.filesPerDirectory,
          options.maxFiles >= options.files + 64, options.maxStorageBytes > 0 else {
        throw HarnessError.invalid("Generation options contain invalid limits: require nonnegative files, positive breadth/capacity/batch/storage, enough directory capacity, and maxFiles >= files + 64 for fixtures and controls.")
    }
    return options
}

func validatedGenerationCheckpoint(_ checkpoint: GenerationCheckpoint) throws -> GenerationCheckpoint {
    let options = try validatedGenerationOptions(checkpoint.options)
    guard checkpoint.schema == 1, checkpoint.ordinaryFilesCreated >= 0,
          checkpoint.ordinaryFilesCreated <= options.files,
          checkpoint.ordinaryFilesCreated == 0 || checkpoint.fixturesComplete else {
        throw HarnessError.invalid("Generation checkpoint has an invalid schema, ordinary-file count, or fixture completion state. Restore its original checkpoint or use a fresh harness root; no traversal or cleanup has started.")
    }
    return checkpoint
}
