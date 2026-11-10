import Foundation
import Darwin

/// Read one native directory entry at a time, rejecting aliases and invalid UTF-8 names.
/// Enumeration and descriptor-close errors are explicit; each callback has its own autorelease pool.
func forEachHarnessDirectoryEntry(_ directory: URL, _ body: (URL) throws -> Void) throws {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw HarnessError.filesystem(directory.path, errno) }
    guard let handle = fdopendir(descriptor) else {
        let failure = errno
        guard close(descriptor) == 0 else { throw HarnessError.filesystem(directory.path, errno) }
        throw HarnessError.filesystem(directory.path, failure)
    }
    let enumeration: Result<Void, Error> = Result {
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                guard errno == 0 else { throw HarnessError.filesystem(directory.path, errno) }
                break
            }
            try autoreleasepool {
                let name = try withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                    let length = Int(entry.pointee.d_namlen)
                    guard length > 0, length < bytes.count, bytes[length] == 0,
                          let name = String(bytes: bytes.prefix(length), encoding: .utf8),
                          !name.contains("/"), !name.contains("\0") else {
                        throw HarnessError.invalid("Directory contains an invalid UTF-8 or malformed entry name: \(directory.path)")
                    }
                    return name
                }
                if name != ".", name != ".." { try body(directory.appendingPathComponent(name)) }
            }
        }
    }
    if closedir(handle) != 0 {
        let failure = errno
        if case .failure(let error) = enumeration {
            throw HarnessError.invalid("Cannot close directory \(directory.path) (errno \(failure)); enumeration also failed: \(error.localizedDescription)")
        }
        throw HarnessError.filesystem(directory.path, failure)
    }
    try enumeration.get()
}

/// Verify actual ordinary entries with lstat and their deterministic payload, without following directory aliases.
/// This operation is explicit because a full verification warms the corpus before benchmark scanning.
func verify(_ root: URL, _ token: String) throws {
    _ = try ownership(root, token)
    let checkpoint = try validatedGenerationCheckpoint(decoded(GenerationCheckpoint.self, root.appendingPathComponent("generation-checkpoint-v1.json")))
    let manifest = try decoded(TreeManifest.self, root.appendingPathComponent("manifest-v1.json"))
    let start = DispatchTime.now().uptimeNanoseconds
    let ordinary = root.appendingPathComponent("ordinary")
    guard try checkedState(ordinary).st_mode & S_IFMT == S_IFDIR,
          try checkedState(root.appendingPathComponent("fixtures")).st_mode & S_IFMT == S_IFDIR else {
        throw HarnessError.invalid("Verification refuses an ordinary/ or fixtures/ root replaced by a directory alias.")
    }
    var actual = 0
    var nonempty = 0
    let expectedDirectories = checkpoint.ordinaryFilesCreated == 0 ? 0 : 1 + (checkpoint.ordinaryFilesCreated - 1) / checkpoint.options.filesPerDirectory
    var folders = 0
    try forEachHarnessDirectoryEntry(ordinary) { folder in
        folders += 1
        guard try checkedState(folder).st_mode & S_IFMT == S_IFDIR else { throw HarnessError.invalid("Ordinary corpus contains an unexpected directory alias: \(folder.path)") }
        try forEachHarnessDirectoryEntry(folder) { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard let raw = name.split(separator: "-").last, let index = Int(raw), index < checkpoint.ordinaryFilesCreated,
                  url == ordinaryURL(root, index, checkpoint.options) else { throw HarnessError.invalid("Unexpected ordinary entry: \(url.path)") }
            let expected = ordinaryPayload(index, checkpoint.options.seed)
            try verifyOrdinary(url, expected)
            actual += 1
            if !expected.isEmpty { nonempty += 1 }
        }
    }
    guard folders == expectedDirectories else { throw HarnessError.invalid("Unexpected ordinary directory count: \(folders), expected \(expectedDirectories).") }
    guard actual == checkpoint.ordinaryFilesCreated, nonempty == manifest.payloadOrdinaryFiles else {
        throw HarnessError.invalid("Actual ordinary counts differ from checkpoint/manifest: \(actual) files, \(nonempty) payload files.")
    }
    for manual in manifest.fixtures.manuals {
        let url = root.appendingPathComponent(manual.relativePath)
        _ = try checkedState(url)
        let bytes: Data
        if manual.kind == "whole-file-so-alias" {
            guard try Data(contentsOf: url) == Data(".so launchctl.1\n".utf8) else { throw HarnessError.invalid("Fixture whole-file alias differs at \(url.path)") }
            bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/000-primary/man1/launchctl.1"))
        } else if manual.kind == "compressed-source" {
            let container = try Data(contentsOf: url)
            let tool: String
            if container.starts(with: [0x1f, 0x8b]) { tool = "/usr/bin/gzip" }
            else if container.starts(with: [0x1f, 0x9d]) { tool = "/usr/bin/compress" }
            else if container.starts(with: [0x42, 0x5a, 0x68]) { tool = "/usr/bin/bzip2" }
            else { throw HarnessError.invalid("Fixture compression signature differs at \(url.path)") }
            bytes = try compressed(tool, ["-d", "-c", url.path], root)
        } else { bytes = try Data(contentsOf: url) }
        guard digest(bytes) == manual.contentSHA256 else { throw HarnessError.invalid("Fixture logical content differs at \(url.path)") }
    }
    let hard = try checkedState(root.appendingPathComponent("fixtures/000-primary/man1/hard-link.1"))
    let primary = try checkedState(root.appendingPathComponent("fixtures/000-primary/man1/launchctl.1"))
    guard hard.st_dev == primary.st_dev, hard.st_ino == primary.st_ino, hard.st_nlink >= 2 else {
        throw HarnessError.invalid("The hard-link fixture no longer shares the primary manual inode.")
    }
    for issue in manifest.fixtures.issues {
        _ = try checkedState(root.appendingPathComponent(issue.relativePath))
        if issue.kind == "excluded", issue.relativePath.contains("directory-alias") {
            guard try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(issue.relativePath).path) == "000-primary" else {
                throw HarnessError.invalid("The directory alias fixture changed: \(issue.relativePath)")
            }
        }
    }
    let permission = try inaccessibleState(root.appendingPathComponent("fixtures/inaccessible"))
    let report = Verification(schema: 1, root: root.path, ordinaryFilesInspected: actual, emptyOrdinaryFiles: actual - nonempty,
                              payloadOrdinaryFiles: nonempty, fixtureManualLocationsVerified: manifest.fixtures.manuals.count,
                              uniqueExpectedGroups: Set(manifest.fixtures.manuals.map(\.groupIdentity)).count,
                              inaccessibleVerified: permission.0, verified: Date(), elapsedSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
    try writeJSON(report, root.appendingPathComponent("verification-v1.json"))
    try FileHandle.standardOutput.write(contentsOf: encoded(report) + Data([10]))
}

/// Cleanup refuses foreign top-level data, requires the original token/UID/path, and never follows symlinks.
/// Only the harness-owned protected fixture has its permissions restored before deletion.
func requireOwnedCleanupContents(_ root: URL, _ checkpoint: GenerationCheckpoint) throws {
    let allowed: Set<String> = [".manpages-stress-owner.json", "generation-checkpoint-v1.json", "fixture-manifest-v1.json", "manifest-v1.json", "verification-v1.json", "fixtures", "ordinary"]
    var ordinaryExists = false
    var fixturesExist = false
    try forEachHarnessDirectoryEntry(root) { entry in
        guard allowed.contains(entry.lastPathComponent) else {
            throw HarnessError.invalid("Root contains foreign top-level entries; move them out before harness cleanup: \(root.path)")
        }
        if entry.lastPathComponent == "ordinary" { ordinaryExists = true }
        if entry.lastPathComponent == "fixtures" { fixturesExist = true }
    }
    if ordinaryExists {
        let ordinary = root.appendingPathComponent("ordinary")
        guard try checkedState(ordinary).st_mode & S_IFMT == S_IFDIR else { throw HarnessError.invalid("Cleanup refuses an ordinary/ root replaced by a directory alias.") }
        try forEachHarnessDirectoryEntry(ordinary) { folder in
            let folderName = folder.lastPathComponent
            guard folderName.hasPrefix("b"), let number = Int(folderName.dropFirst()), number >= 0,
                  number < checkpoint.options.breadth, folderName == String(format: "b%06lld", Int64(number)),
                  try checkedState(folder).st_mode & S_IFMT == S_IFDIR else {
                throw HarnessError.invalid("Cleanup refuses a foreign directory or directory alias: \(folder.path)")
            }
            try forEachHarnessDirectoryEntry(folder) { url in
                guard let raw = url.deletingPathExtension().lastPathComponent.split(separator: "-").last,
                      let index = Int(raw), index >= 0, index < checkpoint.options.files,
                      url == ordinaryURL(root, index, checkpoint.options) else {
                    throw HarnessError.invalid("Cleanup refuses a foreign ordinary-corpus entry: \(url.path)")
                }
                try verifyOrdinary(url, ordinaryPayload(index, checkpoint.options.seed))
            }
        }
    }
    if fixturesExist {
        let fixtures = try decoded(FixtureManifest.self, root.appendingPathComponent("fixture-manifest-v1.json"))
        var paths = Set(fixtures.manuals.map(\.relativePath) + fixtures.issues.map(\.relativePath) + ["fixtures/inaccessible/unseen.1"])
        for path in Array(paths) {
            let components = path.split(separator: "/")
            for length in 1..<components.count { paths.insert(components.prefix(length).joined(separator: "/")) }
        }
        var pending = [root.appendingPathComponent("fixtures")]
        while let directory = pending.popLast() {
            try forEachHarnessDirectoryEntry(directory) { entry in
                let relative = String(entry.path.dropFirst(root.path.count + 1))
                guard paths.contains(relative) else { throw HarnessError.invalid("Cleanup refuses a foreign fixture entry: \(entry.path)") }
                let metadata = try checkedState(entry)
                if metadata.st_mode & S_IFMT == S_IFDIR { pending.append(entry) }
                else if ![S_IFREG, S_IFLNK].contains(metadata.st_mode & S_IFMT) {
                    throw HarnessError.invalid("Cleanup refuses an unexpected special filesystem entry: \(entry.path)")
                }
            }
        }
    }
}

/// Remove a fully ownership-validated tree without materializing wide directories or following symlinks.
func removeOwnedHarnessDirectory(_ directory: URL) throws {
    try forEachHarnessDirectoryEntry(directory) { entry in
        let metadata = try checkedState(entry)
        if metadata.st_mode & S_IFMT == S_IFDIR {
            try removeOwnedHarnessDirectory(entry)
        } else {
            guard [S_IFREG, S_IFLNK].contains(metadata.st_mode & S_IFMT) else {
                throw HarnessError.invalid("Cleanup refuses an unexpected special filesystem entry: \(entry.path)")
            }
            guard unlink(entry.path) == 0 else { throw HarnessError.filesystem(entry.path, errno) }
        }
    }
    guard rmdir(directory.path) == 0 else { throw HarnessError.filesystem(directory.path, errno) }
}

func cleanup(_ root: URL, _ token: String) throws {
    _ = try ownership(root, token)
    let checkpoint = try validatedGenerationCheckpoint(decoded(GenerationCheckpoint.self, root.appendingPathComponent("generation-checkpoint-v1.json")))
    let fixturesRoot = root.appendingPathComponent("fixtures")
    var fixtureMetadata = stat()
    if lstat(fixturesRoot.path, &fixtureMetadata) == 0 {
        guard fixtureMetadata.st_mode & S_IFMT == S_IFDIR else { throw HarnessError.invalid("Cleanup refuses a fixtures/ root replaced by a directory alias.") }
    } else if errno != ENOENT { throw HarnessError.filesystem(fixturesRoot.path, errno) }
    let protected = root.appendingPathComponent("fixtures/inaccessible")
    var state = stat()
    let protectedExists: Bool
    if lstat(protected.path, &state) == 0 {
        guard state.st_mode & S_IFMT == S_IFDIR, chmod(protected.path, 0o700) == 0 else { throw HarnessError.filesystem(protected.path, errno) }
        protectedExists = true
    } else {
        guard errno == ENOENT else { throw HarnessError.filesystem(protected.path, errno) }
        protectedExists = false
    }
    do { try requireOwnedCleanupContents(root, checkpoint) }
    catch {
        if protectedExists, chmod(protected.path, 0o000) != 0 { throw HarnessError.filesystem(protected.path, errno) }
        throw error
    }
    try removeOwnedHarnessDirectory(root)
    try FileHandle.standardOutput.write(contentsOf: Data("Removed ownership-verified harness root: \(root.path)\n".utf8))
}
