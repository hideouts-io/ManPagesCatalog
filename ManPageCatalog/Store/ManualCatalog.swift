import Foundation
import PDFKit

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
    if let configured = environment["MANPATH"], !configured.isEmpty {
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
    var sources: [ManualSource] = []
    var seen = Set<String>()
    for root in roots {
        let sections = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for directory in sections.sorted(by: { $0.path < $1.path }) where directory.lastPathComponent.hasPrefix("man") {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let directorySection = String(directory.lastPathComponent.dropFirst(3))
            guard !directorySection.isEmpty else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            for file in files.sorted(by: { $0.path < $1.path }) {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let plain = file.pathExtension == "gz" ? file.deletingPathExtension() : file
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
    if ["gz", "Z", "bz2"].contains(source.pathExtension) {
        return try await runManualTool(executable: URL(fileURLWithPath: source.pathExtension == "bz2" ? "/usr/bin/bzip2" : "/usr/bin/gzip"), arguments: ["-dc", source.path],
                                       directory: source.deletingLastPathComponent(), input: nil)
    }
    if source.pathExtension == "xz" { throw ManualToolError(message: "XZ-compressed manual is unsupported: \(source.path)") }
    return try Data(contentsOf: source)
}

struct ManualInput: Sendable {
    let bytes: Data
    let directory: URL
}

/// Resolves whole-file .so aliases, including compressed targets, before invoking mandoc.
func manualInput(source: URL) async throws -> ManualInput {
    var current = source.resolvingSymlinksInPath()
    var visited = Set<String>()
    for _ in 0..<32 {
        try Task.checkCancellation()
        guard visited.insert(current.path).inserted else {
            throw ManualToolError(message: "Manual alias cycle at \(current.path) while opening \(source.path).")
        }
        let bytes = try await manualBytes(source: current)
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".\\\"") && !$0.hasPrefix("'\\\"") }
        let directory = current.deletingLastPathComponent()
        guard lines.count == 1, lines[0].hasPrefix(".so ") || lines[0].hasPrefix(".so\t") else {
            return ManualInput(bytes: bytes, directory: directory.deletingLastPathComponent())
        }
        let target = String(lines[0].dropFirst(4)).trimmingCharacters(in: .whitespaces)
        let relative = [directory.deletingLastPathComponent().appendingPathComponent(target), directory.appendingPathComponent(target)]
        let candidates = target.hasPrefix("/") ? [URL(fileURLWithPath: target)] : relative
        let expanded = candidates.flatMap { url in [url, url.appendingPathExtension("gz"), url.appendingPathExtension("bz2"), url.appendingPathExtension("Z")] }
        guard let resolved = expanded.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ManualToolError(message: "Manual alias \(current.path) refers to missing target \(target). Restore its documentation package.")
        }
        current = resolved.standardizedFileURL.resolvingSymlinksInPath()
    }
    throw ManualToolError(message: "Manual alias chain exceeds 32 files: \(source.path).")
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
    let result = try await runManualProcess(executable: URL(fileURLWithPath: "/usr/bin/mandoc"),
                                           arguments: ["-Werror"] + arguments, directory: input.directory, input: input.bytes)
    guard result.status >= 0, result.status <= 3, !result.bytes.isEmpty else {
        throw ManualToolError(message: "mandoc \(arguments.joined(separator: " ")) failed (exit \(result.status)): \(result.diagnostic)")
    }
    return result
}

func manualText(source: URL) async throws -> String {
    try await formattedManualText(source: source).text
}

func formattedManualText(source: URL) async throws -> FormattedManualText {
    let input = try await manualInput(source: source)
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
    let pdf = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/mandoc"), arguments: ["-Werror", "-Tpdf"],
                                      directory: input.directory, input: input.bytes)
    guard pdf.starts(with: Data("%PDF".utf8)) else {
        throw ManualToolError(message: "The system mandoc did not produce PDF data for \(source.path). This app requires mandoc PDF output; no alternate renderer was substituted.")
    }
    try Task.checkCancellation()
    try pdf.write(to: destination, options: .atomic)
}

func executablePath(name: String, section: String, environment: [String: String]) -> String {
    guard ["1", "1m", "1ssl", "1tcl", "8"].contains(section) else { return "" }
    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    for directory in path.split(separator: ":") {
        let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: url.path) { return url.path }
    }
    return ""
}

func writeCatalog(entries: [CatalogEntry], directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Catalog(entries: entries)).write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
}

/// Rendering/metadata failure leaves catalog.json unchanged; completed PDFs remain reusable.
func generateCatalog(directory: URL, roots: [URL], environment: [String: String],
                     progress: @Sendable (CatalogProgress) async -> Void) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sources = try discoverManuals(roots: roots)
    var entries: [CatalogEntry] = []
    await progress(CatalogProgress(completed: 0, total: sources.count))
    for (index, source) in sources.enumerated() {
        try Task.checkCancellation()
        let description = try await manualDescription(source: source.url)
        let name = "\(source.name).\(source.section).pdf"
        let destination = directory.appendingPathComponent(name)
        let sourceDate = try source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var needsRendering = true
        if FileManager.default.fileExists(atPath: destination.path) {
            let attributes = try destination.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let sourceDate, let pdfDate = attributes.contentModificationDate,
               pdfDate >= sourceDate, let size = attributes.fileSize, size > 0, let pdf = PDFDocument(url: destination), pdf.pageCount > 0 { needsRendering = false }
        }
        if needsRendering { try await renderManual(source: source.url, destination: destination) }
        entries.append(CatalogEntry(name: source.name, section: source.section, description: description,
                                    pdf_path: name, source_path: source.url.path,
                                    executable_path: executablePath(name: source.name, section: source.section, environment: environment)))
        await progress(CatalogProgress(completed: index + 1, total: sources.count))
    }
    try Task.checkCancellation()
    try writeCatalog(entries: entries.sorted { ($0.name.lowercased(), $0.section) < ($1.name.lowercased(), $1.section) }, directory: directory)
}

func refreshCatalogMetadata(directory: URL, environment: [String: String],
                            progress: @Sendable (CatalogProgress) async -> Void) async throws {
    let catalog = try loadCatalog(directory: directory)
    var entries: [CatalogEntry] = []
    await progress(CatalogProgress(completed: 0, total: catalog.entries.count))
    for (index, entry) in catalog.entries.enumerated() {
        try Task.checkCancellation()
        guard let source = entry.source_path, !source.isEmpty else {
            throw ManualToolError(message: "Cannot refresh \(entry.id): source_path is missing. Regenerate this legacy catalog to record source paths.")
        }
        entries.append(CatalogEntry(name: entry.name, section: entry.section,
                                    description: try await manualDescription(source: URL(fileURLWithPath: source)),
                                    pdf_path: entry.pdf_path, source_path: source,
                                    executable_path: executablePath(name: entry.name, section: entry.section, environment: environment)))
        await progress(CatalogProgress(completed: index + 1, total: catalog.entries.count))
    }
    try Task.checkCancellation()
    try writeCatalog(entries: entries, directory: directory)
}
