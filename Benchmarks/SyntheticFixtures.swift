import Foundation
import Darwin

func writeFixture(_ bytes: Data, _ url: URL) throws {
    try makeDirectory(url.deletingLastPathComponent())
    var state = stat()
    if lstat(url.path, &state) == 0 {
        guard state.st_mode & S_IFMT == S_IFREG, try Data(contentsOf: url) == bytes else {
            throw HarnessError.invalid("Existing fixture differs from its deterministic source: \(url.path). Choose a fresh root or restore the original installed manual version.")
        }
    } else {
        guard errno == ENOENT else { throw HarnessError.filesystem(url.path, errno) }
        try bytes.write(to: url, options: .atomic)
    }
}

func makeLink(_ destination: String, _ url: URL) throws {
    try makeDirectory(url.deletingLastPathComponent())
    var state = stat()
    if lstat(url.path, &state) == 0 {
        guard state.st_mode & S_IFMT == S_IFLNK, try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == destination else {
            throw HarnessError.invalid("Existing symbolic link differs from the harness manifest: \(url.path)")
        }
    } else {
        guard errno == ENOENT else { throw HarnessError.filesystem(url.path, errno) }
        guard symlink(destination, url.path) == 0 else { throw HarnessError.filesystem(url.path, errno) }
    }
}

func makeHardLink(_ source: URL, _ destination: URL) throws {
    var value = stat()
    if lstat(destination.path, &value) == 0 {
        let original = try checkedState(source)
        guard value.st_mode & S_IFMT == S_IFREG, value.st_dev == original.st_dev, value.st_ino == original.st_ino else {
            throw HarnessError.invalid("Expected the original fixture inode at \(destination.path)")
        }
    } else {
        guard errno == ENOENT else { throw HarnessError.filesystem(destination.path, errno) }
        guard link(source.path, destination.path) == 0 else { throw HarnessError.filesystem(destination.path, errno) }
    }
}

func compressed(_ executable: String, _ arguments: [String], _ directory: URL) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let output = Pipe()
    let diagnostic = Pipe()
    process.standardOutput = output
    process.standardError = diagnostic
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    let warnings = diagnostic.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HarnessError.tool(executable, process.terminationStatus, String(decoding: warnings, as: UTF8.self))
    }
    return bytes
}

func expectedManual(_ path: String, _ name: String, _ section: String, _ language: String, _ bytes: Data, _ kind: String) -> ExpectedManual {
    let sha = digest(bytes)
    return ExpectedManual(relativePath: path, name: name, section: section, language: language,
                          contentSHA256: sha, groupIdentity: "\(sha):\(section):\(language)", kind: kind)
}

func inaccessibleState(_ directory: URL) throws -> (Bool, Int32) {
    guard chmod(directory.path, 0o000) == 0 else { throw HarnessError.filesystem(directory.path, errno) }
    if let handle = opendir(directory.path) {
        guard closedir(handle) == 0 else { throw HarnessError.filesystem(directory.path, errno) }
        return (false, 0)
    }
    let code = errno
    guard [EACCES, EPERM].contains(code) else { throw HarnessError.filesystem(directory.path, code) }
    return (true, code)
}

/// Fixtures reuse real installed manuals without linking to or modifying originals.
/// Whole-file aliases and compressed copies share logical hashes; sections/languages remain distinct groups.
func createFixtures(_ root: URL) throws -> FixtureManifest {
    let launchctl = try Data(contentsOf: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"))
    let ping = try Data(contentsOf: URL(fileURLWithPath: "/usr/share/man/man8/ping.8"))
    let ifconfig = try Data(contentsOf: URL(fileURLWithPath: "/usr/share/man/man8/ifconfig.8"))
    let primary = "fixtures/000-primary/man1/launchctl.1"
    var manuals: [ExpectedManual] = []
    var issues: [ExpectedIssue] = []
    var tools: [String] = []
    var unavailable: [String] = ["Additional mounted-volume fixture is not part of this single-volume tree; run the production scanner with separately selected local-volume roots.", "No network storage is accessed or synthesized."]
    let base = root.appendingPathComponent(primary)
    try writeFixture(launchctl, base)
    manuals.append(expectedManual(primary, "launchctl", "1", "unspecified", launchctl, "installed-mdoc"))
    let duplicate = "fixtures/000-primary/man1/duplicate.1"
    try writeFixture(launchctl, root.appendingPathComponent(duplicate))
    manuals.append(expectedManual(duplicate, "duplicate", "1", "unspecified", launchctl, "identical-content-copy"))
    let hard = "fixtures/000-primary/man1/hard-link.1"
    try makeHardLink(base, root.appendingPathComponent(hard))
    manuals.append(expectedManual(hard, "hard-link", "1", "unspecified", launchctl, "hard-link"))
    let symbolic = "fixtures/000-primary/man1/symbolic-link.1"
    try makeLink("launchctl.1", root.appendingPathComponent(symbolic))
    manuals.append(expectedManual(symbolic, "symbolic-link", "1", "unspecified", launchctl, "file-symlink"))
    let alias = "fixtures/000-primary/man1/whole-alias.1"
    try writeFixture(Data(".so launchctl.1\n".utf8), root.appendingPathComponent(alias))
    manuals.append(expectedManual(alias, "whole-alias", "1", "unspecified", launchctl, "whole-file-so-alias"))
    for (tool, arguments, path, name) in [
        ("/usr/bin/gzip", ["-n", "-c", base.path], "fixtures/000-primary/man1/gzip-copy.1.gz", "gzip-copy"),
        ("/usr/bin/compress", ["-c", base.path], "fixtures/000-primary/man1/compress-copy.1.Z", "compress-copy"),
        ("/usr/bin/bzip2", ["-c", base.path], "fixtures/000-primary/man1/bzip-copy.1.bz2", "bzip-copy"),
        ("/usr/bin/gzip", ["-n", "-c", base.path], "fixtures/odd locations/renamed-compressed-source", "launchctl")
    ] {
        try writeFixture(compressed(tool, arguments, root), root.appendingPathComponent(path))
        manuals.append(expectedManual(path, name, "1", "unspecified", launchctl, "compressed-source"))
        tools.append(tool)
    }
    for locale in ["fr", "ja_JP"] {
        let path = "fixtures/localized/\(locale)/man1/launchctl.1"
        try writeFixture(launchctl, root.appendingPathComponent(path))
        manuals.append(expectedManual(path, "launchctl", "1", locale, launchctl, "localized-path"))
    }
    let revised = launchctl + Data("\n.\\\" Deterministic synthetic second package revision\n".utf8)
    let revisedPath = "fixtures/version-two/man1/launchctl.1"
    try writeFixture(revised, root.appendingPathComponent(revisedPath))
    manuals.append(expectedManual(revisedPath, "launchctl", "1", "unspecified", revised, "distinct-version"))
    for (path, name, section, bytes) in [
        ("fixtures/odd locations/Unicode café/network reference", "ping", "8", ping),
        ("fixtures/extended/man8special/ping.8special", "ping", "8special", ping),
        ("fixtures/network/man8/ifconfig.8", "ifconfig", "8", ifconfig)
    ] {
        try writeFixture(bytes, root.appendingPathComponent(path))
        manuals.append(expectedManual(path, name, section, "unspecified", bytes, "installed-network-manual"))
    }
    let roff = Data(".TH SYNTHETIC 3p \"2026-10-03\" \"Benchmark\"\n.SH \"NAME\"\nsynthetic \\- deterministic multiline\nmanual fixture\n.SH SYNOPSIS\n.B synthetic\n.SH DESCRIPTION\nThis manual exercises discovery without executing commands.\n".utf8)
    let roffPath = "fixtures/native/man3p/synthetic.3p"
    try writeFixture(roff, root.appendingPathComponent(roffPath))
    manuals.append(expectedManual(roffPath, "synthetic", "3p", "unspecified", roff, "synthetic-roff"))
    let mdoc = Data(".Dd October 3, 2026\n.Dt SYNTHETIC-MDOC 1\n.Os\n.Sh NAME\n.Nm synthetic-mdoc\n.Nd deterministic multiline\nmdoc fixture\n.Sh SYNOPSIS\n.Nm\n.Sh DESCRIPTION\nThis manual is documentation only.\n".utf8)
    let mdocPath = "fixtures/native/man1/synthetic-mdoc.1"
    try writeFixture(mdoc, root.appendingPathComponent(mdocPath))
    manuals.append(expectedManual(mdocPath, "synthetic-mdoc", "1", "unspecified", mdoc, "synthetic-mdoc"))
    let deepPath = "fixtures/.hidden/Tool.app/Contents/Resources/" + (0..<64).map { String(format: "d%02d", $0) }.joined(separator: "/") + "/space folder/日本語 café/nonstandard documentation"
    try writeFixture(mdoc, root.appendingPathComponent(deepPath))
    manuals.append(expectedManual(deepPath, "synthetic-mdoc", "1", "unspecified", mdoc, "deep-hidden-application-unicode"))
    for path in ["fixtures/directory-alias-one", "fixtures/directory-alias-two"] {
        try makeLink("000-primary", root.appendingPathComponent(path))
        issues.append(ExpectedIssue(relativePath: path, kind: "excluded", reason: "Directory alias of an already traversed directory; no repeated traversal is expected."))
    }
    try makeLink(".", root.appendingPathComponent("fixtures/root-loop"))
    issues.append(ExpectedIssue(relativePath: "fixtures/root-loop", kind: "excluded", reason: "Directory inode was already visited; symlink loop must terminate."))
    try makeLink("missing-target.1", root.appendingPathComponent("fixtures/broken.1"))
    issues.append(ExpectedIssue(relativePath: "fixtures/broken.1", kind: "failed", reason: "Broken file symlink."))
    for (name, destination) in [("cycle-a", "cycle-b"), ("cycle-b", "cycle-a")] {
        try makeLink(destination, root.appendingPathComponent("fixtures/\(name)"))
        issues.append(ExpectedIssue(relativePath: "fixtures/\(name)", kind: "failed", reason: "Unresolvable symbolic-link cycle."))
    }
    try writeFixture(Data("Ordinary data carrying a misleading manual suffix.\n".utf8), root.appendingPathComponent("fixtures/diagnostics/not-a-manual.1"))
    issues.append(ExpectedIssue(relativePath: "fixtures/diagnostics/not-a-manual.1", kind: "unsupported", reason: "Filename is a candidate but content is not a supported manual."))
    try writeFixture(Data("not a gzip stream\n".utf8), root.appendingPathComponent("fixtures/diagnostics/corrupt.1.gz"))
    issues.append(ExpectedIssue(relativePath: "fixtures/diagnostics/corrupt.1.gz", kind: "failed", reason: "Candidate compression decoding must fail explicitly."))
    if let xz = ["/usr/bin/xz", "/opt/homebrew/bin/xz", "/usr/local/bin/xz"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        try writeFixture(compressed(xz, ["-c", base.path], root), root.appendingPathComponent("fixtures/diagnostics/unsupported.1.xz"))
        tools.append(xz)
        issues.append(ExpectedIssue(relativePath: "fixtures/diagnostics/unsupported.1.xz", kind: "unsupported", reason: "Valid xz container is recognized but is unsupported by the production decoder."))
    } else { unavailable.append("xz compression fixture unavailable: no existing xz executable was found; no dependency was installed.") }
    let protected = root.appendingPathComponent("fixtures/inaccessible")
    var state = stat()
    if lstat(protected.path, &state) == 0 {
        guard state.st_mode & S_IFMT == S_IFDIR, chmod(protected.path, 0o700) == 0 else { throw HarnessError.filesystem(protected.path, errno) }
    }
    try writeFixture(launchctl, protected.appendingPathComponent("unseen.1"))
    let permission = try inaccessibleState(protected)
    issues.append(ExpectedIssue(relativePath: "fixtures/inaccessible", kind: permission.0 ? "inaccessible" : "unverified", reason: permission.0 ? "chmod 000 prevents enumeration under the actual generator UID; its manual is intentionally outside expected discovered groups." : "This identity can enumerate chmod 000 directories; an inaccessible test was not established."))
    return FixtureManifest(manuals: manuals, issues: issues, compressionTools: Array(Set(tools)).sorted(), unavailableScenarios: unavailable,
                           inaccessibleVerified: permission.0, inaccessibleErrno: permission.1)
}
