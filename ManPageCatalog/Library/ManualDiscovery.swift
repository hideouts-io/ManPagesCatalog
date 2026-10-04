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
    var bytes = [UInt8](repeating: 0, count: min(65536, Int(metadata.st_size)))
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

enum ManualCompression: String {
    case gzip, compress, bzip2, xz, zstandard, lz4, lzip
}

/// Inspect container signatures so renamed compressed manuals are not missed by filename heuristics.
func manualCompression(_ bytes: Data) -> ManualCompression? {
    let signatures: [(ManualCompression, [UInt8])] = [
        (.gzip, [0x1f, 0x8b]), (.compress, [0x1f, 0x9d]), (.bzip2, [0x42, 0x5a, 0x68]),
        (.xz, [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]), (.zstandard, [0x28, 0xb5, 0x2f, 0xfd]),
        (.lz4, [0x04, 0x22, 0x4d, 0x18]), (.lzip, [0x4c, 0x5a, 0x49, 0x50])
    ]
    return signatures.first(where: { bytes.starts(with: $0.1) })?.0
}

func discoveredManual(file: URL, root: URL, state: ManualFileState, allowedNetworkRoots: [URL]) async throws -> ManualPage? {
    let filename = autoreleasepool { manualFilename(file) }
    // An empty regular file cannot contain a manual header or compression signature.
    if state.size == 0 {
        if filename != nil {
            throw DiscoveryAccessError(kind: .unsupported, message: "Candidate is empty and has no manual content.")
        }
        return nil
    }
    let prefix = try autoreleasepool { try manualPrefix(file) }
    let compression = manualCompression(prefix)
    let compressed = compression != nil || ["gz", "Z", "bz2"].contains(file.pathExtension)
    if compressed && ["tar", "cpio"].contains(file.deletingPathExtension().pathExtension) {
        throw DiscoveryAccessError(kind: .excluded, message: "Archive contents are not traversed. Extract documentation into a selected folder to scan it.")
    }
    if [.xz, .zstandard, .lz4, .lzip].contains(compression) || ["xz", "lzma", "zst", "lz", "lz4"].contains(file.pathExtension) {
        throw DiscoveryAccessError(kind: .unsupported, message: "Cannot inspect \(compression?.rawValue ?? file.pathExtension) compressed content with the current decoder. It may contain documentation; extract it explicitly and select that folder.")
    }
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

func discoveryDirectoryMetadata(_ value: stat) -> DiscoveryDirectoryMetadata {
    DiscoveryDirectoryMetadata(device: value.st_dev, inode: value.st_ino,
        modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
        changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
}

/// Permission and extended-attribute changes affect ctime without changing directory entries.
func sameDiscoveryDirectoryNamespace(current: DiscoveryDirectoryMetadata, saved: DiscoveryDirectoryMetadata) -> Bool {
    current.device == saved.device && current.inode == saved.inode &&
        current.modifiedSeconds == saved.modifiedSeconds && current.modifiedNanoseconds == saved.modifiedNanoseconds
}

/// Owns one native stream and its ordered fingerprint; no directory listing or seek cookie is retained.
final class DiscoveryDirectoryStream {
    let directory: URL
    let metadata: DiscoveryDirectoryMetadata
    private let allowedNetworkRoots: [URL]
    private var handle: UnsafeMutablePointer<DIR>?
    private var prefix = SHA256()

    init(directory: URL, expectedIdentity: String, allowedNetworkRoots: [URL]) throws {
        let resolved = directory.resolvingSymlinksInPath()
        let descriptor = open(resolved.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let failure = errno
            throw DiscoveryAccessError(kind: [EACCES, EPERM].contains(failure) ? .inaccessible : .failed, message: "Cannot open directory \(directory.path): \(String(cString: strerror(failure))) (errno \(failure)).")
        }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            let failure = errno
            guard Darwin.close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw DiscoveryAccessError(kind: .failed, message: "Cannot inspect opened directory \(directory.path): \(String(cString: strerror(failure))) (errno \(failure)).")
        }
        let opened = discoveryDirectoryMetadata(value)
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_flags & UInt32(SF_DATALESS) == 0, opened.identity == expectedIdentity else {
            guard Darwin.close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw DiscoveryAccessError(kind: .failed, message: "Directory \(directory.path) changed identity/type or became cloud-only before enumeration. Start a fresh scan to recheck it.")
        }
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else {
            let failure = errno
            guard Darwin.close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw DiscoveryAccessError(kind: .failed, message: "Cannot inspect the mounted filesystem for \(directory.path): \(String(cString: strerror(failure))) (errno \(failure)).")
        }
        // Darwin fdopendir materializes union mounts internally; do not silently lose the buffer bound.
        guard filesystem.f_flags & UInt32(MNT_UNION) == 0 else {
            guard Darwin.close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw DiscoveryAccessError(kind: .unsupported, message: "Union-mounted directory \(directory.path) is not streamed: the native runtime would materialize its complete listing. This subtree was not inspected.")
        }
        guard let stream = fdopendir(descriptor) else {
            let failure = errno
            guard Darwin.close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw DiscoveryAccessError(kind: .failed, message: "Cannot enumerate directory \(directory.path): \(String(cString: strerror(failure))) (errno \(failure)).")
        }
        self.directory = directory
        self.allowedNetworkRoots = allowedNetworkRoots
        metadata = opened
        handle = stream
    }

    // Normal completion closes explicitly and reports errors; unwinding an earlier failure still releases the descriptor.
    deinit { if let handle { closedir(handle) } }

    func close() throws {
        guard let stream = handle else { return }
        handle = nil
        guard closedir(stream) == 0 else {
            throw DiscoveryAccessError(kind: .failed, message: "Cannot close directory stream \(directory.path): \(String(cString: strerror(errno))) (errno \(errno)).")
        }
    }

    func nextName() throws -> String? {
        guard let handle else { throw ManualToolError(message: "Directory stream \(directory.path) is already closed.") }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(handle) else {
                let failure = errno
                guard failure == 0 else { throw DiscoveryAccessError(kind: .failed, message: "Directory enumeration failed at \(directory.path): \(String(cString: strerror(failure))) (errno \(failure)).") }
                return nil
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String? in
                guard length > 0, length < bytes.count else { return nil }
                return String(bytes: bytes.prefix(length), encoding: .utf8)
            }
            guard let name, !name.contains("/"), !name.contains("\0") else {
                throw DiscoveryAccessError(kind: .unsupported, message: "Directory \(directory.path) contains an invalid or non-UTF-8 entry name; remaining entries were not inspected.")
            }
            if name != "." && name != ".." { return name }
        }
    }

    /// Length-prefix UTF-8 names to distinguish ordered entries without per-entry digest formatting.
    func commit(_ name: String) {
        var length = UInt64(name.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { prefix.update(bufferPointer: $0) }
        name.withCString { bytes in
            prefix.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: name.utf8.count))
        }
    }

    var digest: String { prefix.finalize().map { String(format: "%02x", $0) }.joined() }

    func verifyUnchanged() throws {
        guard let handle else { throw ManualToolError(message: "Directory stream \(directory.path) is already closed.") }
        try requireDiscoveryVolume(url: directory, allowedNetworkRoots: allowedNetworkRoots)
        let bound = try materializedFileState(directory)
        guard bound.directory, bound.identity == metadata.identity else {
            throw DiscoveryAccessError(kind: .failed, message: "Directory path \(directory.path) no longer refers to the opened directory. Its measured coverage may be incomplete; start a fresh scan to recheck the changed path.")
        }
        var value = stat()
        guard fstat(dirfd(handle), &value) == 0 else { throw DiscoveryAccessError(kind: .failed, message: "Cannot recheck directory \(directory.path): \(String(cString: strerror(errno))) (errno \(errno)).") }
        guard sameDiscoveryDirectoryNamespace(current: discoveryDirectoryMetadata(value), saved: metadata) else {
            throw DiscoveryAccessError(kind: .failed, message: "Directory identity or entry modification time at \(directory.path) changed during enumeration. Its measured coverage may be incomplete; start a fresh scan to recheck it.")
        }
    }

    func restore(_ cursor: DiscoveryDirectoryCursor) throws {
        guard sameDiscoveryDirectoryNamespace(current: metadata, saved: cursor.metadata) else { throw ManualToolError(message: "Cannot resume changed directory \(directory.path): its opened identity or directory entry modification time differs. Start a fresh scan; retained manuals and the saved checkpoint are unchanged.") }
        for _ in 0..<cursor.consumedEntries {
            guard let name = try nextName() else { throw ManualToolError(message: "Cannot resume directory \(directory.path): its saved entry prefix is now shorter. Start a fresh scan; retained manuals and the saved checkpoint are unchanged.") }
            commit(name)
        }
        guard digest == cursor.prefixDigest else { throw ManualToolError(message: "Cannot resume directory \(directory.path): entry order or names changed since the checkpoint. Start a fresh scan; retained manuals and the saved checkpoint are unchanged.") }
        if let pending = cursor.pendingEntry {
            guard try nextName() == pending else { throw ManualToolError(message: "Cannot resume directory \(directory.path): its interrupted entry changed or moved in enumeration order. Start a fresh scan; retained manuals and the saved checkpoint are unchanged.") }
        }
        try verifyUnchanged()
    }
}

/// A bounded depth-first stream retains only active directories and one interrupted entry.
/// Resume replays and validates a stable prefix; already consumed file contents require a fresh scan to recheck.
func continueDiscovery(checkpoint: DiscoveryCheckpoint, previous: [ManualPage],
                       progress: @Sendable (DiscoveryProgress) async -> Void,
                       save: @Sendable (DiscoveryCheckpoint) async throws -> Void) async throws -> LibraryScan {
    var state = checkpoint
    var cached: [String: ManualPage] = [:]
    for page in previous { for location in page.locations { cached[location.source.path] = page.at(location) } }
    var segmentPeak = state.pendingCount
    var lastProgress = -Double.infinity
    var reportedFiles: Int = 0
    var lastSave = -Double.infinity
    discoveryRoots: for index in state.roots.indices {
        let root = state.roots[index].root
        var streams: [DiscoveryDirectoryStream] = []
        do {
            for cursor in state.roots[index].directoriesInProgress {
                try Task.checkCancellation()
                try requireDiscoveryVolume(url: cursor.directory, allowedNetworkRoots: state.plan.allowedNetworkRoots)
                let file = try materializedFileState(cursor.directory)
                let stream = try DiscoveryDirectoryStream(directory: cursor.directory, expectedIdentity: file.identity, allowedNetworkRoots: state.plan.allowedNetworkRoots)
                try stream.restore(cursor)
                streams.append(stream)
            }
        } catch is CancellationError {
            for stream in streams { try stream.close() }
            break discoveryRoots
        }
        while (!state.roots[index].pending.isEmpty || !streams.isEmpty), !Task.isCancelled {
            let url: URL
            if let pending = state.roots[index].pending.last { url = pending }
            else {
                let cursorIndex = state.roots[index].directoriesInProgress.count - 1
                let stream = streams[cursorIndex]
                if state.roots[index].directoriesInProgress[cursorIndex].pendingEntry == nil {
                    do {
                        guard let name = try autoreleasepool(invoking: { try stream.nextName() }) else {
                            try stream.verifyUnchanged()
                            try stream.close()
                            streams.removeLast()
                            state.roots[index].directoriesInProgress.removeLast()
                            continue
                        }
                        state.roots[index].directoriesInProgress[cursorIndex].pendingEntry = name
                        state.peakPending = max(state.peakPending ?? 0, state.pendingCount)
                        segmentPeak = max(segmentPeak, state.pendingCount)
                    } catch is CancellationError { break }
                    catch {
                        state.roots[index].issues.append(discoveryIssue(url: stream.directory, error: error))
                        try stream.close()
                        streams.removeLast()
                        state.roots[index].directoriesInProgress.removeLast()
                        continue
                    }
                }
                guard let name = state.roots[index].directoriesInProgress[cursorIndex].pendingEntry else { throw ManualToolError(message: "Directory traversal lost the pending entry for \(stream.directory.path).") }
                url = autoreleasepool { stream.directory.appendingPathComponent(name, isDirectory: false) }
            }
            var inspectedRegular = false
            var openedDirectory: DiscoveryDirectoryStream? = nil
            do {
                try Task.checkCancellation()
                // Foundation path/volume bridges create temporary objects on this long-lived worker.
                let file = try autoreleasepool {
                    try requireDiscoveryVolume(url: url, allowedNetworkRoots: state.plan.allowedNetworkRoots)
                    return try materializedFileState(url)
                }
                if file.directory {
                    if let first = state.visited[file.identity] {
                        state.roots[index].issues.append(DiscoveryIssue(path: url.path, kind: .excluded, reason: "Directory already traversed at \(first); avoids duplicate traversal and link cycles."))
                    } else if streams.count >= maximumDiscoveryDirectoryDepth {
                        state.roots[index].issues.append(DiscoveryIssue(path: url.path, kind: .unsupported, reason: "Directory depth exceeds the bounded \(maximumDiscoveryDirectoryDepth)-stream traversal limit; this subtree was not inspected."))
                    } else {
                        openedDirectory = try DiscoveryDirectoryStream(directory: url, expectedIdentity: file.identity, allowedNetworkRoots: state.plan.allowedNetworkRoots)
                        state.visited[file.identity] = url.path
                        state.roots[index].directories += 1
                    }
                } else {
                    if file.regular {
                        inspectedRegular = true
                        let page: ManualPage?
                        if let old = cached[url.path], old.problem == nil || old.indexed,
                           old.locations.first(where: { $0.source == url })?.stamp == "direct:" + file.stamp {
                            var reused = old
                            reused.locations = [ManualLocation(source: url, root: root, name: old.name, section: old.section, language: old.language, stamp: "direct:" + file.stamp)]
                            page = reused.at(reused.locations[0])
                        } else {
                            page = try await discoveredManual(file: url, root: root, state: file, allowedNetworkRoots: state.plan.allowedNetworkRoots)
                        }
                        if let page {
                            state.pages.append(page)
                            state.roots[index].manuals += 1
                            if let problem = page.problem, !page.indexed { state.roots[index].issues.append(DiscoveryIssue(path: url.path, kind: .unsupported, reason: problem)) }
                        }
                    } else {
                        state.roots[index].issues.append(DiscoveryIssue(path: url.path, kind: .excluded, reason: "Special filesystem entry; sockets, devices and pipes are never read."))
                    }
                }
            } catch is CancellationError { break }
            catch {
                state.roots[index].issues.append(discoveryIssue(url: url, error: error))
            }
            if !state.roots[index].pending.isEmpty { state.roots[index].pending.removeLast() }
            else {
                let cursorIndex = state.roots[index].directoriesInProgress.count - 1
                guard let name = state.roots[index].directoriesInProgress[cursorIndex].pendingEntry else { throw ManualToolError(message: "Directory traversal lost the committed entry at \(url.path).") }
                streams[cursorIndex].commit(name)
                state.roots[index].directoriesInProgress[cursorIndex].consumedEntries += 1
                state.roots[index].directoriesInProgress[cursorIndex].pendingEntry = nil
            }
            if let stream = openedDirectory {
                state.roots[index].directoriesInProgress.append(DiscoveryDirectoryCursor(directory: url, metadata: stream.metadata,
                    consumedEntries: 0, prefixDigest: stream.digest, pendingEntry: nil))
                streams.append(stream)
            }
            if inspectedRegular { state.roots[index].files += 1 }
            state.peakPending = max(state.peakPending ?? 0, state.pendingCount)
            segmentPeak = max(segmentPeak, state.pendingCount)
            let now = ProcessInfo.processInfo.systemUptime
            let files = state.roots.reduce(0) { $0 + $1.files }
            if now - lastProgress > 0.15 || (reportedFiles == 0 && files > 0) {
                await progress(DiscoveryProgress(path: url.path, directories: state.roots.reduce(0) { $0 + $1.directories },
                                                  files: state.roots.reduce(0) { $0 + $1.files }, manuals: state.pages.count,
                                                  pending: state.pendingCount, peakPending: segmentPeak))
                lastProgress = now
                reportedFiles = files
            }
            if now - lastSave > 5 {
                for (cursorIndex, stream) in streams.enumerated() { state.roots[index].directoriesInProgress[cursorIndex].prefixDigest = stream.digest }
                state.updated = Date()
                try await save(state)
                lastSave = ProcessInfo.processInfo.systemUptime
            }
        }
        for (cursorIndex, stream) in streams.enumerated() {
            state.roots[index].directoriesInProgress[cursorIndex].prefixDigest = stream.digest
            try stream.close()
        }
        if Task.isCancelled { break }
    }
    state.updated = Date()
    try await save(state)
    await progress(DiscoveryProgress(path: "Discovery stopped", directories: state.roots.reduce(0) { $0 + $1.directories },
        files: state.roots.reduce(0) { $0 + $1.files }, manuals: state.pages.count, pending: state.pendingCount,
        peakPending: segmentPeak))
    return state.snapshot
}

func discoverLibrary(plan: DiscoveryPlan, previous: [ManualPage], progress: @Sendable (DiscoveryProgress) async -> Void) async throws -> LibraryScan {
    try await continueDiscovery(checkpoint: newDiscoveryCheckpoint(plan: plan, title: "Discovery"), previous: previous, progress: progress, save: { _ in })
}

func scanLibrary(roots: [URL]) async throws -> LibraryScan {
    try await discoverLibrary(plan: DiscoveryPlan(roots: roots, allowedNetworkRoots: [], exclusions: []), previous: [], progress: { _ in })
}
