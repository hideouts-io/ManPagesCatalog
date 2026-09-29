import Foundation
import Combine

/// Coordinates catalog I/O; failed refreshes retain the last successfully loaded catalog.
@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var entries: [CatalogEntry] = []
    @Published private(set) var state: CatalogLoadState = .firstLaunch
    @Published private(set) var revision = 0
    @Published var outputDir: URL? {
        didSet {
            if let url = outputDir {
                // A launch-time directory override must not replace the user's saved catalog.
                if defaults.volatileDomain(forName: UserDefaults.argumentDomain)["outputDir"] == nil {
                    defaults.set(url.path, forKey: "outputDir")
                }
                reload()
            }
        }
    }

    private let defaults: UserDefaults
    private var loadedDir: URL?
    private var requestID = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: "outputDir"), !saved.isEmpty {
            outputDir = URL(fileURLWithPath: saved)
            reload()
        }
    }

    var sections: [String] {
        Set(entries.map(\.section)).sorted { left, right in
            left.compare(right, options: [.numeric, .literal], locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending
        }
    }

    func filteredEntries(section: String?, query: String) -> [CatalogEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (section == nil || entry.section == section) &&
            (term.isEmpty || entry.name.localizedCaseInsensitiveContains(term)
                || entry.description.localizedCaseInsensitiveContains(term))
        }
    }

    func reload() {
        // Preserve the existing ability to recover the saved directory on reload.
        if outputDir == nil, let saved = defaults.string(forKey: "outputDir"), !saved.isEmpty {
            outputDir = URL(fileURLWithPath: saved)
            return
        }
        requestID += 1
        let request = requestID
        guard let directory = outputDir else {
            state = .firstLaunch
            return
        }
        state = .loading
        Task {
            do {
                let catalog = try await Task.detached(priority: .userInitiated) {
                    try loadCatalog(directory: directory)
                }.value
                guard request == requestID else { return }
                entries = catalog.entries
                loadedDir = directory
                revision += 1
                state = entries.isEmpty ? .empty : .ready
            } catch {
                guard request == requestID else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func pdfURL(for entry: CatalogEntry) -> URL? {
        loadedDir?.appendingPathComponent(entry.pdf_path)
    }
}

enum CatalogLoadState: Equatable {
    case firstLaunch
    case loading
    case ready
    case empty
    case failed(String)
}

struct CatalogReadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func loadCatalog(directory: URL) throws -> Catalog {
    let url = directory.appendingPathComponent("catalog.json")
    do {
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        var identities = Set<String>()
        for entry in catalog.entries {
            let components = entry.pdf_path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.name.isEmpty, !entry.section.isEmpty, !entry.pdf_path.isEmpty,
                  !entry.pdf_path.hasPrefix("/"), !components.contains(".."),
                  identities.insert(entry.id).inserted else {
                throw CatalogReadError(message: "Invalid entry \(entry.id): name/section must be nonempty, PDF paths must stay inside the catalog, and IDs must be unique.")
            }
        }
        return catalog
    } catch {
        throw CatalogReadError(message: "Cannot load \(url.path): \(error.localizedDescription) Choose a valid catalog folder or generate one. The previous catalog, if any, is still displayed.")
    }
}

func sectionLabel(_ section: String) -> String {
    let number = String(section.prefix(while: \.isNumber))
    let labels = ["1": "Commands", "2": "System Calls", "3": "Library APIs", "4": "Devices",
                  "5": "File Formats", "6": "Games", "7": "Conventions", "8": "Administration", "9": "Kernel Interfaces"]
    return "\(section) — \(labels[number] ?? "Additional Manuals")"
}
