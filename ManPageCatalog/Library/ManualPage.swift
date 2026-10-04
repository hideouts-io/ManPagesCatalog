import Foundation

struct ManualLocation: Hashable, Codable, Sendable {
    let source: URL
    let root: URL
    let name: String
    let section: String
    let language: String
    let stamp: String
}

struct ManualPage: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(fingerprint):\(section):\(language)" }
    let name: String
    let section: String
    let source: URL
    let root: URL
    let fingerprint: String
    let language: String
    var locations: [ManualLocation]
    var description: String
    var indexed: Bool
    var problem: String?
    var title: String { "\(name)(\(section))" }

    func at(_ location: ManualLocation) -> ManualPage {
        ManualPage(name: location.name, section: location.section, source: location.source, root: location.root,
                   fingerprint: fingerprint, language: location.language, locations: locations,
                   description: description, indexed: indexed, problem: problem)
    }
}

enum CoverageKind: String, Codable, CaseIterable, Sendable {
    case pending, excluded, inaccessible, failed, unsupported
}

struct DiscoveryIssue: Codable, Hashable, Sendable {
    let path: String
    let kind: CoverageKind
    let reason: String
}

struct SourceCoverage: Identifiable, Codable, Sendable {
    var id: String { root.path }
    let root: URL
    let count: Int
    let directories: Int
    let files: Int
    let completed: Bool
    let issues: [DiscoveryIssue]
    var problems: [String] { issues.map { "\($0.path): \($0.reason)" } }
}

struct LibraryScan: Codable, Sendable {
    let pages: [ManualPage]
    let coverage: [SourceCoverage]
    let cancelled: Bool
}

struct DiscoveryProgress: Sendable {
    let path: String
    let directories: Int
    let files: Int
    let manuals: Int
    let pending: Int
    let peakPending: Int
}

/// Identical resolved content shares one search entry; names and every encountered location survive.
func groupedManuals(_ pages: [ManualPage]) -> [ManualPage] {
    let groups = Dictionary(grouping: pages, by: \.id)
    return groups.values.map { group in
        let locations = Array(Set(group.flatMap(\.locations))).sorted { $0.source.path < $1.source.path }
        var page = group.sorted { $0.source.path < $1.source.path }[0]
        page.locations = locations
        return page
    }.sorted { $0.source.path < $1.source.path }
}

/// Only remove prior locations positively covered by a completed scan. Failures retain usable data.
func mergingDiscovery(previous: [ManualPage], scan: LibraryScan) -> [ManualPage] {
    let discovered = Set(scan.pages.flatMap(\.locations).map { $0.source.path })
    let retained = previous.compactMap { page -> ManualPage? in
        let locations = page.locations.filter { location in
            if discovered.contains(location.source.path) { return false }
            return !scan.coverage.contains { coverage in
                coverage.completed && pathContains(root: coverage.root.path, path: location.source.path) &&
                !coverage.issues.contains { pathContains(root: $0.path, path: location.source.path) }
            }
        }
        guard let first = locations.first else { return nil }
        var retained = page.at(first)
        retained.locations = locations
        return retained
    }
    return groupedManuals(scan.pages + retained)
}

func pathContains(root: String, path: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
}

struct DiscoveryInventoryError: LocalizedError {
    let path: String
    let duplicateID: String
    var errorDescription: String? {
        "Cannot read discovery inventory \(path): duplicate grouped manual ID \(duplicateID). Keep one entry per content/section/language identity. Move this app-owned inventory aside to rebuild it; original manual sources are separate."
    }
}

/// Reject malformed grouped inventories; raw checkpoint entries may still share content IDs.
func loadDiscovery(_ url: URL) throws -> LibraryScan {
    do {
        let saved = try JSONDecoder().decode(LibraryScan.self, from: Data(contentsOf: url))
        try validateManualPages(saved.pages)
        var identities: Set<String> = []
        for page in saved.pages {
            guard identities.insert(page.id).inserted else {
                throw DiscoveryInventoryError(path: url.path, duplicateID: page.id)
            }
        }
        return saved
    } catch let error as DiscoveryInventoryError {
        throw error
    } catch {
        throw ManualToolError(message: "Cannot read discovery inventory \(url.path): \(error.localizedDescription) Move this app-owned inventory aside to rebuild it; original manuals and PDF catalogs are separate.")
    }
}

func validateManualPages(_ pages: [ManualPage]) throws {
    for page in pages {
        guard !page.locations.isEmpty, !page.name.isEmpty, !page.section.isEmpty,
              page.locations.contains(where: { $0.source == page.source && $0.root == page.root && $0.name == page.name }),
              page.fingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              page.locations.allSatisfy({ $0.source.isFileURL && $0.root.isFileURL && !$0.name.isEmpty && $0.section == page.section && $0.language == page.language }) else {
            throw ManualToolError(message: "Inventory contains a manual with invalid identity or source locations.")
        }
    }
}
