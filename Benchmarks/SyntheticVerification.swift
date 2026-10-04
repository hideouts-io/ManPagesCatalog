import Foundation
import Darwin

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
    let folders = try FileManager.default.contentsOfDirectory(at: ordinary, includingPropertiesForKeys: nil)
    guard folders.count == expectedDirectories else { throw HarnessError.invalid("Unexpected ordinary directory count: \(folders.count), expected \(expectedDirectories).") }
    for folder in folders {
        guard try checkedState(folder).st_mode & S_IFMT == S_IFDIR else { throw HarnessError.invalid("Ordinary corpus contains an unexpected directory alias: \(folder.path)") }
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for url in entries {
            let name = url.deletingPathExtension().lastPathComponent
            guard let raw = name.split(separator: "-").last, let index = Int(raw), index < checkpoint.ordinaryFilesCreated,
                  url == ordinaryURL(root, index, checkpoint.options) else { throw HarnessError.invalid("Unexpected ordinary entry: \(url.path)") }
            let expected = ordinaryPayload(index, checkpoint.options.seed)
            try verifyOrdinary(url, expected)
            actual += 1
            if !expected.isEmpty { nonempty += 1 }
        }
    }
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
    let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    guard entries.allSatisfy({ allowed.contains($0.lastPathComponent) }) else {
        throw HarnessError.invalid("Root contains foreign top-level entries; move them out before harness cleanup: \(root.path)")
    }
    if entries.contains(where: { $0.lastPathComponent == "ordinary" }) {
        let ordinary = root.appendingPathComponent("ordinary")
        guard try checkedState(ordinary).st_mode & S_IFMT == S_IFDIR else { throw HarnessError.invalid("Cleanup refuses an ordinary/ root replaced by a directory alias.") }
        for folder in try FileManager.default.contentsOfDirectory(at: ordinary, includingPropertiesForKeys: nil) {
            let folderName = folder.lastPathComponent
            guard folderName.hasPrefix("b"), let number = Int(folderName.dropFirst()), number >= 0,
                  number < checkpoint.options.breadth, folderName == String(format: "b%06lld", Int64(number)),
                  try checkedState(folder).st_mode & S_IFMT == S_IFDIR else {
                throw HarnessError.invalid("Cleanup refuses a foreign directory or directory alias: \(folder.path)")
            }
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                guard let raw = url.deletingPathExtension().lastPathComponent.split(separator: "-").last,
                      let index = Int(raw), index >= 0, index < checkpoint.options.files,
                      url == ordinaryURL(root, index, checkpoint.options) else {
                    throw HarnessError.invalid("Cleanup refuses a foreign ordinary-corpus entry: \(url.path)")
                }
                try verifyOrdinary(url, ordinaryPayload(index, checkpoint.options.seed))
            }
        }
    }
    if entries.contains(where: { $0.lastPathComponent == "fixtures" }) {
        let fixtures = try decoded(FixtureManifest.self, root.appendingPathComponent("fixture-manifest-v1.json"))
        var paths = Set(fixtures.manuals.map(\.relativePath) + fixtures.issues.map(\.relativePath) + ["fixtures/inaccessible/unseen.1"])
        for path in Array(paths) {
            let components = path.split(separator: "/")
            for length in 1..<components.count { paths.insert(components.prefix(length).joined(separator: "/")) }
        }
        var pending = [root.appendingPathComponent("fixtures")]
        while let directory = pending.popLast() {
            for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
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
    try FileManager.default.removeItem(at: root)
    try FileHandle.standardOutput.write(contentsOf: Data("Removed ownership-verified harness root: \(root.path)\n".utf8))
}
