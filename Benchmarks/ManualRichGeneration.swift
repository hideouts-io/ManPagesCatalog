import Foundation
import Darwin

actor ManualRichInterrupt {
    private var requested = false
    func request() { requested = true }
    func isRequested() -> Bool { requested }
}

/// Both source format and body size vary deterministically; all generated pages have a unique marker.
/// catalogindex is a common full-text probe. catalogbench-000001 is the first command-name probe.
func manualRichSynthetic(_ ordinal: Int, _ options: ManualRichOptions) -> (String, String, String, Data) {
    let name = String(format: "catalogbench-%06lld", Int64(ordinal + 1))
    let section = ["1", "3", "8"][ordinal % 3]
    let marker = String(format: "catalogmarker%016llx%06lld", options.seed, Int64(ordinal + 1))
    let mdoc = ordinal % 2 != 0
    var text = mdoc ? ".Dd October 4, 2026\n.Dt \(name.uppercased()) \(section)\n.Os\n.Sh NAME\n.Nm \(name)\n.Nd deterministic catalog indexing reference \(ordinal + 1)\n.Sh SYNOPSIS\n.Nm\n.Sh DESCRIPTION\n" : ".TH \(name.uppercased()) \(section) \"October 4, 2026\" \"ManualRichCorpus\"\n.SH NAME\n\(name) \\- deterministic catalog indexing reference \(ordinal + 1)\n.SH SYNOPSIS\n.B \(name)\n.SH DESCRIPTION\n"
    text += "This catalogindex manual has the unique lookup marker \(marker). It documents an isolated synthetic command without executing anything.\n"
    if ordinal % options.largeEvery == 0 {
        for paragraph in 0..<options.largeParagraphs {
            text += mdoc ? ".Pp\n" : ".PP\n"
            text += "Reference paragraph \(paragraph + 1) for \(name) explains catalogindex discovery, search, reading, diagnostics, and durable indexing. Its deterministic seed is \(options.seed).\n"
        }
    }
    return (name, section, marker, Data(text.utf8))
}

func manualRichRegularBytes(_ path: URL) throws -> Data {
    let state = try manualRichState(path)
    guard state.st_mode & S_IFMT == S_IFREG, state.st_flags & UInt32(SF_DATALESS) == 0,
          state.st_size >= 0, state.st_size <= 8 * 1024 * 1024 else {
        throw ManualRichError.invalid("Corpus source must be a materialized regular file no larger than 8 MiB: \(path.path)")
    }
    return try Data(contentsOf: path)
}

func manualRichExpected(_ path: String, _ name: String, _ section: String, _ language: String,
                        _ source: Data, _ content: Data, _ marker: String, _ kind: ManualRichSourceKind,
                        _ ordinal: Int?, _ target: String?, _ original: String?) -> ManualRichSource {
    let hash = manualRichHash(content)
    return ManualRichSource(relativePath: path, name: name, section: section, language: language,
                            sourceSHA256: manualRichHash(source), contentSHA256: hash, expectedID: "\(hash):\(section):\(language)",
                            byteCount: source.count, formatterMarker: marker, kind: kind, ordinal: ordinal,
                            target: target, originalInstalledSource: original)
}

/// Owned installed copies freeze the measured version across interrupted generation/resume.
func manualRichInstalledBytes(_ root: URL, _ relative: String, _ installed: String) throws -> Data {
    var parent = root
    let components = [""] + relative.split(separator: "/").dropLast().map(String.init)
    for component in components {
        if !component.isEmpty { parent.appendPathComponent(component) }
        var state = stat()
        if lstat(parent.path, &state) != 0 {
            guard errno == ENOENT else { throw ManualRichError.filesystem(parent.path, errno) }
            return try manualRichRegularBytes(URL(fileURLWithPath: installed))
        }
        guard state.st_mode & S_IFMT == S_IFDIR, state.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw ManualRichError.invalid("Installed-copy parent is an alias, placeholder or non-directory: \(parent.path)")
        }
        _ = try manualRichVolume(parent)
    }
    let owned = root.appendingPathComponent(relative)
    var value = stat()
    if lstat(owned.path, &value) == 0 {
        try manualRichParents(root, relative)
        return try manualRichRegularBytes(owned)
    }
    guard errno == ENOENT else { throw ManualRichError.filesystem(owned.path, errno) }
    return try manualRichRegularBytes(URL(fileURLWithPath: installed))
}

func manualRichSources(_ root: URL, _ options: ManualRichOptions) throws -> [ManualRichSource] {
    var sources: [ManualRichSource] = []
    sources.reserveCapacity(options.manuals + 10)
    for ordinal in 0..<options.manuals {
        let source = autoreleasepool { () -> ManualRichSource in
            let (name, section, marker, bytes) = manualRichSynthetic(ordinal, options)
            return manualRichExpected("manuals/generated/man\(section)/\(name).\(section)", name, section, "unspecified", bytes, bytes,
                                      marker, ordinal % 2 == 0 ? .roff : .mdoc, ordinal, nil, nil)
        }
        sources.append(source)
    }
    let installed: [(String, String, String, String)] = [
        ("launchctl", "1", "/usr/share/man/man1/launchctl.1", "bootstrap"),
        ("ping", "8", "/usr/share/man/man8/ping.8", "packets"),
        ("ifconfig", "8", "/usr/share/man/man8/ifconfig.8", "interface")
    ]
    for (name, section, original, marker) in installed {
        let relative = "manuals/installed/man\(section)/\(name).\(section)"
        let bytes = try manualRichInstalledBytes(root, relative, original)
        sources.append(manualRichExpected(relative, name, section, "unspecified", bytes, bytes, marker, .installed, nil, nil, original))
    }
    let target = "manuals/installed/man1/launchctl.1"
    let launchctl = try manualRichInstalledBytes(root, target, "/usr/share/man/man1/launchctl.1")
    for (kind, name, path) in [(ManualRichSourceKind.copy, "duplicate", "manuals/duplicates/man1/duplicate.1"),
                               (.hardLink, "hard-link", "manuals/aliases/man1/hard-link.1"),
                               (.symbolicLink, "file-link", "manuals/aliases/man1/file-link.1")] {
        sources.append(manualRichExpected(path, name, "1", "unspecified", launchctl, launchctl, "bootstrap", kind, nil, target, nil))
    }
    let alias = Data(".so ../../installed/man1/launchctl.1\n".utf8)
    sources.append(manualRichExpected("manuals/aliases/man1/whole-alias.1", "whole-alias", "1", "unspecified", alias, launchctl,
                                      "bootstrap", .wholeAlias, nil, target, nil))
    for language in ["fr", "ja_JP"] {
        sources.append(manualRichExpected("manuals/localized/\(language)/man1/launchctl.1", "launchctl", "1", language,
                                          launchctl, launchctl, "bootstrap", .localized, nil, target, nil))
    }
    let marker = String(format: "catalogversion%016llx", options.seed)
    let version = launchctl + Data("\n.Sh SYNTHETIC VERSION\nThis distinct package revision has marker \(marker).\n".utf8)
    sources.append(manualRichExpected("manuals/versions/v2/man1/launchctl.1", "launchctl", "1", "unspecified", version, version,
                                      marker, .version, nil, target, nil))
    return sources
}

func manualRichSourceBytes(_ source: ManualRichSource, _ options: ManualRichOptions, _ root: URL) throws -> Data {
    if let ordinal = source.ordinal { return manualRichSynthetic(ordinal, options).3 }
    if let original = source.originalInstalledSource { return try manualRichInstalledBytes(root, source.relativePath, original) }
    guard let target = source.target else { throw ManualRichError.invalid("Missing source target for \(source.relativePath)") }
    let bytes = try manualRichRegularBytes(root.appendingPathComponent(target))
    switch source.kind {
    case .wholeAlias: return Data(".so ../../installed/man1/launchctl.1\n".utf8)
    case .version: return bytes + Data("\n.Sh SYNTHETIC VERSION\nThis distinct package revision has marker \(source.formatterMarker).\n".utf8)
    case .copy, .hardLink, .symbolicLink, .localized: return bytes
    default: throw ManualRichError.invalid("Unexpected source kind at \(source.relativePath)")
    }
}

func manualRichMakeParents(_ root: URL, _ relative: String) throws {
    var current = root
    for component in relative.split(separator: "/").dropLast() {
        current.appendPathComponent(String(component))
        var value = stat()
        if lstat(current.path, &value) == 0 {
            guard value.st_mode & S_IFMT == S_IFDIR else { throw ManualRichError.invalid("Corpus parent became an alias or non-directory: \(current.path)") }
        } else {
            guard errno == ENOENT, mkdir(current.path, 0o700) == 0 else { throw ManualRichError.filesystem(current.path, errno) }
        }
    }
}

func manualRichCreateSource(_ source: ManualRichSource, _ options: ManualRichOptions, _ root: URL) throws {
    try manualRichMakeParents(root, source.relativePath)
    let path = root.appendingPathComponent(source.relativePath)
    var value = stat()
    if lstat(path.path, &value) == 0 { try manualRichVerifySource(source, root); return }
    guard errno == ENOENT else { throw ManualRichError.filesystem(path.path, errno) }
    if source.kind == .symbolicLink {
        guard symlink("../../installed/man1/launchctl.1", path.path) == 0 else { throw ManualRichError.filesystem(path.path, errno) }
    } else if source.kind == .hardLink {
        guard let target = source.target, link(root.appendingPathComponent(target).path, path.path) == 0 else { throw ManualRichError.filesystem(path.path, errno) }
    } else {
        let bytes = try manualRichSourceBytes(source, options, root)
        guard bytes.count == source.byteCount, manualRichHash(bytes) == source.sourceSHA256 else {
            throw ManualRichError.invalid("Source changed after its manifest was planned: \(path.path). Retain this root and use a fresh corpus for the new installed version.")
        }
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManualRichError.filesystem(path.path, errno) }
        let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, bytes.count) }
        let failure = errno
        guard close(descriptor) == 0 else { throw ManualRichError.filesystem(path.path, errno) }
        guard count == bytes.count else { throw ManualRichError.invalid("Incomplete source write at \(path.path): wrote \(count) of \(bytes.count) bytes (errno \(failure)). The last committed checkpoint is retained; this partial file needs explicit inspection before resume.") }
    }
    try manualRichVerifySource(source, root)
}

func manualRichLimits(_ root: URL, _ options: ManualRichOptions, _ initial: UInt64) throws -> UInt64 {
    let free = try manualRichVolume(root).0
    let consumption = initial > free ? initial - free : 0
    guard free >= options.freeReserveBytes, consumption <= options.maxStorageBytes else {
        throw ManualRichError.invalid("Corpus resource guard stopped generation: available=\(free), reserve=\(options.freeReserveBytes), observed volume decrease=\(consumption), budget=\(options.maxStorageBytes). Other host activity contributes; the checkpoint is retained.")
    }
    return free
}

/// Generation is resumed from verified committed files; graceful signals pause only between bounded batches.
func manualRichGenerate(_ root: URL, _ token: String, _ options: ManualRichOptions, _ interrupt: ManualRichInterrupt) async throws -> Bool {
    _ = try manualRichOptionsValidated(options)
    guard root.pathComponents.count >= 5, token.count >= 16 else { throw ManualRichError.invalid("Use a dedicated absolute root and an owner token of at least 16 characters.") }
    let parent = root.deletingLastPathComponent()
    guard try manualRichState(parent).st_mode & S_IFMT == S_IFDIR else { throw ManualRichError.invalid("Create the real local parent directory first: \(parent.path)") }
    var existing = stat()
    if lstat(root.path, &existing) == 0 { _ = try manualRichOwnership(root, token) }
    else if errno != ENOENT { throw ManualRichError.filesystem(root.path, errno) }
    let available = try manualRichVolume(parent)
    let sources = try manualRichSources(root, options)
    let payload = sources.reduce(UInt64(0)) { $0 + UInt64($1.byteCount) }
    let estimate = UInt64(sources.count + 16) * 4096 + payload
    guard available.0 >= options.freeReserveBytes, estimate <= available.0 - options.freeReserveBytes,
          estimate <= options.maxStorageBytes else { throw ManualRichError.invalid("Corpus estimate \(estimate) exceeds storage budget/free space after reserve; no generation started. available=\(available.0), reserve=\(options.freeReserveBytes), budget=\(options.maxStorageBytes).") }
    var state = stat()
    let owner: ManualRichOwnership
    if lstat(root.path, &state) == 0 { owner = try manualRichOwnership(root, token) }
    else {
        guard errno == ENOENT, mkdir(root.path, 0o700) == 0 else { throw ManualRichError.filesystem(root.path, errno) }
        owner = ManualRichOwnership(schema: 1, root: root.path, ownerToken: token, creatorUID: getuid(), created: Date())
        try manualRichWrite(owner, root.appendingPathComponent(".manual-rich-owner-v1.json"))
    }
    let checkpointURL = root.appendingPathComponent("generation-checkpoint-v1.json")
    let manifestURL = root.appendingPathComponent("manifest-v1.json")
    let initial: UInt64
    var committed = 0
    if FileManager.default.fileExists(atPath: checkpointURL.path) {
        let saved = try manualRichRead(ManualRichCheckpoint.self, checkpointURL)
        guard saved.schema == 1, saved.options == options, saved.sourceFilesCommitted >= 0, saved.sourceFilesCommitted <= sources.count else {
            throw ManualRichError.invalid("Resume requires original generation options and valid committed source counters; this corpus was not changed.")
        }
        let old = try manualRichRead(ManualRichManifest.self, manifestURL)
        guard old.sources == sources, old.ownership.root == root.path, old.options == options else { throw ManualRichError.invalid("Existing manifest differs from the deterministic source plan; this corpus was not changed.") }
        initial = saved.initialFreeBytes
        committed = saved.sourceFilesCommitted
        for index in 0..<committed { try autoreleasepool { try manualRichVerifySource(sources[index], root) } }
    } else { initial = available.0 }
    func manifest(_ count: Int) -> ManualRichManifest {
        ManualRichManifest(schema: 1, ownership: owner, options: options, scanRoot: root.appendingPathComponent("manuals").path,
            sources: sources, expectedSourceLocations: sources.count, expectedUniqueManuals: Set(sources.map(\.expectedID)).count,
            actualSourceFilesCommitted: count, generationComplete: count == sources.count, expectedSourceBytes: payload,
            filesystem: available.1, initialFreeBytes: initial, updated: Date(),
            interpretation: "Committed generation operations are not production inspection/indexing counts. Scan only manuals/. Installed copies freeze source versions. Explicit verify warms sources; caches are never flushed. Storage guards measure conservative volume free-space deltas including other host activity. SIGINT/SIGTERM pause between batches; abrupt partial writes fail explicitly and are retained for inspection.")
    }
    try manualRichWrite(manifest(committed), manifestURL)
    _ = try manualRichLimits(root, options, initial)
    try manualRichWrite(ManualRichCheckpoint(schema: 1, options: options, sourceFilesCommitted: committed, initialFreeBytes: initial, updated: Date()), checkpointURL)
    while committed < sources.count, !(await interrupt.isRequested()) {
        let end = committed + min(options.batchSize, sources.count - committed)
        while committed < end {
            try autoreleasepool { try manualRichCreateSource(sources[committed], options, root) }
            committed += 1
        }
        try manualRichWrite(ManualRichCheckpoint(schema: 1, options: options, sourceFilesCommitted: committed, initialFreeBytes: initial, updated: Date()), checkpointURL)
        let free = try manualRichLimits(root, options, initial)
        print("event=generation-batch sourceFilesCommitted=\(committed) expectedSourceLocations=\(sources.count) freeBytes=\(free)")
    }
    try manualRichWrite(manifest(committed), manifestURL)
    print("event=\(committed == sources.count ? "generation-complete" : "generation-paused") sourceFilesCommitted=\(committed) expectedUniqueManuals=\(Set(sources.map(\.expectedID)).count) root=\(root.path)")
    return committed == sources.count
}
