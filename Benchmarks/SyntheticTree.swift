import Foundation
import CryptoKit
import Darwin

/// Signals request a checkpointed pause between bounded generation batches.
actor InterruptState {
    private var requested = false
    func request() { requested = true }
    func isRequested() -> Bool { requested }
}

func checkedState(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw HarnessError.filesystem(url.path, errno) }
    return value
}

func volumeState(_ root: URL) throws -> VolumeState {
    var value = statfs()
    guard statfs(root.path, &value) == 0 else { throw HarnessError.filesystem(root.path, errno) }
    guard value.f_flags & UInt32(MNT_LOCAL) != 0 else { throw HarnessError.invalid("Harness roots must be on a local volume: \(root.path)") }
    let name = withUnsafeBytes(of: value.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return VolumeState(freeBytes: UInt64(value.f_bavail) * UInt64(value.f_bsize), filesystem: name)
}

func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

func decoded<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: url))
}

func writeJSON<T: Encodable>(_ value: T, _ url: URL) throws {
    try encoded(value).write(to: url, options: .atomic)
}

func emit(_ value: GenerationEvent) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(value) + Data([10])
    try FileHandle.standardOutput.write(contentsOf: bytes)
}

func ownership(_ root: URL, _ token: String) throws -> Ownership {
    let metadata = try checkedState(root)
    guard metadata.st_mode & S_IFMT == S_IFDIR else { throw HarnessError.invalid("Harness root must be a real directory, never a symlink: \(root.path)") }
    let marker = try decoded(Ownership.self, root.appendingPathComponent(".manpages-stress-owner.json"))
    guard marker.schema == 1, marker.root == root.path, marker.ownerToken == token, marker.creatorUID == getuid() else {
        throw HarnessError.invalid("Ownership token, creator UID, schema, or original root does not match; no files will be changed at \(root.path).")
    }
    return marker
}

func prepareRoot(_ root: URL, _ token: String) throws -> Ownership {
    guard root.pathComponents.count >= 5, !token.isEmpty, token.count >= 16 else {
        throw HarnessError.invalid("Use a dedicated deeply located root and an explicit owner token of at least 16 characters.")
    }
    var state = stat()
    if lstat(root.path, &state) == 0 { return try ownership(root, token) }
    guard errno == ENOENT else { throw HarnessError.filesystem(root.path, errno) }
    let parent = root.deletingLastPathComponent()
    guard try checkedState(parent).st_mode & S_IFMT == S_IFDIR else { throw HarnessError.invalid("Create the local parent directory first: \(parent.path)") }
    _ = try volumeState(parent)
    guard mkdir(root.path, 0o700) == 0 else { throw HarnessError.filesystem(root.path, errno) }
    let marker = Ownership(schema: 1, root: root.path, ownerToken: token, creatorUID: getuid(), created: Date())
    try writeJSON(marker, root.appendingPathComponent(".manpages-stress-owner.json"))
    return marker
}

func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard try checkedState(url).st_mode & S_IFMT == S_IFDIR else { throw HarnessError.invalid("Expected a real harness directory at \(url.path).") }
}

func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

func ordinaryURL(_ root: URL, _ index: Int, _ options: GenerationOptions) -> URL {
    let folder = String(format: "b%06lld", Int64(index / options.filesPerDirectory))
    let name = String(format: "file-%016llx-%012lld.data", options.seed, Int64(index))
    return root.appendingPathComponent("ordinary").appendingPathComponent(folder).appendingPathComponent(name)
}

func ordinaryPayload(_ index: Int, _ seed: UInt64) -> Data {
    guard index % 10 == Int(seed % 10) else { return Data() }
    let text = "ordinary-data seed=\(seed) ordinal=\(index); documentation absent."
    let bytes = Array(text.utf8.prefix(64))
    return Data(bytes + [UInt8](repeating: 0x20, count: 64 - bytes.count))
}

func createOrdinary(_ url: URL, _ bytes: Data) throws -> Bool {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    if descriptor < 0 {
        guard errno == EEXIST else { throw HarnessError.filesystem(url.path, errno) }
        let state = try checkedState(url)
        guard state.st_mode & S_IFMT == S_IFREG, state.st_size == bytes.count, try Data(contentsOf: url) == bytes else {
            throw HarnessError.invalid("Existing ordinary file differs from the deterministic corpus: \(url.path)")
        }
        return false
    }
    let count = bytes.withUnsafeBytes { pointer in write(descriptor, pointer.baseAddress, bytes.count) }
    let failure = errno
    guard close(descriptor) == 0 else { throw HarnessError.filesystem(url.path, errno) }
    guard count == bytes.count else { throw HarnessError.filesystem(url.path, failure) }
    return true
}

func checkLimits(_ root: URL, _ options: GenerationOptions, _ initialFree: UInt64) throws -> VolumeState {
    let volume = try volumeState(root)
    guard volume.freeBytes >= options.freeReserveBytes else {
        throw HarnessError.invalid("Free space fell below the explicit reserve (\(volume.freeBytes) available, \(options.freeReserveBytes) reserved). Generation checkpoint is retained at \(root.path).")
    }
    let observedConsumption = initialFree > volume.freeBytes ? initialFree - volume.freeBytes : 0
    guard observedConsumption <= options.maxStorageBytes else {
        throw HarnessError.invalid("Observed volume free-space decrease \(observedConsumption) exceeds --max-storage-bytes \(options.maxStorageBytes). Other host activity can contribute; this conservative guard stops generation and preserves the checkpoint.")
    }
    return volume
}

func payloadCount(_ count: Int, _ seed: UInt64) -> Int {
    let residue = Int(seed % 10)
    return count > residue ? (count - residue + 9) / 10 : 0
}

func verifyOrdinary(_ url: URL, _ bytes: Data) throws {
    let state = try checkedState(url)
    guard state.st_mode & S_IFMT == S_IFREG, state.st_size == bytes.count, try Data(contentsOf: url) == bytes else {
        throw HarnessError.invalid("Checkpointed ordinary file type, size, or content differs at \(url.path).")
    }
}

/// Generation commits exact successful file operations after each explicit batch.
/// Resume verifies every checkpointed ordinary path individually; files created after the last checkpoint
/// are accepted only after their deterministic contents and regular-file type are verified.
func generate(_ root: URL, _ token: String, _ options: GenerationOptions, _ interrupts: InterruptState) async throws -> Bool {
    _ = try validatedGenerationOptions(options)
    let marker = try prepareRoot(root, token)
    let checkpointURL = root.appendingPathComponent("generation-checkpoint-v1.json")
    let start = DispatchTime.now().uptimeNanoseconds
    let currentFree = try volumeState(root).freeBytes
    let checkpoint: GenerationCheckpoint
    if FileManager.default.fileExists(atPath: checkpointURL.path) {
        let old = try validatedGenerationCheckpoint(decoded(GenerationCheckpoint.self, checkpointURL))
        guard old.options.seed == options.seed, old.options.filesPerDirectory == options.filesPerDirectory,
              old.options.files <= options.files, old.options.breadth <= options.breadth else {
            throw HarnessError.invalid("Resume requires the original seed and files-per-directory, at least the previous breadth, and a target no smaller than the previous requested target. Files created after a crash's last checkpoint must remain part of the corpus.")
        }
        checkpoint = old
    } else {
        checkpoint = GenerationCheckpoint(schema: 1, options: options, ordinaryFilesCreated: 0, fixturesComplete: false, initialFreeBytes: currentFree, updated: Date())
        try writeJSON(checkpoint, checkpointURL)
    }
    _ = try checkLimits(root, options, checkpoint.initialFreeBytes)
    let conservativeEstimate = UInt64(options.files) * 4096
    guard checkpoint.initialFreeBytes >= options.freeReserveBytes,
          conservativeEstimate <= checkpoint.initialFreeBytes - options.freeReserveBytes,
          conservativeEstimate <= options.maxStorageBytes else {
        throw HarnessError.invalid("The conservative 4096 bytes/path estimate exceeds the explicit storage budget or available free space after reserve. Reduce the target or use a dedicated larger local volume.")
    }
    let fixtureURL = root.appendingPathComponent("fixture-manifest-v1.json")
    let fixtures: FixtureManifest
    if checkpoint.fixturesComplete {
        fixtures = try decoded(FixtureManifest.self, fixtureURL)
    } else {
        fixtures = try createFixtures(root)
        try writeJSON(fixtures, fixtureURL)
    }
    try makeDirectory(root.appendingPathComponent("ordinary"))
    // Verify the committed prefix before extending it. Never replace an older complete
    // checkpoint with a smaller count merely because resume verification was interrupted.
    for index in 0..<checkpoint.ordinaryFilesCreated {
        try verifyOrdinary(ordinaryURL(root, index, options), ordinaryPayload(index, options.seed))
        if index % options.batchSize == 0, await interrupts.isRequested() { break }
    }
    var count = checkpoint.ordinaryFilesCreated
    var directoryIndex = -1
    var lastEmission: UInt64 = 0
    while count < options.files, !(await interrupts.isRequested()) {
        let batchEnd = count + min(options.batchSize, options.files - count)
        while count < batchEnd {
            let folder = count / options.filesPerDirectory
            let url = ordinaryURL(root, count, options)
            if folder != directoryIndex {
                try makeDirectory(url.deletingLastPathComponent())
                directoryIndex = folder
            }
            _ = try createOrdinary(url, ordinaryPayload(count, options.seed))
            count += 1
        }
        let state = GenerationCheckpoint(schema: 1, options: options, ordinaryFilesCreated: count, fixturesComplete: true,
                                         initialFreeBytes: checkpoint.initialFreeBytes, updated: Date())
        try writeJSON(state, checkpointURL)
        let volume = try checkLimits(root, options, checkpoint.initialFreeBytes)
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastEmission >= 1_000_000_000 {
            try emit(GenerationEvent(event: "generation-progress", ordinaryFilesCreated: count, targetOrdinaryFiles: options.files,
                                     elapsedSeconds: Double(now - start) / 1_000_000_000, freeBytes: volume.freeBytes, completed: false))
            lastEmission = now
        }
    }
    let complete = count == options.files
    let final = GenerationCheckpoint(schema: 1, options: options, ordinaryFilesCreated: count, fixturesComplete: true,
                                     initialFreeBytes: checkpoint.initialFreeBytes, updated: Date())
    try writeJSON(final, checkpointURL)
    let volume = try checkLimits(root, options, checkpoint.initialFreeBytes)
    let nonempty = payloadCount(count, options.seed)
    let manifest = TreeManifest(schema: 1, ownership: marker, options: options, ordinaryFilesCreated: count,
                                emptyOrdinaryFiles: count - nonempty, payloadOrdinaryFiles: nonempty, payloadBytesPerNonemptyFile: 64,
                                fixtures: fixtures, generationComplete: complete, filesystem: volume.filesystem,
                                freeBytesAtStart: checkpoint.initialFreeBytes, freeBytesObserved: volume.freeBytes, wallClockUpdated: Date(),
                                interpretation: "Generation counts are successful deterministic file operations, not production scanner inspection counts. Ordinary files are a metadata-heavy corpus: exactly one in ten has a 64-byte nonmanual payload; the remainder are empty. Free-space differences include other host activity. Only fixtures/ and ordinary/ are production scan roots; control JSON files are excluded. Generation/resume warms filesystem caches; no cold-cache claim is made.")
    try writeJSON(manifest, root.appendingPathComponent("manifest-v1.json"))
    try emit(GenerationEvent(event: complete ? "generation-complete" : "generation-paused", ordinaryFilesCreated: count,
                             targetOrdinaryFiles: options.files, elapsedSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000,
                             freeBytes: volume.freeBytes, completed: complete))
    return complete
}

func arguments(_ raw: [String]) throws -> (String, [String: String]) {
    guard let mode = raw.first, ["generate", "verify", "cleanup"].contains(mode), (raw.count - 1) % 2 == 0 else {
        throw HarnessError.invalid("Usage: synthetic-tree generate|verify|cleanup --root /dedicated/root --owner-token TOKEN [generate: --seed N --files N --breadth N --files-per-directory N --batch-size N --max-files N --max-storage-bytes N --free-reserve-bytes N].")
    }
    let allowed: Set<String> = mode == "generate" ? ["root", "owner-token", "seed", "files", "breadth", "files-per-directory", "batch-size", "max-files", "max-storage-bytes", "free-reserve-bytes"] : ["root", "owner-token"]
    var values: [String: String] = [:]
    for offset in stride(from: 1, to: raw.count, by: 2) {
        let key = String(raw[offset].dropFirst(2))
        guard raw[offset].hasPrefix("--"), allowed.contains(key), values[key] == nil else { throw HarnessError.invalid("Unknown or duplicate explicit argument: \(raw[offset])") }
        values[key] = raw[offset + 1]
    }
    guard Set(values.keys) == allowed else { throw HarnessError.invalid("Every \(mode) argument is required explicitly: \(allowed.sorted().joined(separator: ", ")).") }
    return (mode, values)
}

func integer<T: FixedWidthInteger>(_ values: [String: String], _ key: String, _ type: T.Type) throws -> T {
    guard let raw = values[key], let result = T(raw) else { throw HarnessError.invalid("--\(key) must be a valid \(type).") }
    return result
}

@main
enum SyntheticTree {
    static func main() async {
        do {
            let parsed = try arguments(Array(CommandLine.arguments.dropFirst()))
            guard let rawRoot = parsed.1["root"], rawRoot.hasPrefix("/"), let token = parsed.1["owner-token"] else { throw HarnessError.invalid("Root must be absolute and the owner token explicit.") }
            let root = URL(fileURLWithPath: rawRoot).standardizedFileURL
            switch parsed.0 {
            case "generate":
                let options = GenerationOptions(seed: try integer(parsed.1, "seed", UInt64.self), files: try integer(parsed.1, "files", Int.self),
                                                breadth: try integer(parsed.1, "breadth", Int.self), filesPerDirectory: try integer(parsed.1, "files-per-directory", Int.self),
                                                batchSize: try integer(parsed.1, "batch-size", Int.self), maxFiles: try integer(parsed.1, "max-files", Int.self),
                                                maxStorageBytes: try integer(parsed.1, "max-storage-bytes", UInt64.self), freeReserveBytes: try integer(parsed.1, "free-reserve-bytes", UInt64.self))
                let interrupts = InterruptState()
                signal(SIGINT, SIG_IGN)
                signal(SIGTERM, SIG_IGN)
                let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                    source.setEventHandler { Task { await interrupts.request() } }
                    source.resume()
                    return source
                }
                let complete = try await generate(root, token, options, interrupts)
                for source in sources { source.cancel() }
                if !complete { exit(2) }
            case "verify": try verify(root, token)
            case "cleanup": try cleanup(root, token)
            default: throw HarnessError.invalid("Unknown explicit mode.")
            }
        } catch {
            do { try FileHandle.standardError.write(contentsOf: Data("\(error.localizedDescription)\n".utf8)) }
            catch { fputs("Cannot write harness error diagnostic to stderr.\n", stderr) }
            exit(1)
        }
    }
}
