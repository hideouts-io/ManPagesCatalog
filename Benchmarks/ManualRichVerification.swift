import Foundation
import Darwin
import SQLite3

/// Reject parent aliases before any owned source read or mutation.
func manualRichParents(_ root: URL, _ relative: String) throws {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !relative.hasPrefix("/"), parts.count >= 2,
          parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw ManualRichError.invalid("Invalid owned relative source path: \(relative)")
    }
    var current = root
    for part in parts.dropLast() {
        current.appendPathComponent(String(part))
        let state = try manualRichState(current)
        guard state.st_mode & S_IFMT == S_IFDIR, state.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw ManualRichError.invalid("Owned parent is an alias, placeholder or non-directory: \(current.path)")
        }
        _ = try manualRichVolume(current)
    }
}

func manualRichVerifySource(_ source: ManualRichSource, _ root: URL) throws {
    try manualRichParents(root, source.relativePath)
    let path = root.appendingPathComponent(source.relativePath)
    let state = try manualRichState(path)
    if source.kind == .symbolicLink {
        guard state.st_mode & S_IFMT == S_IFLNK, source.target == "manuals/installed/man1/launchctl.1" else {
            throw ManualRichError.invalid("Unexpected symbolic-link type/target at \(path.path)")
        }
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
        guard destination == "../../installed/man1/launchctl.1" else {
            throw ManualRichError.invalid("Symbolic-link destination changed at \(path.path); refusal to follow it.")
        }
        guard let target = source.target else { throw ManualRichError.invalid("Missing symbolic-link target at \(path.path)") }
        try manualRichParents(root, target)
        let bytes = try manualRichRegularBytes(root.appendingPathComponent(target))
        guard bytes.count == source.byteCount, manualRichHash(bytes) == source.sourceSHA256 else {
            throw ManualRichError.invalid("Symbolic-link content differs from the manifest: \(path.path)")
        }
    } else {
        let bytes = try manualRichRegularBytes(path)
        guard bytes.count == source.byteCount, manualRichHash(bytes) == source.sourceSHA256 else {
            throw ManualRichError.invalid("Source bytes differ from the manifest: \(path.path); retained for inspection.")
        }
        if source.kind == .hardLink {
            guard let target = source.target else { throw ManualRichError.invalid("Missing hard-link target at \(path.path)") }
            try manualRichParents(root, target)
            let targetState = try manualRichState(root.appendingPathComponent(target))
            guard state.st_dev == targetState.st_dev, state.st_ino == targetState.st_ino else {
                throw ManualRichError.invalid("Hard-link identity differs from its declared target: \(path.path)")
            }
        }
    }
}

func manualRichLoadManifest(_ root: URL, _ token: String) throws -> ManualRichManifest {
    let owner = try manualRichOwnership(root, token)
    _ = try manualRichVolume(root)
    let manifest = try manualRichRead(ManualRichManifest.self, root.appendingPathComponent("manifest-v1.json"))
    _ = try manualRichOptionsValidated(manifest.options)
    guard manifest.schema == 1, manifest.ownership.schema == owner.schema,
          manifest.ownership.root == owner.root, manifest.ownership.ownerToken == owner.ownerToken,
          manifest.ownership.creatorUID == owner.creatorUID,
          manifest.scanRoot == root.appendingPathComponent("manuals").path,
          manifest.sources.count == manifest.options.manuals + 10,
          manifest.expectedSourceLocations == manifest.sources.count,
          manifest.expectedUniqueManuals == manifest.options.manuals + 6,
          manifest.actualSourceFilesCommitted >= 0, manifest.actualSourceFilesCommitted <= manifest.sources.count,
          manifest.generationComplete == (manifest.actualSourceFilesCommitted == manifest.sources.count) else {
        throw ManualRichError.invalid("Manifest schema, ownership, source/group counts or completion fields are inconsistent: \(root.path)")
    }
    var paths: Set<String> = []
    var ids: Set<String> = []
    var bytes: UInt64 = 0
    for (index, source) in manifest.sources.enumerated() {
        guard source.relativePath.hasPrefix("manuals/"), !source.relativePath.contains("\0"),
              !source.relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              paths.insert(source.relativePath).inserted, !source.name.isEmpty, !source.section.isEmpty, !source.language.isEmpty,
              source.byteCount > 0, source.byteCount <= 8 * 1024 * 1024,
              source.sourceSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              source.contentSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              source.expectedID == "\(source.contentSHA256):\(source.section):\(source.language)", !source.formatterMarker.isEmpty else {
            throw ManualRichError.invalid("Manifest source contains invalid identity, size or owned path: \(source.relativePath)")
        }
        if index < manifest.options.manuals {
            let (name, section, marker, data) = manualRichSynthetic(index, manifest.options)
            guard source == manualRichExpected("manuals/generated/man\(section)/\(name).\(section)", name, section, "unspecified", data, data,
                marker, index % 2 == 0 ? .roff : .mdoc, index, nil, nil) else {
                throw ManualRichError.invalid("Generated source plan does not match its seed/options: \(source.relativePath)")
            }
        } else {
            guard source.ordinal == nil else { throw ManualRichError.invalid("Fixture source has an unexpected generated ordinal: \(source.relativePath)") }
        }
        ids.insert(source.expectedID)
        bytes += UInt64(source.byteCount)
    }
    guard ids.count == manifest.expectedUniqueManuals, bytes == manifest.expectedSourceBytes else {
        throw ManualRichError.invalid("Manifest distinct identities or source-byte sum is inconsistent: \(root.path)")
    }
    let fixtureKinds: [String: ManualRichSourceKind] = [
        "manuals/installed/man1/launchctl.1": .installed, "manuals/installed/man8/ping.8": .installed,
        "manuals/installed/man8/ifconfig.8": .installed, "manuals/duplicates/man1/duplicate.1": .copy,
        "manuals/aliases/man1/hard-link.1": .hardLink, "manuals/aliases/man1/file-link.1": .symbolicLink,
        "manuals/aliases/man1/whole-alias.1": .wholeAlias, "manuals/localized/fr/man1/launchctl.1": .localized,
        "manuals/localized/ja_JP/man1/launchctl.1": .localized, "manuals/versions/v2/man1/launchctl.1": .version
    ]
    let fixtures = Array(manifest.sources.dropFirst(manifest.options.manuals))
    guard Set(fixtures.map(\.relativePath)) == Set(fixtureKinds.keys),
          fixtures.allSatisfy({ fixtureKinds[$0.relativePath] == $0.kind }) else {
        throw ManualRichError.invalid("Fixture paths/kinds differ from the harness-owned layout; nothing will be deleted: \(root.path)")
    }
    let checkpoint = try manualRichRead(ManualRichCheckpoint.self, root.appendingPathComponent("generation-checkpoint-v1.json"))
    guard checkpoint.schema == 1, checkpoint.options == manifest.options,
          checkpoint.initialFreeBytes == manifest.initialFreeBytes,
          checkpoint.sourceFilesCommitted >= manifest.actualSourceFilesCommitted,
          checkpoint.sourceFilesCommitted <= manifest.sources.count else {
        throw ManualRichError.invalid("Generation checkpoint options or committed counts are inconsistent: \(root.path)")
    }
    return manifest
}

func manualRichDirectories(_ sources: [ManualRichSource]) -> Set<String> {
    var directories: Set<String> = ["manuals"]
    for source in sources {
        var components: [String] = []
        for component in source.relativePath.split(separator: "/").dropLast() {
            components.append(String(component))
            directories.insert(components.joined(separator: "/"))
        }
    }
    return directories
}

/// Files inspected by this walk are physical verification observations, never production scan counts.
func manualRichInspectTree(_ root: URL, _ manifest: ManualRichManifest) throws -> Int {
    let sources = Dictionary(uniqueKeysWithValues: manifest.sources.map { ($0.relativePath, $0) })
    let directories = manualRichDirectories(manifest.sources)
    var inspected = 0
    func visit(_ directory: URL) throws {
        try manualRichEntries(directory) { child in
            let relative = String(child.path.dropFirst(root.path.count + 1))
            let state = try manualRichState(child)
            if state.st_mode & S_IFMT == S_IFDIR {
                guard directories.contains(relative), state.st_flags & UInt32(SF_DATALESS) == 0 else {
                    throw ManualRichError.invalid("Unplanned directory or placeholder; refusal to modify it: \(child.path)")
                }
                _ = try manualRichVolume(child)
                try visit(child)
            } else {
                guard let source = sources[relative] else { throw ManualRichError.invalid("Foreign source file; refusal to modify it: \(child.path)") }
                try manualRichVerifySource(source, root)
                inspected += 1
            }
        }
    }
    let scanRoot = root.appendingPathComponent("manuals")
    var state = stat()
    if lstat(scanRoot.path, &state) == 0 {
        guard state.st_mode & S_IFMT == S_IFDIR else { throw ManualRichError.invalid("Manual root must be a real directory: \(scanRoot.path)") }
        try visit(scanRoot)
    } else if errno != ENOENT { throw ManualRichError.filesystem(scanRoot.path, errno) }
    return inspected
}

func manualRichVerify(_ root: URL, _ token: String) throws {
    let began = ProcessInfo.processInfo.systemUptime
    let manifest = try manualRichLoadManifest(root, token)
    let actual = try manualRichInspectTree(root, manifest)
    guard manifest.generationComplete, actual == manifest.expectedSourceLocations else {
        throw ManualRichError.invalid("Corpus is incomplete: independently inspected \(actual), expected \(manifest.expectedSourceLocations); resume original generation options first.")
    }
    let result = ManualRichVerification(schema: 1, root: root.path, actualFilesInspected: actual,
        expectedLocations: manifest.expectedSourceLocations, expectedUniqueManuals: manifest.expectedUniqueManuals,
        verified: Date(), elapsedSeconds: ProcessInfo.processInfo.systemUptime - began)
    try manualRichWrite(result, root.appendingPathComponent("verification-v1.json"))
    print("event=physical-verification actualFilesInspected=\(actual) expectedUniqueManuals=\(result.expectedUniqueManuals) root=\(root.path)")
}

/// Only a fully preflighted owned tree is removed; arbitrary files or parent aliases block cleanup.
func manualRichCleanup(_ root: URL, _ token: String) throws {
    let manifest = try manualRichLoadManifest(root, token)
    let actual = try manualRichInspectTree(root, manifest)
    let sources = Dictionary(uniqueKeysWithValues: manifest.sources.map { ($0.relativePath, $0) })
    let directories = manualRichDirectories(manifest.sources)
    let controls: Set<String> = [".manual-rich-owner-v1.json", "manifest-v1.json", "generation-checkpoint-v1.json", "verification-v1.json", "production-verification-v1.json"]
    try manualRichEntries(root) { child in
        if child.lastPathComponent == "manuals" { return }
        guard controls.contains(child.lastPathComponent), try manualRichState(child).st_mode & S_IFMT == S_IFREG else {
            throw ManualRichError.invalid("Foreign control file or alias; nothing deleted: \(child.path)")
        }
    }
    func remove(_ directory: URL) throws {
        try manualRichEntries(directory) { child in
            let state = try manualRichState(child)
            let relative = String(child.path.dropFirst(root.path.count + 1))
            if state.st_mode & S_IFMT == S_IFDIR {
                guard directories.contains(relative) else { throw ManualRichError.invalid("Unplanned directory appeared during cleanup; retained: \(child.path)") }
                try remove(child)
            } else {
                if let source = sources[relative] {
                    // Targets may already be removed: validate the entry being unlinked without following aliases.
                    if source.kind == .symbolicLink {
                        guard state.st_mode & S_IFMT == S_IFLNK,
                              try FileManager.default.destinationOfSymbolicLink(atPath: child.path) == "../../installed/man1/launchctl.1" else {
                            throw ManualRichError.invalid("Symbolic link changed during cleanup; retained: \(child.path)")
                        }
                    } else {
                        let bytes = try manualRichRegularBytes(child)
                        guard bytes.count == source.byteCount, manualRichHash(bytes) == source.sourceSHA256 else {
                            throw ManualRichError.invalid("Source changed during cleanup; retained: \(child.path)")
                        }
                    }
                }
                else {
                    guard directory == root, controls.contains(child.lastPathComponent), state.st_mode & S_IFMT == S_IFREG else {
                        throw ManualRichError.invalid("Foreign file appeared during cleanup; retained: \(child.path)")
                    }
                }
                guard unlink(child.path) == 0 else { throw ManualRichError.filesystem(child.path, errno) }
            }
        }
        guard rmdir(directory.path) == 0 else { throw ManualRichError.filesystem(directory.path, errno) }
    }
    try remove(root)
    print("event=cleanup actualSourceFilesRemoved=\(actual) root=\(root.path)")
}

struct ManualRichObservedLocation: Decodable {
    let source: URL
    let root: URL
    let name: String
    let section: String
    let language: String
    let stamp: String
}

struct ManualRichObservedPage: Decodable {
    let name: String
    let section: String
    let source: URL
    let root: URL
    let fingerprint: String
    let language: String
    let locations: [ManualRichObservedLocation]
    let description: String
    let indexed: Bool
    let problem: String?
    var id: String { "\(fingerprint):\(section):\(language)" }
}

struct ManualRichObservedIssue: Decodable { let path: String; let kind: String; let reason: String }
struct ManualRichObservedCoverage: Decodable {
    let root: URL
    let count: Int
    let directories: Int
    let files: Int
    let completed: Bool
    let issues: [ManualRichObservedIssue]
}
struct ManualRichObservedScan: Decodable {
    let pages: [ManualRichObservedPage]
    let coverage: [ManualRichObservedCoverage]
    let cancelled: Bool
}
struct ManualRichProductionVerification: Codable {
    let schema: Int
    let verified: Date
    let manifest: String
    let inventory: String
    let index: String
    let productionRoot: String
    let observedDiscoveryFiles: Int
    let observedDiscoveryDirectories: Int
    let observedManualLocations: Int
    let observedUniqueManuals: Int
    let observedReadableIndexedManuals: Int
    let indexedManualsWithDiagnostics: Int
    let expectedManualLocations: Int
    let expectedUniqueManuals: Int
    let failures: [String]
    let limitations: [String]
}

func manualRichColumn(_ statement: OpaquePointer, _ column: Int32) throws -> String {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, column) else {
        throw ManualRichError.database("Expected non-null TEXT column \(column).")
    }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count <= 64 * 1024 * 1024, let value = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8) else {
        throw ManualRichError.database("Column \(column) is invalid UTF-8 or exceeds the 64 MiB row limit.")
    }
    return value
}

/// Independently inspect persisted production inventory/FTS bodies; this does not call the scanner or formatter.
func manualRichVerifyProduction(_ root: URL, _ token: String, _ inventory: URL, _ index: URL, _ output: URL) throws {
    let manifest = try manualRichLoadManifest(root, token)
    guard manifest.generationComplete else { throw ManualRichError.invalid("Production verification requires a completed generation manifest.") }
    guard output.path != inventory.path, output.path != index.path,
          !output.path.hasPrefix(root.path + "/") || output == root.appendingPathComponent("production-verification-v1.json") else {
        throw ManualRichError.invalid("Choose a separate verification output; corpus control/source files and production inputs cannot be overwritten.")
    }
    let saved = try manualRichRead(ManualRichObservedScan.self, inventory)
    let expectedByPath = Dictionary(uniqueKeysWithValues: manifest.sources.map { (root.appendingPathComponent($0.relativePath).path, $0) })
    let expectedGroups = Dictionary(grouping: manifest.sources, by: \.expectedID)
    var failures: [String] = []
    let coverage = saved.coverage.filter { $0.root.isFileURL && $0.root.path == manifest.scanRoot }
    if saved.cancelled { failures.append("Production inventory is cancelled.") }
    if saved.coverage.count != 1 || coverage.count != 1 { failures.append("Expected exactly one production coverage root for \(manifest.scanRoot).") }
    if coverage.count == 1 {
        let row = coverage[0]
        if !row.completed || !row.issues.isEmpty || row.files != manifest.expectedSourceLocations || row.directories <= 0 || row.count != manifest.expectedSourceLocations {
            failures.append("Production coverage is incomplete, has issues or differs from expected inspected files/groups: files=\(row.files), manuals=\(row.count), completed=\(row.completed), issues=\(row.issues.count).")
        }
    }
    var pages: [String: ManualRichObservedPage] = [:]
    var paths: Set<String> = []
    for page in saved.pages {
        guard pages[page.id] == nil else { failures.append("Duplicate production group: \(page.id)"); continue }
        pages[page.id] = page
        guard let group = expectedGroups[page.id] else { failures.append("Unexpected production identity: \(page.id)"); continue }
        if !page.indexed || page.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("Manual not successfully described/indexed: \(page.source.path); indexed=\(page.indexed), descriptionCharacters=\(page.description.count), diagnostic=\(page.problem ?? "none").")
        }
        if !page.source.isFileURL || !page.root.isFileURL || page.root.path != manifest.scanRoot ||
            !page.locations.contains(where: { $0.source == page.source && $0.name == page.name && $0.root == page.root }) ||
            page.locations.count != group.count { failures.append("Primary source/root or grouped-location count differs: \(page.id).") }
        for location in page.locations {
            guard location.source.isFileURL, location.root.isFileURL, location.root.path == manifest.scanRoot,
                  let source = expectedByPath[location.source.path] else { failures.append("Unexpected source/root: \(location.source.absoluteString)"); continue }
            if !paths.insert(location.source.path).inserted || location.name != source.name || location.section != source.section ||
                location.language != source.language || source.expectedID != page.id || location.stamp.isEmpty {
                failures.append("Location metadata/identity/uniqueness differs: \(location.source.path).")
            }
        }
    }
    if Set(pages.keys) != Set(expectedGroups.keys) || paths != Set(expectedByPath.keys) { failures.append("Production identities or observed location set differs from the manifest.") }
    let indexState = try manualRichState(index)
    guard indexState.st_mode & S_IFMT == S_IFREG, indexState.st_flags & UInt32(SF_DATALESS) == 0 else { throw ManualRichError.invalid("Production index must be a materialized regular file: \(index.path)") }
    _ = try manualRichVolume(index)
    var database: OpaquePointer?
    let opened = sqlite3_open_v2(index.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
    guard opened == SQLITE_OK, let handle = database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite handle"
        if let database { _ = sqlite3_close(database) }
        throw ManualRichError.database("Cannot open \(index.path): status \(opened), \(message)")
    }
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(handle, "SELECT id,fingerprint,description,body,diagnostic FROM manuals_v3 ORDER BY id", -1, &statement, nil)
    guard prepared == SQLITE_OK, let query = statement else {
        let message = String(cString: sqlite3_errmsg(handle))
        _ = sqlite3_close(handle)
        throw ManualRichError.database("Cannot read manuals_v3: status \(prepared), \(message)")
    }
    var readable = 0
    var diagnostics = 0
    var indexed: Set<String> = []
    let outcome: Result<Void, Error> = Result {
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ManualRichError.database("Read failed: status \(step), \(String(cString: sqlite3_errmsg(handle)))") }
            try autoreleasepool {
                let id = try manualRichColumn(query, 0)
                let fingerprint = try manualRichColumn(query, 1)
                let description = try manualRichColumn(query, 2)
                let body = try manualRichColumn(query, 3)
                let diagnostic = try manualRichColumn(query, 4)
                guard indexed.insert(id).inserted, let source = expectedGroups[id]?.first, let page = pages[id] else {
                    failures.append("Unexpected or duplicated FTS identity: \(id)"); return
                }
                if !diagnostic.isEmpty { diagnostics += 1 }
                if fingerprint == source.contentSHA256, description == page.description, page.problem == (diagnostic.isEmpty ? nil : diagnostic),
                   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.contains(source.formatterMarker) {
                    readable += 1
                } else { failures.append("Persisted formatter body, fingerprint or description failed verification: \(id).") }
            }
        }
    }
    let finalized = sqlite3_finalize(query)
    let closed = sqlite3_close(handle)
    try outcome.get()
    guard finalized == SQLITE_OK, closed == SQLITE_OK else { throw ManualRichError.database("Cannot finalize/close production read: finalize=\(finalized), close=\(closed)") }
    if indexed != Set(expectedGroups.keys) || readable != manifest.expectedUniqueManuals { failures.append("Persisted readable FTS groups differ: indexed=\(indexed.count), readable=\(readable), expected=\(manifest.expectedUniqueManuals).") }
    let report = ManualRichProductionVerification(schema: 1, verified: Date(), manifest: root.appendingPathComponent("manifest-v1.json").path,
        inventory: inventory.path, index: index.path, productionRoot: manifest.scanRoot,
        observedDiscoveryFiles: coverage.first?.files ?? 0, observedDiscoveryDirectories: coverage.first?.directories ?? 0,
        observedManualLocations: paths.count, observedUniqueManuals: pages.count, observedReadableIndexedManuals: readable,
        indexedManualsWithDiagnostics: diagnostics, expectedManualLocations: manifest.expectedSourceLocations,
        expectedUniqueManuals: manifest.expectedUniqueManuals, failures: failures,
        limitations: ["Physical generation counts are separate from production coverage counters and persisted formatter/FTS observations.",
            "Body-marker checks establish readable persisted formatter output; they do not validate rendered WebKit, page Find, PDF export or every source paragraph.",
            "SQLite was opened read-only using the host SQLite API. Corpus generation/verification warm source caches; no controlled cold-cache claim is made."])
    try manualRichWrite(report, output)
    guard failures.isEmpty else { throw ManualRichError.invalid("Production verification has \(failures.count) failures; report retained at \(output.path): \(failures.prefix(3).joined(separator: "; "))") }
    print("event=production-verification observedDiscoveryFiles=\(report.observedDiscoveryFiles) observedUniqueManuals=\(report.observedUniqueManuals) readableIndexedManuals=\(readable) output=\(output.path)")
}
