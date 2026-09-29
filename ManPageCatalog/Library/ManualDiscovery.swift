import Foundation
import CryptoKit
import Darwin

struct ManualFileState: Sendable {
    let directory: Bool
    let regular: Bool
    let identity: String
    let stamp: String
    let size: Int64
}

struct DiscoveryAccessError: LocalizedError {
    let kind: CoverageKind
    let message: String
    var errorDescription: String? { message }
}

/// Metadata reads never request cloud hydration. Check resolved targets as well as directory entries.
func materializedFileState(_ url: URL) throws -> ManualFileState {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
        let code = errno
        throw DiscoveryAccessError(kind: [EACCES, EPERM].contains(code) ? .inaccessible : .failed,
                                   message: "Cannot inspect \(url.path): \(String(cString: strerror(code))) (errno \(code)).")
    }
    if value.st_flags & UInt32(SF_DATALESS) != 0 || url.pathExtension == "icloud" {
        throw DiscoveryAccessError(kind: .excluded, message: "Cloud-only placeholder; download explicitly in Finder before scanning again.")
    }
    if value.st_mode & S_IFMT == S_IFLNK {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path != url.path else { throw DiscoveryAccessError(kind: .failed, message: "Unresolved symbolic link or link cycle.") }
        return try materializedFileState(resolved)
    }
    let stamp = "\(url.path):\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    return ManualFileState(directory: value.st_mode & S_IFMT == S_IFDIR, regular: value.st_mode & S_IFMT == S_IFREG,
                           identity: "\(value.st_dev):\(value.st_ino)", stamp: stamp, size: value.st_size)
}

func requireMaterializedManual(_ url: URL) throws {
    let state = try materializedFileState(url)
    guard state.regular else { throw DiscoveryAccessError(kind: .unsupported, message: "Manual source is not a regular file.") }
    guard state.size <= 64 * 1024 * 1024 else {
        throw DiscoveryAccessError(kind: .unsupported, message: "Manual source exceeds the 64 MiB input limit.")
    }
}

func requireDiscoveryVolume(url: URL, allowedNetworkRoots: [URL]) throws {
    let resolved = url.resolvingSymlinksInPath()
    if allowedNetworkRoots.contains(where: { pathContains(root: $0.resolvingSymlinksInPath().path, path: resolved.path) }) { return }
    let values = try resolved.resourceValues(forKeys: [.volumeIsLocalKey])
    guard values.volumeIsLocal == true else {
        throw DiscoveryAccessError(kind: .excluded, message: "Network or unidentified volume; select this folder explicitly to authorize scanning it.")
    }
}

func discoveryIssue(url: URL, error: Error) -> DiscoveryIssue {
    let kind: CoverageKind
    if let access = error as? DiscoveryAccessError { kind = access.kind }
    else {
        let error = error as NSError
        let permission = error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)
        kind = permission || (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError) ? .inaccessible : .failed
    }
    return DiscoveryIssue(path: url.path, kind: kind, reason: error.localizedDescription)
}

/// Read a bounded prefix from an already materialized regular file; never block on a special file.
func manualPrefix(_ url: URL) throws -> Data {
    let descriptor = open(url.resolvingSymlinksInPath().path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
        close(descriptor)
        throw DiscoveryAccessError(kind: .excluded, message: "File changed type or became cloud-only before reading.")
    }
    var bytes = [UInt8](repeating: 0, count: 65536)
    let count = read(descriptor, &bytes, bytes.count)
    let failure = errno
    guard close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
    return Data(bytes.prefix(count))
}

func roffHeader(_ data: Data) -> (name: String, section: String)? {
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
    guard let first = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
          first.hasPrefix(".") || first.hasPrefix("'") || first.hasPrefix("\\\"") else { return nil }
    guard let range = text.range(of: #"(?m)^[.'][ \t]*(?:TH|Dt|HS)[ \t]+[^\r\n]+"#, options: .regularExpression) else { return nil }
    let fields = String(text[range]).matches(of: /"([^"]*)"|([^\s"]+)/).map { String($0.1 ?? $0.2 ?? "") }
    guard fields.count >= 2, !fields[1].isEmpty else { return nil }
    let candidate = fields.count > 2 ? fields[2].replacingOccurrences(of: "\\&", with: "").lowercased() : ""
    let tclSections = ["cmds": "1", "lib": "3", "ncmds": "n", "tcl": "n", "tk": "n", "tclc": "3", "tkc": "3", "tclcmds": "1", "tkcmds": "1", "iwid": "1"]
    let declared = fields[0] == ".HS" && text.contains(".de HS") ? tclSections[candidate] ?? candidate : candidate
    let section = declared.range(of: #"^(?:[0-9][A-Za-z0-9]*|[nlpo]|tcl)$"#, options: .regularExpression) != nil ? declared : ""
    return (fields[1], section)
}

func manualFilename(_ file: URL) -> (name: String, section: String)? {
    let plain = ["gz", "Z", "bz2", "xz", "lzma", "zst", "lz", "lz4"].contains(file.pathExtension) ? file.deletingPathExtension() : file
    let section = plain.pathExtension
    guard section.range(of: #"^(?:[0-9][A-Za-z0-9]*|[nlpo]|tcl)$"#, options: .regularExpression) != nil else { return nil }
    return (plain.deletingPathExtension().lastPathComponent, section)
}

func manualLanguage(_ file: URL) -> String {
    let parts = file.pathComponents
    guard let index = parts.lastIndex(where: { $0.range(of: #"^(?:man|cat)(?:[0-9][A-Za-z0-9]*|[nlpo]|tcl)$"#, options: .regularExpression) != nil }), index > 0 else { return "unspecified" }
    let locale = parts[index - 1]
    guard locale.range(of: #"^[a-z]{2,3}(?:[_-][A-Z]{2})?(?:\.[A-Za-z0-9-]+)?(?:@[A-Za-z]+)?$"#, options: .regularExpression) != nil,
          locale != "man" else { return "unspecified" }
    return locale
}

func discoveredManual(file: URL, root: URL, state: ManualFileState, allowedNetworkRoots: [URL]) async throws -> ManualPage? {
    let filename = manualFilename(file)
    let compressed = ["gz", "Z", "bz2"].contains(file.pathExtension)
    if compressed && ["tar", "cpio"].contains(file.deletingPathExtension().pathExtension) {
        throw DiscoveryAccessError(kind: .excluded, message: "Archive contents are not traversed. Extract documentation into a selected folder to scan it.")
    }
    if ["xz", "lzma", "zst", "lz", "lz4"].contains(file.pathExtension) {
        guard filename != nil || ["man", "mdoc", "roff"].contains(file.deletingPathExtension().pathExtension) else { return nil }
        throw DiscoveryAccessError(kind: .unsupported, message: "\(file.pathExtension) compression is not supported by the system renderer integration.")
    }
    let prefix = try manualPrefix(file)
    let prefixText = String(decoding: prefix, as: UTF8.self)
    let alias = prefixText.range(of: #"(?m)^\.so[ \t]+"#, options: .regularExpression) != nil
    guard filename != nil || compressed || roffHeader(prefix) != nil || alias else { return nil }
    let input: ManualInput
    let problem: String?
    do {
        input = try await validatedManualInput(source: file) { target in
            try requireDiscoveryVolume(url: target, allowedNetworkRoots: allowedNetworkRoots)
            try requireMaterializedManual(target)
        }
        problem = nil
    } catch let error as DiscoveryAccessError where error.kind == .unsupported && roffHeader(prefix) != nil {
        // A validated header establishes discovery even when safe rendering is unsupported.
        // Keep the name searchable and expose the failure; never index unverified included content.
        input = ManualInput(bytes: try await manualBytes(source: file), directory: file.deletingLastPathComponent(), sourceChain: [file])
        problem = error.localizedDescription
    }
    guard let header = roffHeader(input.bytes) else {
        throw DiscoveryAccessError(kind: .unsupported, message: "Candidate has no supported .TH or .Dt manual header. Preformatted cat pages and non-manual files are not indexed.")
    }
    let metadata = filename ?? (name: header.name.lowercased(), section: header.section)
    guard !metadata.section.isEmpty else {
        throw DiscoveryAccessError(kind: .unsupported, message: "Manual header has no usable section and the filename supplies none.")
    }
    // Unresolved includes cannot establish cross-location content equivalence.
    let identityBytes = problem == nil ? input.bytes : input.bytes + Data(file.path.utf8)
    let digest = SHA256.hash(data: identityBytes).map { String(format: "%02x", $0) }.joined()
    let language = manualLanguage(file)
    // Aliases are re-resolved on every scan: their target can change without changing the alias file.
    let indirect = input.sourceChain.count > 1
    let location = ManualLocation(source: file, root: root, name: metadata.name, section: metadata.section,
                                  language: language, stamp: (indirect ? "alias:" : "direct:") + state.stamp)
    return ManualPage(name: metadata.name, section: metadata.section, source: file, root: root, fingerprint: digest,
                      language: language, locations: [location], description: "", indexed: false, problem: problem)
}

/// Recurses hidden folders and packages; inode identity prevents directory cycles and overlapping-root work.
/// Cancellation returns coverage but callers must not replace the previous catalog with partial discoveries.
func discoverLibrary(plan: DiscoveryPlan, previous: [ManualPage], progress: @Sendable (DiscoveryProgress) async -> Void) async -> LibraryScan {
    var pages: [ManualPage] = []
    var coverage: [SourceCoverage] = []
    var visited: [String: String] = [:]
    var cached: [String: ManualPage] = [:]
    for page in previous { for location in page.locations { cached[location.source.path] = page.at(location) } }
    var totalDirectories = 0, totalFiles = 0
    var lastProgress = Date.distantPast
    for root in plan.roots {
        var stack = [root]
        var issues: [DiscoveryIssue] = []
        let start = pages.count, startDirectories = totalDirectories, startFiles = totalFiles
        while let url = stack.popLast(), !Task.isCancelled {
            do {
                try requireDiscoveryVolume(url: url, allowedNetworkRoots: plan.allowedNetworkRoots)
                let state = try materializedFileState(url)
                if state.directory {
                    if let first = visited[state.identity] {
                        issues.append(DiscoveryIssue(path: url.path, kind: .excluded, reason: "Directory already traversed at \(first); avoids duplicate traversal and link cycles."))
                        continue
                    }
                    // Mark only after successful enumeration so an inaccessible alias cannot hide a usable path.
                    let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                    visited[state.identity] = url.path
                    totalDirectories += 1
                    stack += children.map { url.appendingPathComponent($0.lastPathComponent) }.sorted { $0.path > $1.path }
                } else if state.regular {
                    totalFiles += 1
                    if let old = cached[url.path], old.problem == nil || old.indexed, old.locations.first(where: { $0.source == url })?.stamp == "direct:" + state.stamp {
                        var reused = old
                        reused.locations = [ManualLocation(source: url, root: root, name: old.name, section: old.section, language: old.language, stamp: "direct:" + state.stamp)]
                        pages.append(reused.at(reused.locations[0]))
                    } else if let page = try await discoveredManual(file: url, root: root, state: state, allowedNetworkRoots: plan.allowedNetworkRoots) {
                        pages.append(page)
                        if let problem = page.problem { issues.append(DiscoveryIssue(path: url.path, kind: .unsupported, reason: problem)) }
                    }
                } else {
                    issues.append(DiscoveryIssue(path: url.path, kind: .excluded, reason: "Special filesystem entry; sockets, devices and pipes are never read."))
                }
            } catch is CancellationError { break }
            catch { issues.append(discoveryIssue(url: url, error: error)) }
            if Date().timeIntervalSince(lastProgress) > 0.15 {
                await progress(DiscoveryProgress(path: url.path, directories: totalDirectories, files: totalFiles, manuals: pages.count))
                lastProgress = Date()
            }
        }
        coverage.append(SourceCoverage(root: root, count: pages.count - start, directories: totalDirectories - startDirectories,
                                       files: totalFiles - startFiles, completed: !Task.isCancelled && stack.isEmpty, issues: issues))
        if Task.isCancelled { break }
    }
    let attempted = Set(coverage.map { $0.root.path })
    for root in plan.roots where !attempted.contains(root.path) {
        coverage.append(SourceCoverage(root: root, count: 0, directories: 0, files: 0, completed: false,
                                       issues: [DiscoveryIssue(path: root.path, kind: .excluded, reason: "Not scanned: operation cancelled before reaching this root.")]))
    }
    for issue in plan.exclusions {
        coverage.append(SourceCoverage(root: URL(fileURLWithPath: issue.path), count: 0, directories: 0, files: 0, completed: false, issues: [issue]))
    }
    return LibraryScan(pages: groupedManuals(pages), coverage: coverage, cancelled: Task.isCancelled)
}

func scanLibrary(roots: [URL]) async throws -> LibraryScan {
    await discoverLibrary(plan: DiscoveryPlan(roots: roots, allowedNetworkRoots: [], exclusions: []), previous: [], progress: { _ in })
}
