import Foundation
import PDFKit
import CryptoKit
import Darwin
import Compression

struct ManualSource: Equatable, Sendable {
    let url: URL
    let name: String
    let section: String
}

struct CatalogProgress: Sendable {
    let completed: Int
    let total: Int
}

/// Uses the system's configured manual roots; an explicit MANPATH permits a bounded corpus.
func manualRoots(environment: [String: String]) async throws -> [URL] {
    let path: String
    if let configured = environment["MANPATH"], !configured.isEmpty, !configured.components(separatedBy: ":").contains("") {
        path = configured
    } else {
        let data = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/manpath"), arguments: [],
                                           directory: URL(fileURLWithPath: "/"), input: nil)
        path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let roots = path.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    guard !roots.isEmpty else { throw ManualToolError(message: "No manual directories were returned by manpath. Check MANPATH or install manual pages.") }
    return roots
}

func discoverManuals(roots: [URL]) throws -> [ManualSource] {
    try discoverManuals(roots: roots, access: ManualSourceAccess(generation: UUID(), allowedNetworkRoots: []))
}

func discoverManuals(roots: [URL], access: ManualSourceAccess) throws -> [ManualSource] {
    var sources: [ManualSource] = []
    var seen = Set<String>()
    for root in roots {
        try access.check()
        try requireDiscoveryVolume(url: root, allowedNetworkRoots: access.allowedNetworkRoots)
        let sections = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for directory in sections.sorted(by: { $0.path < $1.path }) where directory.lastPathComponent.hasPrefix("man") {
            try access.check()
            try requireDiscoveryVolume(url: directory, allowedNetworkRoots: access.allowedNetworkRoots)
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let directorySection = String(directory.lastPathComponent.dropFirst(3))
            guard !directorySection.isEmpty else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            for file in files.sorted(by: { $0.path < $1.path }) {
                try access.check()
                try requireDiscoveryVolume(url: file, allowedNetworkRoots: access.allowedNetworkRoots)
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let plain = ["gz", "Z", "bz2", "xz"].contains(file.pathExtension) ? file.deletingPathExtension() : file
                let section = plain.pathExtension
                guard section.hasPrefix(directorySection) || directorySection.hasPrefix(section),
                      let first = section.first, first.isNumber || first == "n" else { continue }
                let name = plain.deletingPathExtension().lastPathComponent
                let key = "\(name.lowercased()).\(section)"
                if seen.insert(key).inserted { sources.append(ManualSource(url: file, name: name, section: section)) }
            }
        }
    }
    return sources
}

func manualBytes(source: URL) async throws -> Data {
    try await checkedManualBytes(source: source, validate: { target in
        try requireDiscoveryVolume(url: target, allowedNetworkRoots: [])
        try requireMaterializedManual(target)
    })
}

struct ManualInput: Sendable {
    let bytes: Data
    let directory: URL
    let sourceChain: [URL]
    let dependencies: [ManualSourceDependency]

    init(bytes: Data, directory: URL, sourceChain: [URL]) {
        self.init(bytes: bytes, directory: directory, sourceChain: sourceChain, dependencies: [])
    }

    init(bytes: Data, directory: URL, sourceChain: [URL], dependencies: [ManualSourceDependency]) {
        self.bytes = bytes; self.directory = directory; self.sourceChain = sourceChain; self.dependencies = dependencies
    }
}

/// Legacy paths have no historical scan boundary and never carry serialized network consent.
func manualInput(source: URL) async throws -> ManualInput {
    try await sourceManualInput(source: source, scope: .legacy,
                                access: ManualSourceAccess(generation: UUID(), allowedNetworkRoots: []))
}

func sourceManualInput(source: URL, scope: ManualSourceScope, access: ManualSourceAccess) async throws -> ManualInput {
    try await sourceManualInput(source: source, scopes: [scope], access: access)
}

private func sourceManualInput(source: URL, scopes: [ManualSourceScope], access: ManualSourceAccess) async throws -> ManualInput {
    try access.check()
    let restrictions = try scopes.map { scope in
        ManualSourceRestriction(exclusions: try manualScopeExclusions(scope), roots: scope.traversalRoots.map { roots in
            zip(roots, scope.resolvedTraversalRoots ?? []).map { DiscoveryTraversalRoot(path: $0.path, resolvedPath: $1.path) }
        })
    }
    return try await validatedManualInput(source: source, validate: { target in
        try access.check()
        for restriction in restrictions {
            try requireDiscoveryScope(url: target, allowedNetworkRoots: access.allowedNetworkRoots,
                                      exclusions: restriction.exclusions, traversalRoots: restriction.roots)
        }
        try requireMaterializedManual(target)
    }, validateCandidate: { candidate in
        try access.check()
        try requireManualCandidateVolume(url: candidate, allowedNetworkRoots: access.allowedNetworkRoots)
        for restriction in restrictions {
            let resolved = try requireDiscoveryPathBoundary(url: candidate, exclusions: restriction.exclusions, traversalRoots: restriction.roots)
            try requireManualCandidateVolume(url: resolved, allowedNetworkRoots: access.allowedNetworkRoots)
        }
    })
}

private struct ManualSourceRestriction: Sendable {
    let exclusions: [DiscoveryExcludedPath]
    let roots: [DiscoveryTraversalRoot]?
}

/// Reacquire the chosen location, not an arbitrary duplicate, and reject changed dependency identity.
func manualInput(page: ManualPage, access: ManualSourceAccess) async throws -> ManualInput {
    try await restrictedManualInput(page: page, scope: .legacy, access: access)
}

/// Additional runtime restrictions can only narrow the selected location's persisted policy.
func restrictedManualInput(page: ManualPage, scope: ManualSourceScope, access: ManualSourceAccess) async throws -> ManualInput {
    guard let location = page.locations.first(where: { $0.source == page.source && $0.root == page.root && $0.name == page.name }) else {
        throw ManualToolError(message: "The selected manual has no matching source location. Rescan before opening it.")
    }
    if let provenance = location.provenance { try validateManualSourceProvenance(provenance, source: location.source) }
    let input = try await sourceManualInput(source: page.source, scopes: [location.provenance?.scope ?? .legacy, scope], access: access)
    guard manualContentDigest(input.bytes) == page.fingerprint,
          location.provenance.map({ $0.dependencies == input.dependencies }) ?? true else {
        throw ManualToolError(message: "Manual source or include provenance changed after discovery: \(page.source.path). Run a scan to discover its current version before reading, indexing or exporting.")
    }
    return input
}

func manualScopeExclusions(_ scope: ManualSourceScope) throws -> [DiscoveryExcludedPath] {
    let paths = zip(scope.traversalExclusions, scope.resolvedTraversalExclusions).map {
        DiscoveryExcludedPath(issue: $0, resolvedPath: $1.path)
    }
    return paths + (try discoveryExcludedMountedPaths(volumes: scope.excludedMountedVolumes))
}

func manualContentDigest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// Open once without following a replaced final link; bound raw reads and decode that same snapshot.
func checkedManualBytes(source: URL, validate: @Sendable (URL) throws -> Void) async throws -> Data {
    try validate(source)
    let before = try materializedFileState(source)
    let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        let code = errno
        throw DiscoveryAccessError(kind: [EACCES, EPERM].contains(code) ? .inaccessible : .failed,
            message: "Cannot open manual source \(source.path): \(String(cString: strerror(code))) (errno \(code)).")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let bytes: Data
    do {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_flags & UInt32(SF_DATALESS) == 0, metadata.st_size <= 64 * 1024 * 1024,
              before.identity == "\(metadata.st_dev):\(metadata.st_ino)" else {
            throw ManualToolError(message: "Manual source changed or is not a materialized regular file: \(source.path). Retry discovery.")
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else {
            let code = errno
            throw ManualToolError(message: "Cannot validate the opened manual source path \(source.path): \(String(cString: strerror(code))) (errno \(code)).")
        }
        try validate(URL(fileURLWithPath: String(cString: path)))
        var raw = Data()
        while true {
            try Task.checkCancellation()
            try validate(source)
            guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            guard raw.count <= 64 * 1024 * 1024 - chunk.count else {
                throw DiscoveryAccessError(kind: .unsupported, message: "Manual source exceeds the 64 MiB input limit: \(source.path).")
            }
            raw.append(chunk)
        }
        guard try materializedFileState(source).stamp == before.stamp else {
            throw ManualToolError(message: "Manual source changed while reading: \(source.path). Retry discovery.")
        }
        bytes = raw
    } catch {
        do { try handle.close() }
        catch let cleanup { throw ManualProcessCleanupError(cause: error, failures: ["Cannot close manual source: \(cleanup.localizedDescription)"]) }
        throw error
    }
    try handle.close()
    let compression = manualCompression(bytes)
    if compression == .xz || compression == nil && source.pathExtension == "xz" {
        return try decodeXZManual(bytes: bytes, source: source)
    }
    if let compression, ![.gzip, .compress, .bzip2].contains(compression) {
        throw ManualToolError(message: "Unsupported \(compression.rawValue) compressed manual: \(source.path). Extract it explicitly before opening.")
    }
    if [.gzip, .compress, .bzip2].contains(compression) || ["gz", "Z", "bz2"].contains(source.pathExtension) {
        return try await runManualTool(executable: URL(fileURLWithPath: compression == .bzip2 || compression == nil && source.pathExtension == "bz2" ? "/usr/bin/bzip2" : "/usr/bin/gzip"),
                                       arguments: ["-dc"], directory: URL(fileURLWithPath: "/"), input: bytes)
    }
    if source.pathExtension == "lzma" {
        throw ManualToolError(message: "Unsupported lzma compressed manual: \(source.path). Only single-stream XZ containers are supported by the native decoder.")
    }
    return bytes
}

struct ManualDecompressionCleanupError: LocalizedError {
    let cause: Error?
    let source: URL
    let status: Int32

    var errorDescription: String? {
        let cleanup = "Cannot destroy the XZ decoder for \(source.path) (status \(status))."
        return cause.map { "\($0.localizedDescription) \(cleanup)" } ?? cleanup
    }
}

/// Apple supports LZMA2 in XZ; require one complete container and retain no partial plaintext.
/// Output and between-call runtime are bounded; the API exposes no dictionary-memory limit or in-call cancellation.
func decodeXZManual(bytes: Data, source: URL) throws -> Data {
    try Task.checkCancellation()
    guard bytes.count <= 64 * 1024 * 1024 else {
        throw ManualToolError(message: "XZ manual exceeds the 64 MiB compressed input limit: \(source.path).")
    }
    guard manualCompression(bytes) == .xz else {
        throw ManualToolError(message: "Invalid XZ manual header: \(source.path). Expected an XZ container; .lzma-alone and raw LZMA are unsupported.")
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    return try bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        guard let sourceBytes = input.bindMemory(to: UInt8.self).baseAddress else {
            throw ManualToolError(message: "XZ decompression received no input bytes: \(source.path).")
        }
        let capacity = 65_536
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        var stream = compression_stream(dst_ptr: destination, dst_size: capacity,
                                        src_ptr: sourceBytes, src_size: input.count, state: nil)
        let initialized = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
        guard initialized == COMPRESSION_STATUS_OK else {
            throw ManualToolError(message: "Cannot initialize XZ decompression for \(source.path) (status \(initialized.rawValue)).")
        }
        stream.src_ptr = sourceBytes
        stream.src_size = input.count
        let decoded: Data
        do {
            decoded = try decodedXZStream(stream: &stream, source: source, destination: destination,
                                         capacity: capacity, deadline: deadline)
        } catch {
            let cleanup = compression_stream_destroy(&stream)
            if cleanup != COMPRESSION_STATUS_OK {
                throw ManualDecompressionCleanupError(cause: error, source: source, status: cleanup.rawValue)
            }
            throw error
        }
        let cleanup = compression_stream_destroy(&stream)
        guard cleanup == COMPRESSION_STATUS_OK else {
            throw ManualDecompressionCleanupError(cause: nil, source: source, status: cleanup.rawValue)
        }
        try Task.checkCancellation()
        return decoded
    }
}

private func decodedXZStream(stream: inout compression_stream, source: URL, destination: UnsafeMutablePointer<UInt8>,
                             capacity: Int, deadline: ContinuousClock.Instant) throws -> Data {
    var decoded = Data()
    while true {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ManualToolError(message: "XZ decompression exceeded the 30-second timeout: \(source.path).")
        }
        let remaining = stream.src_size
        stream.dst_ptr = destination
        stream.dst_size = capacity
        let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ManualToolError(message: "XZ decompression exceeded the 30-second timeout: \(source.path).")
        }
        guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
            throw ManualToolError(message: "XZ decompression failed for \(source.path) (status \(status.rawValue)). The container is corrupt, truncated or unsupported.")
        }
        let produced = capacity - stream.dst_size
        guard produced <= 64 * 1024 * 1024 - decoded.count else {
            throw ManualToolError(message: "XZ decompression exceeded the 64 MiB decoded output limit: \(source.path).")
        }
        decoded.append(destination, count: produced)
        if status == COMPRESSION_STATUS_END {
            guard stream.src_size == 0 else {
                throw ManualToolError(message: "XZ manual has concatenated streams, padding or trailing data (\(stream.src_size) unconsumed bytes): \(source.path). Only one complete XZ stream is supported.")
            }
            return decoded
        }
        guard stream.src_size < remaining || produced > 0 else {
            throw ManualToolError(message: "XZ decompression made no progress before reaching a complete stream: \(source.path). The container is truncated or unsupported.")
        }
    }
}

func validatedManualInput(source: URL, validate: @Sendable (URL) throws -> Void) async throws -> ManualInput {
    try await validatedManualInput(source: source, validate: validate, validateCandidate: { _ in })
}

func validatedManualInput(source: URL, validate: @Sendable (URL) throws -> Void,
                          validateCandidate: @Sendable (URL) throws -> Void) async throws -> ManualInput {
    let fragment = try await resolveManualFragment(source: source, parent: nil, line: nil, active: [], dependencies: [],
        decodedSize: 0, validate: validate, validateCandidate: validateCandidate)
    if fragment.embedded, let unsupported = fragment.ambiguous.first {
        throw DiscoveryAccessError(kind: .unsupported, message: "Embedded roff includes require unconditional static markup; \(unsupported). Conditional, macro-generated and .mso includes are unsupported.")
    }
    return ManualInput(bytes: fragment.bytes, directory: source.deletingLastPathComponent().deletingLastPathComponent(),
                       sourceChain: fragment.dependencies.map(\.resolved), dependencies: fragment.dependencies)
}

private struct ManualResolvedFragment {
    let bytes: Data
    let dependencies: [ManualSourceDependency]
    let decodedSize: Int
    let embedded: Bool
    let ambiguous: [String]
}

/// This is a static inclusion grammar, not a roff interpreter. General markup remains mandoc's job.
private let staticIncludeRequests: Set<String> = ["TH", "SH", "SS", "PP", "P", "LP", "PD", "TP", "IP", "HP", "br", "sp", "nf", "fi", "RS", "RE", "ad", "na", "nh", "hy", "B", "I", "BR", "BI", "IB", "IR", "RB", "RI", "SM", "SB", "so", "Dd", "Dt", "Os", "Sh", "Ss", "Pp", "Nm", "Nd", "Fl", "Ar", "Pa", "Em", "Sy", "Li", "Cm", "Ic", "Xr", "Sx", "Bl", "El", "It", "Bd", "Ed", "D1", "Dl", "Op", "Oo", "Oc", "Bq", "Dq", "Sq", "Ql", "Aq", "Pq", "Lk", "Mt", "An", "Fn", "Ft", "Fa", "Fo", "Fc", "In", "Vt", "Va", "Er", "Ev", "No", "Ns", "Pf", "Ap", "Ta"]
private let staticIncludeEscapes: Set<UInt8> = Set("&-\"f(e ~%0|^:cud".utf8)

private func ambiguousIncludeMarkup(_ line: String) -> Bool {
    if line.contains("\r") || line.contains("\0") || line.hasSuffix("\\") || line.contains("\\#") { return true }
    if line.hasPrefix(".\\\"") || line.hasPrefix("'\\\"") { return false }
    if line.hasPrefix(".") || line.hasPrefix("'") {
        let request = String(line.dropFirst().prefix(while: { $0 != " " && $0 != "\t" }))
        if !staticIncludeRequests.contains(request) { return true }
    }
    // Restrict evaluation-changing escapes in an included graph, including undefined expansions.
    var characters = line.utf8.makeIterator()
    while let character = characters.next() {
        if character == 92 {
            guard let escaped = characters.next(), staticIncludeEscapes.contains(escaped) else { return true }
        }
    }
    return false
}

private func literalManualInclude(_ line: String) throws -> String? {
    guard line.hasPrefix(".so ") || line.hasPrefix(".so\t") else { return nil }
    let target = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    guard target.utf8.count < Int(MAXPATHLEN) else {
        throw DiscoveryAccessError(kind: .unsupported, message: "Manual .so target exceeds the \(Int(MAXPATHLEN) - 1)-byte filesystem path limit.")
    }
    guard !target.isEmpty, target.range(of: #"^[A-Za-z0-9_./+@%=-]+$"#, options: .regularExpression) != nil else {
        throw DiscoveryAccessError(kind: .unsupported, message: "Manual .so target must be a literal path without roff escapes, quotes or whitespace: \(target.prefix(160)).")
    }
    return target
}

private func manualIncludeTarget(target: String, source: URL, validateCandidate: @Sendable (URL) throws -> Void) throws -> URL {
    let directory = source.deletingLastPathComponent()
    let candidates = target.hasPrefix("/") ? [URL(fileURLWithPath: target)] :
        [directory.deletingLastPathComponent().appendingPathComponent(target), directory.appendingPathComponent(target)]
    var rejected: Error?
    for candidate in candidates.flatMap({ [$0, $0.appendingPathExtension("gz"), $0.appendingPathExtension("bz2"), $0.appendingPathExtension("Z"), $0.appendingPathExtension("xz")] }) {
        do { try validateCandidate(candidate) }
        catch { if rejected == nil { rejected = error }; continue }
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    if let rejected { throw rejected }
    throw ManualToolError(message: "Manual include \(source.path) refers to missing target \(target). Restore its documentation package.")
}

private func resolveManualFragment(source: URL, parent: Int?, line: Int?, active: [String],
    dependencies: [ManualSourceDependency], decodedSize: Int, validate: @Sendable (URL) throws -> Void,
    validateCandidate: @Sendable (URL) throws -> Void) async throws -> ManualResolvedFragment {
    try Task.checkCancellation()
    guard active.count < 32 else { throw ManualToolError(message: "Manual alias/include depth exceeds 32 files: \(source.path).") }
    guard dependencies.count < 1024 else { throw ManualToolError(message: "Manual include graph exceeds 1024 source occurrences: \(source.path).") }
    try validateCandidate(source)
    let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
    guard !active.contains(resolved.path) else { throw ManualToolError(message: "Manual alias/include cycle at \(source.path).") }
    let bytes = try await checkedManualBytes(source: resolved, validate: validate)
    guard bytes.count <= 64 * 1024 * 1024 - decodedSize else {
        throw ManualToolError(message: "Manual include graph exceeds the 64 MiB decoded input limit: \(source.path).")
    }
    let occurrence = dependencies.count
    var graph = dependencies + [ManualSourceDependency(requested: source, resolved: resolved, digest: manualContentDigest(bytes), parent: parent, line: line)]
    var total = decodedSize + bytes.count
    let text = String(decoding: bytes, as: UTF8.self)
    let lines = text.components(separatedBy: "\n")
    let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix(".\\\"") && !$0.hasPrefix("'\\\"") }
    var output = Data()
    var embedded = false
    var ambiguous = lines.enumerated().filter { ambiguousIncludeMarkup($0.element) }.map { "ambiguous markup at \(source.path):\($0.offset + 1)" }
    var found = false
    var aliasBytes: Data?
    if lines.contains(where: { $0.hasPrefix(".so ") || $0.hasPrefix(".so\t") }), meaningful.count > 1, let unsupported = ambiguous.first {
        throw DiscoveryAccessError(kind: .unsupported, message: "Embedded roff includes require unconditional static markup; \(unsupported). Conditional, macro-generated and .mso includes are unsupported.")
    }
    for (offset, content) in lines.enumerated() {
        if let target = try literalManualInclude(content) {
            found = true
            let selected = try manualIncludeTarget(target: target, source: resolved, validateCandidate: validateCandidate)
            let child = try await resolveManualFragment(source: selected, parent: occurrence, line: offset + 1,
                active: active + [resolved.path], dependencies: graph, decodedSize: total,
                validate: validate, validateCandidate: validateCandidate)
            graph = child.dependencies; total = child.decodedSize
            if meaningful.count == 1 { aliasBytes = child.bytes }
            embedded = embedded || meaningful.count != 1 || child.embedded
            ambiguous += child.ambiguous
            output.append(child.bytes)
            if !child.bytes.isEmpty && child.bytes.last != 10 { output.append(10) }
        } else {
            output.append(Data(content.utf8))
            if offset < lines.count - 1 { output.append(10) }
        }
        guard output.count <= 64 * 1024 * 1024 else { throw ManualToolError(message: "Expanded manual exceeds the 64 MiB input limit: \(source.path).") }
    }
    if found && String(data: bytes, encoding: .utf8) == nil {
        throw DiscoveryAccessError(kind: .unsupported, message: "Manual includes require valid UTF-8 source text: \(source.path).")
    }
    return ManualResolvedFragment(bytes: aliasBytes ?? (found ? output : bytes), dependencies: graph, decodedSize: total,
                                  embedded: embedded, ambiguous: ambiguous)
}

/// mandoc handles man/mdoc, quoted NAME headings, aliases and multiline descriptions.
func manualDescription(source: URL) async throws -> String {
    return descriptionFromFormattedManual(try await manualText(source: source))
}

struct FormattedManualText: Sendable {
    let text: String
    let diagnostic: String
}

/// mandoc explicitly distinguishes usable output with input errors (1–3) from failure (4–6).
/// Callers must display diagnostics alongside any partially formatted output.
func formatManual(input: ManualInput, arguments: [String]) async throws -> ManualProcessResult {
    // mandoc rejects absolute/upward .so paths. An empty cwd denies generated relative includes.
    // Sources and the process's stdin/stdout/stderr captures must never be placed in this directory.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManPagesCatalog-mandoc-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    let result: ManualProcessResult
    do {
        result = try await runManualProcess(executable: URL(fileURLWithPath: "/usr/bin/mandoc"),
                                           arguments: ["-Werror"] + arguments, directory: directory, input: input.bytes)
        guard !result.diagnostic.contains(".so request failed:"), !result.diagnostic.contains(".so with absolute path"),
              !result.diagnostic.contains("skipping insecure request:"),
              result.diagnostic.range(of: #"skipping unknown macro: [.' ]*(?:mso|soquiet|msoquiet)(?:\s|$)"#, options: .regularExpression) == nil else {
            throw DiscoveryAccessError(kind: .unsupported, message: "Unsupported generated or insecure roff include; only validated unconditional literal .so targets are supported. \(result.diagnostic)")
        }
        guard result.status >= 0, result.status <= 3, !result.bytes.isEmpty else {
            throw ManualToolError(message: "mandoc \(arguments.joined(separator: " ")) failed (exit \(result.status)): \(result.diagnostic)")
        }
    } catch {
        do { try FileManager.default.removeItem(at: directory) }
        catch let cleanup { throw ManualProcessCleanupError(cause: error, failures: ["Cannot remove empty formatter directory: \(cleanup.localizedDescription)"]) }
        throw error
    }
    try FileManager.default.removeItem(at: directory)
    return result
}

func manualText(source: URL) async throws -> String {
    try await formattedManualText(source: source).text
}

func formattedManualText(source: URL) async throws -> FormattedManualText {
    let input = try await manualInput(source: source)
    return try await formattedManualText(input: input)
}

func formattedManualText(input: ManualInput) async throws -> FormattedManualText {
    let formatted = try await formatManual(input: input, arguments: ["-Tutf8", "-O", "width=1000"])
    let plain = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/col"), arguments: ["-b"],
                                      directory: URL(fileURLWithPath: "/"), input: formatted.bytes)
    return FormattedManualText(text: String(decoding: plain, as: UTF8.self), diagnostic: formatted.diagnostic)
}

func descriptionFromFormattedManual(_ text: String) -> String {
    var inName = false
    var lines: [String] = []
    for line in text.components(separatedBy: .newlines) {
        if line.trimmingCharacters(in: .whitespaces) == "NAME" {
            inName = true
        } else if inName {
            if let first = line.first, !first.isWhitespace { break }
            let content = line.trimmingCharacters(in: .whitespaces)
            if !content.isEmpty { lines.append(content) }
        }
    }
    let name = lines.joined(separator: " ")
    guard let separator = name.range(of: #"\s+[–—−-]\s+"#, options: .regularExpression) else { return "" }
    return String(name[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
}

func renderManual(source: URL, destination: URL) async throws {
    let input = try await manualInput(source: source)
    let pdf = try await renderedManualPDF(input: input)
    try Task.checkCancellation()
    try pdf.write(to: destination, options: .atomic)
}

func renderedManualPDF(input: ManualInput) async throws -> Data {
    let formatted = try await formatManual(input: input, arguments: ["-Tpdf"])
    guard formatted.status == 0 else {
        throw ManualToolError(message: "mandoc PDF rendering failed (exit \(formatted.status)): \(formatted.diagnostic)")
    }
    let pdf = formatted.bytes
    guard pdf.starts(with: Data("%PDF".utf8)) else {
        throw ManualToolError(message: "The system mandoc did not produce PDF data. This app requires mandoc PDF output; no alternate renderer was substituted.")
    }
    try Task.checkCancellation()
    return pdf
}

func executablePath(name: String, section: String, environment: [String: String]) -> String {
    resolveCommandExecutable(name: name, section: section, environment: environment).path ?? ""
}

func writeCatalog(entries: [CatalogEntry], directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Catalog(entries: entries)).write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
}

/// Rendering/metadata failure leaves catalog.json unchanged. Every PDF uses the verified input bytes.
func generateCatalog(directory: URL, roots: [URL], environment: [String: String],
                     progress: @Sendable (CatalogProgress) async -> Void) async throws {
    let authority = await MainActor.run { ManualSourceAuthority(selectedRoots: []) }
    try await generateCatalog(directory: directory, roots: roots, environment: environment, authority: authority, progress: progress)
}

func generateCatalog(directory: URL, roots: [URL], environment: [String: String], authority: ManualSourceAuthority,
                     progress: @Sendable (CatalogProgress) async -> Void) async throws {
    let access = await authority.snapshot()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sources = try discoverManuals(roots: roots, access: access)
    var entries: [CatalogEntry] = []
    await progress(CatalogProgress(completed: 0, total: sources.count))
    for (index, source) in sources.enumerated() {
        try Task.checkCancellation()
        let input = try await sourceManualInput(source: source.url, scope: .legacy, access: access)
        let description = descriptionFromFormattedManual(try await formattedManualText(input: input).text)
        try await authority.requireCurrent(access)
        let name = "\(source.name).\(source.section).pdf"
        let destination = directory.appendingPathComponent(name)
        let pdf = try await renderedManualPDF(input: input)
        try Task.checkCancellation()
        try await MainActor.run {
            try Task.checkCancellation()
            try authority.requireCurrent(access)
            try pdf.write(to: destination, options: .atomic)
        }
        entries.append(CatalogEntry(name: source.name, section: source.section, description: description,
                                    pdf_path: name, source_path: source.url.path,
                                    executable_path: executablePath(name: source.name, section: source.section, environment: environment)))
        await progress(CatalogProgress(completed: index + 1, total: sources.count))
    }
    try Task.checkCancellation()
    let ordered = entries.sorted { ($0.name.lowercased(), $0.section) < ($1.name.lowercased(), $1.section) }
    try await MainActor.run {
        try Task.checkCancellation()
        try authority.requireCurrent(access)
        try writeCatalog(entries: ordered, directory: directory)
    }
}

func refreshCatalogMetadata(directory: URL, environment: [String: String],
                            progress: @Sendable (CatalogProgress) async -> Void) async throws {
    let authority = await MainActor.run { ManualSourceAuthority(selectedRoots: []) }
    try await refreshCatalogMetadata(directory: directory, environment: environment, authority: authority, progress: progress)
}

func refreshCatalogMetadata(directory: URL, environment: [String: String], authority: ManualSourceAuthority,
                            progress: @Sendable (CatalogProgress) async -> Void) async throws {
    let access = await authority.snapshot()
    let catalog = try loadCatalog(directory: directory)
    var entries: [CatalogEntry] = []
    await progress(CatalogProgress(completed: 0, total: catalog.entries.count))
    for (index, entry) in catalog.entries.enumerated() {
        try Task.checkCancellation()
        guard let source = entry.source_path, !source.isEmpty else {
            throw ManualToolError(message: "Cannot refresh \(entry.id): source_path is missing. Regenerate this legacy catalog to record source paths.")
        }
        let input = try await sourceManualInput(source: URL(fileURLWithPath: source), scope: .legacy, access: access)
        let formatted = try await formattedManualText(input: input)
        guard formatted.diagnostic.isEmpty else {
            throw ManualToolError(message: "Cannot refresh catalog metadata for \(entry.id) from \(source): \(formatted.diagnostic) Correct the source formatting before retrying. Previous catalog metadata and PDFs remain unchanged.")
        }
        let description = descriptionFromFormattedManual(formatted.text)
        try await authority.requireCurrent(access)
        entries.append(CatalogEntry(name: entry.name, section: entry.section, description: description,
                                    pdf_path: entry.pdf_path, source_path: source,
                                    executable_path: executablePath(name: entry.name, section: entry.section, environment: environment)))
        await progress(CatalogProgress(completed: index + 1, total: catalog.entries.count))
    }
    try Task.checkCancellation()
    let refreshed = entries
    try await MainActor.run {
        try Task.checkCancellation()
        try authority.requireCurrent(access)
        try writeCatalog(entries: refreshed, directory: directory)
    }
}
