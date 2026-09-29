import Foundation

struct ManualPage: Identifiable, Hashable, Sendable {
    var id: String { source.path }
    let name: String
    let section: String
    let source: URL
    let root: URL
    let fingerprint: String
    var description: String
    var indexed: Bool
    var problem: String?
    var title: String { "\(name)(\(section))" }
}

struct SourceCoverage: Identifiable, Sendable {
    var id: String { root.path }
    let root: URL
    let count: Int
    let problems: [String]
}

struct LibraryScan: Sendable {
    let pages: [ManualPage]
    let coverage: [SourceCoverage]
}

/// Searches manual directories and one locale level, never arbitrary home-directory contents.
func scanLibrary(roots: [URL]) throws -> LibraryScan {
    var pages: [ManualPage] = []
    var coverage: [SourceCoverage] = []
    var seen = Set<String>()
    for root in roots {
        try Task.checkCancellation()
        var problems: [String] = []
        let startCount = pages.count
        do {
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var sections: [URL] = []
            for child in children {
                guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                if child.lastPathComponent.hasPrefix("man") { sections.append(child) }
                else {
                    let localized = try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    sections += localized.filter { $0.lastPathComponent.hasPrefix("man") }
                }
            }
            for sectionURL in sections.sorted(by: { $0.path < $1.path }) {
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: sectionURL, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey], options: [])
                    for file in files.sorted(by: { $0.path < $1.path }) {
                        do {
                            let resolved = file.resolvingSymlinksInPath()
                            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
                            guard values.isRegularFile == true else { continue }
                            let compressed = ["gz", "bz2", "Z", "xz"].contains(file.pathExtension)
                            let plain = compressed ? file.deletingPathExtension() : file
                            let section = plain.pathExtension
                            guard let first = section.first, first.isNumber || first == "n",
                                  seen.insert(file.standardizedFileURL.path).inserted else { continue }
                            let unsupported = file.pathExtension == "xz" ? "XZ compression is not supported by the bundled system-tool integration." : nil
                            // Compressed files and .so aliases are refreshed because their target may change independently.
                            let alias = try !compressed && (values.fileSize ?? 0) < 2048 && String(decoding: Data(contentsOf: resolved), as: UTF8.self).contains(".so")
                            let fingerprint = compressed || alias ? "" : "v2:\(resolved.path):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
                            pages.append(ManualPage(name: plain.deletingPathExtension().lastPathComponent, section: section,
                                                    source: file, root: root,
                                                    fingerprint: fingerprint,
                                                    description: "", indexed: false, problem: unsupported))
                            if let unsupported { problems.append("\(file.path): \(unsupported)") }
                        } catch { problems.append("\(file.path): \(error.localizedDescription)") }
                    }
                } catch { problems.append("\(sectionURL.path): \(error.localizedDescription)") }
            }
        } catch { problems.append("\(root.path): \(error.localizedDescription)") }
        coverage.append(SourceCoverage(root: root, count: pages.count - startCount, problems: problems))
    }
    return LibraryScan(pages: pages, coverage: coverage)
}

func systemLibraryRoots(environment: [String: String], additional: [String]) async throws -> [URL] {
    var roots = try await manualRoots(environment: environment)
    // An explicit MANPATH is an exact scope, useful for dedicated documentation collections.
    if environment["MANPATH"] == nil {
        let candidates = ["/usr/share/man", "/usr/local/share/man", "/opt/homebrew/share/man", "/opt/local/share/man",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/man").path]
        roots += candidates.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    roots += additional.map { URL(fileURLWithPath: $0) }
    var seen = Set<String>()
    return roots.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
}
