import Foundation
import CryptoKit
import Darwin

enum ManualRichError: LocalizedError {
    case invalid(String)
    case filesystem(String, Int32)
    case database(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .filesystem(let path, let code): return "Manual-rich filesystem operation failed at \(path): \(String(cString: strerror(code))) (errno \(code))."
        case .database(let message): return "Manual-rich production index verification failed: \(message)"
        }
    }
}

struct ManualRichOptions: Codable, Equatable {
    let seed: UInt64
    let manuals: Int
    let largeEvery: Int
    let largeParagraphs: Int
    let batchSize: Int
    let maxFiles: Int
    let maxStorageBytes: UInt64
    let freeReserveBytes: UInt64
}

enum ManualRichSourceKind: String, Codable {
    case roff, mdoc, installed, copy, hardLink, symbolicLink, wholeAlias, localized, version
}

struct ManualRichSource: Codable, Equatable {
    let relativePath: String
    let name: String
    let section: String
    let language: String
    let sourceSHA256: String
    let contentSHA256: String
    let expectedID: String
    let byteCount: Int
    let formatterMarker: String
    let kind: ManualRichSourceKind
    let ordinal: Int?
    let target: String?
    let originalInstalledSource: String?
}

struct ManualRichOwnership: Codable {
    let schema: Int
    let root: String
    let ownerToken: String
    let creatorUID: UInt32
    let created: Date
}

struct ManualRichCheckpoint: Codable {
    let schema: Int
    let options: ManualRichOptions
    let sourceFilesCommitted: Int
    let initialFreeBytes: UInt64
    let updated: Date
}

struct ManualRichManifest: Codable {
    let schema: Int
    let ownership: ManualRichOwnership
    let options: ManualRichOptions
    let scanRoot: String
    let sources: [ManualRichSource]
    let expectedSourceLocations: Int
    let expectedUniqueManuals: Int
    let actualSourceFilesCommitted: Int
    let generationComplete: Bool
    let expectedSourceBytes: UInt64
    let filesystem: String
    let initialFreeBytes: UInt64
    let updated: Date
    let interpretation: String
}

struct ManualRichVerification: Codable {
    let schema: Int
    let root: String
    let actualFilesInspected: Int
    let expectedLocations: Int
    let expectedUniqueManuals: Int
    let verified: Date
    let elapsedSeconds: Double
}

func manualRichHash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

func manualRichState(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw ManualRichError.filesystem(url.path, errno) }
    return value
}

func manualRichVolume(_ root: URL) throws -> (UInt64, String) {
    var value = statfs()
    guard statfs(root.path, &value) == 0 else { throw ManualRichError.filesystem(root.path, errno) }
    guard value.f_flags & UInt32(MNT_LOCAL) != 0 else { throw ManualRichError.invalid("Manual-rich corpus requires an accessible local volume: \(root.path)") }
    let filesystem = try withUnsafeBytes(of: value.f_fstypename) { bytes -> String in
        guard let name = String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) else { throw ManualRichError.invalid("Invalid filesystem name at \(root.path)") }
        return name
    }
    guard value.f_bsize > 0 else { throw ManualRichError.invalid("Invalid filesystem block size at \(root.path)") }
    let available = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_bsize))
    guard !available.overflow else { throw ManualRichError.invalid("Filesystem available-byte counter overflow at \(root.path)") }
    return (available.partialValue, filesystem)
}

func manualRichRead<T: Decodable>(_ type: T.Type, _ path: URL) throws -> T {
    let state = try manualRichState(path)
    guard state.st_mode & S_IFMT == S_IFREG, state.st_size >= 0, state.st_size <= 128 * 1024 * 1024,
          state.st_flags & UInt32(SF_DATALESS) == 0 else { throw ManualRichError.invalid("Expected a materialized regular JSON file no larger than 128 MiB: \(path.path)") }
    return try JSONDecoder().decode(type, from: Data(contentsOf: path))
}

func manualRichWrite<T: Encodable>(_ value: T, _ path: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: path, options: .atomic)
}

func manualRichOptionsValidated(_ options: ManualRichOptions) throws -> ManualRichOptions {
    guard options.manuals >= 2, options.maxFiles <= 100_000, options.maxFiles >= 28,
          options.manuals <= options.maxFiles - 26, options.largeEvery > 1,
          options.largeParagraphs > 0, options.largeParagraphs <= 4096, options.batchSize > 0,
          options.batchSize <= 10_000, options.maxStorageBytes > 0 else {
        throw ManualRichError.invalid("Require at least 2 generated manuals, maxFiles <= 100000 and >= manuals+26, largeEvery >1, 1...4096 largeParagraphs, 1...10000 batchSize, and positive storage budget.")
    }
    return options
}

func manualRichOwnership(_ root: URL, _ token: String) throws -> ManualRichOwnership {
    guard try manualRichState(root).st_mode & S_IFMT == S_IFDIR else { throw ManualRichError.invalid("Owned corpus root must be a real directory, never an alias: \(root.path)") }
    let owner = try manualRichRead(ManualRichOwnership.self, root.appendingPathComponent(".manual-rich-owner-v1.json"))
    guard owner.schema == 1, owner.root == root.path, owner.creatorUID == getuid(), owner.ownerToken == token else {
        throw ManualRichError.invalid("Corpus ownership root/token/UID/schema does not match; nothing will be changed: \(root.path)")
    }
    return owner
}

/// Streaming filesystem adapter; invalid names, aliases and enumeration/close errors never disappear.
func manualRichEntries(_ directory: URL, _ body: (URL) throws -> Void) throws {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw ManualRichError.filesystem(directory.path, errno) }
    guard let stream = fdopendir(descriptor) else {
        let failure = errno
        guard close(descriptor) == 0 else { throw ManualRichError.filesystem(directory.path, errno) }
        throw ManualRichError.filesystem(directory.path, failure)
    }
    let outcome: Result<Void, Error> = Result {
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ManualRichError.filesystem(directory.path, errno) }
                break
            }
            try autoreleasepool {
                let name = try withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                    let count = Int(entry.pointee.d_namlen)
                    guard count > 0, count < bytes.count, bytes[count] == 0,
                          let name = String(bytes: bytes.prefix(count), encoding: .utf8), !name.contains("/"), !name.contains("\0") else {
                        throw ManualRichError.invalid("Invalid UTF-8 or malformed directory entry at \(directory.path)")
                    }
                    return name
                }
                if name != ".", name != ".." { try body(directory.appendingPathComponent(name)) }
            }
        }
    }
    if closedir(stream) != 0 {
        let failure = errno
        if case .failure(let error) = outcome { throw ManualRichError.invalid("Directory close failed (errno \(failure)) at \(directory.path); enumeration also failed: \(error.localizedDescription)") }
        throw ManualRichError.filesystem(directory.path, failure)
    }
    try outcome.get()
}
