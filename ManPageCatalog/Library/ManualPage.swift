import Foundation
import os

/// Persisted restrictions are evidence of a scan's boundary, never a grant of network access.
struct ManualSourceScope: Hashable, Codable, Sendable {
    let traversalRoots: [URL]?
    let resolvedTraversalRoots: [URL]?
    let traversalExclusions: [DiscoveryIssue]
    let resolvedTraversalExclusions: [URL]
    let excludedMountedVolumes: [URL]

    static var legacy: ManualSourceScope {
        ManualSourceScope(traversalRoots: nil, resolvedTraversalRoots: nil, traversalExclusions: [],
                          resolvedTraversalExclusions: [], excludedMountedVolumes: [])
    }
}

/// Ordered occurrences retain repeated includes and distinguish retargeting from identical content.
struct ManualSourceDependency: Hashable, Codable, Sendable {
    let requested: URL
    let resolved: URL
    let digest: String
    let parent: Int?
    let line: Int?
}

struct ManualSourceProvenance: Hashable, Codable, Sendable {
    let version: Int
    let scope: ManualSourceScope
    let dependencies: [ManualSourceDependency]
}

struct ManualSourceAccess: Sendable {
    let generation: UUID
    let allowedNetworkRoots: [URL]
    let lease: ManualSourceLease

    init(generation: UUID, allowedNetworkRoots: [URL]) {
        self.generation = generation; self.allowedNetworkRoots = allowedNetworkRoots
        lease = ManualSourceLease()
    }

    func check() throws { try lease.check() }
}

/// A shared cancellation boundary for source I/O already running away from the main actor.
struct ManualSourceLease: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: true)

    func revoke() { current.withLock { $0 = false } }

    func check() throws {
        guard current.withLock({ $0 }) else {
            throw ManualToolError(message: "Source selections changed during acquisition. Retry with the currently selected folders.")
        }
    }
}

/// The app's current explicit selections authorize I/O; inventories and history cannot grant access.
@MainActor
final class ManualSourceAuthority {
    private var access: ManualSourceAccess
    private var selectedRoots: [URL]

    init(selectedRoots: [URL]) {
        let selected = selectedRoots.map(\.standardizedFileURL)
        self.selectedRoots = selected
        access = ManualSourceAccess(generation: UUID(), allowedNetworkRoots: selected.map { $0.resolvingSymlinksInPath() })
    }

    func snapshot() -> ManualSourceAccess { access }

    func requireCurrent(_ expected: ManualSourceAccess) throws {
        try expected.check()
        guard access.generation == expected.generation else {
            throw ManualToolError(message: "Source selections changed during this operation. Retry with the currently selected folders; no new result was published.")
        }
    }

    func replaceSelectedRoots(_ roots: [URL]) {
        let selected = roots.map(\.standardizedFileURL)
        guard selected.map(\.path) != selectedRoots.map(\.path) else { return }
        let pinned = Dictionary(zip(selectedRoots, access.allowedNetworkRoots).map { ($0.path, $1) },
                                uniquingKeysWith: { first, _ in first })
        access.lease.revoke()
        selectedRoots = selected
        access = ManualSourceAccess(generation: UUID(), allowedNetworkRoots: selected.map {
            pinned[$0.path] ?? $0.resolvingSymlinksInPath()
        })
    }
}

struct ManualLocation: Hashable, Codable, Sendable {
    let source: URL
    let root: URL
    let name: String
    let section: String
    let language: String
    let stamp: String
    let provenance: ManualSourceProvenance?

    private enum CodingKeys: String, CodingKey {
        case source, root, name, section, language, stamp, provenance
    }

    /// Only inventories written before provenance existed may omit the policy; a present null is invalid.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provenance: ManualSourceProvenance?
        if container.contains(.provenance) {
            provenance = try container.decode(ManualSourceProvenance.self, forKey: .provenance)
        } else { provenance = nil }
        self.init(source: try container.decode(URL.self, forKey: .source),
                  root: try container.decode(URL.self, forKey: .root),
                  name: try container.decode(String.self, forKey: .name),
                  section: try container.decode(String.self, forKey: .section),
                  language: try container.decode(String.self, forKey: .language),
                  stamp: try container.decode(String.self, forKey: .stamp), provenance: provenance)
    }

    init(source: URL, root: URL, name: String, section: String, language: String, stamp: String) {
        self.init(source: source, root: root, name: name, section: section, language: language, stamp: stamp, provenance: nil)
    }

    init(source: URL, root: URL, name: String, section: String, language: String, stamp: String,
         provenance: ManualSourceProvenance?) {
        self.source = source; self.root = root; self.name = name; self.section = section
        self.language = language; self.stamp = stamp; self.provenance = provenance
    }
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

/// An encountered directory alias refers to measured work, without inventing descendant file locations.
struct DiscoveryDirectoryReference: Codable, Hashable, Sendable {
    let directory: URL
    let identity: String
    /// Older checkpoints did not retain which coverage root opened the directory.
    let root: URL?
}

struct DiscoveryIssue: Codable, Hashable, Sendable {
    let path: String
    let kind: CoverageKind
    let reason: String
    let directoryReference: DiscoveryDirectoryReference?

    init(path: String, kind: CoverageKind, reason: String) {
        self.init(path: path, kind: kind, reason: reason, directoryReference: nil)
    }

    init(path: String, kind: CoverageKind, reason: String, directoryReference: DiscoveryDirectoryReference?) {
        self.path = path
        self.kind = kind
        self.reason = reason
        self.directoryReference = directoryReference
    }
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
        try validateCoverageDirectoryReferences(saved.coverage)
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

/// References identify the actual coverage record, not a root inferred from overlapping path prefixes.
func validateCoverageDirectoryReferences(_ coverage: [SourceCoverage]) throws {
    let measured = coverage.filter { $0.directories > 0 }
    for source in coverage {
        for issue in source.issues {
            guard let reference = issue.directoryReference else { continue }
            let identity = reference.identity.split(separator: ":", omittingEmptySubsequences: false)
            guard issue.kind == .excluded, pathContains(root: source.root.path, path: issue.path),
                  !issue.path.contains("\0"), reference.directory.isFileURL,
                  reference.directory.path.hasPrefix("/"), !reference.directory.path.contains("\0"),
                  identity.count == 2, Int32(identity[0]) != nil, UInt64(identity[1]).map({ $0 > 0 }) == true,
                  reference.root.map({ root in
                      root.isFileURL && root.path.hasPrefix("/") && !root.path.contains("\0") &&
                      measured.contains { $0.root == root && pathContains(root: root.path, path: reference.directory.path) }
                  }) ?? measured.contains(where: { pathContains(root: $0.root.path, path: reference.directory.path) }) else {
                throw ManualToolError(message: "Coverage contains an invalid directory reference at \(issue.path). Start a fresh scan to rebuild coverage; retained manual sources are unchanged.")
            }
        }
    }
}

func validateManualPages(_ pages: [ManualPage]) throws {
    for page in pages {
        guard !page.locations.isEmpty, !page.name.isEmpty, !page.section.isEmpty,
              page.locations.contains(where: { $0.source == page.source && $0.root == page.root && $0.name == page.name }),
              page.fingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              page.locations.allSatisfy({ validManualSourceURL($0.source) && validManualSourceURL($0.root) && !$0.name.isEmpty && $0.section == page.section && $0.language == page.language }) else {
            throw ManualToolError(message: "Inventory contains a manual with invalid identity or source locations.")
        }
        let keys: Set<[String]> = Set(page.locations.map { [$0.source.standardizedFileURL.path, $0.root.standardizedFileURL.path, $0.name, $0.section, $0.language] })
        guard keys.count == page.locations.count else {
            throw ManualToolError(message: "Inventory contains ambiguous source locations or conflicting provenance for \(page.source.path). Start a fresh scan to rebuild source metadata.")
        }
        for location in page.locations {
            if let provenance = location.provenance {
                try validateManualSourceProvenance(provenance, source: location.source)
            }
        }
    }
}

func validManualSourceURL(_ url: URL) -> Bool {
    url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0") &&
        (url.host == nil || url.host == "" || url.host == "localhost")
}

/// Validate new records strictly; only an absent field receives the explicit legacy interpretation.
func validateManualSourceProvenance(_ provenance: ManualSourceProvenance, source: URL) throws {
    let scope = provenance.scope
    let rootsValid: Bool
    switch (scope.traversalRoots, scope.resolvedTraversalRoots) {
    case (nil, nil): rootsValid = true
    case let (.some(roots), .some(resolved)):
        rootsValid = !roots.isEmpty && roots.count == resolved.count && (roots + resolved).allSatisfy(validManualSourceURL)
    default: rootsValid = false
    }
    guard provenance.version == 1, rootsValid,
          scope.traversalExclusions.count == scope.resolvedTraversalExclusions.count,
          scope.traversalExclusions.allSatisfy({ $0.kind == .excluded && $0.path.hasPrefix("/") && !$0.path.contains("\0") && $0.directoryReference == nil }),
          (scope.resolvedTraversalExclusions + scope.excludedMountedVolumes).allSatisfy(validManualSourceURL),
          !provenance.dependencies.isEmpty, provenance.dependencies.count <= 1024,
          provenance.dependencies[0].requested == source,
          provenance.dependencies.enumerated().allSatisfy({ index, dependency in
              validManualSourceURL(dependency.requested) && validManualSourceURL(dependency.resolved) &&
              dependency.digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil &&
              (index == 0 ? dependency.parent == nil && dependency.line == nil :
                dependency.parent.map { $0 >= 0 && $0 < index } == true && dependency.line.map { $0 > 0 } == true)
          }) else {
        throw ManualToolError(message: "Inventory contains invalid or unsupported source provenance for \(source.path). Start a fresh scan to rebuild this app-owned metadata; source manuals are unchanged.")
    }
}
