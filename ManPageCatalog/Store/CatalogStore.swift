import Foundation
import Combine

class CatalogStore: ObservableObject {
    @Published var entries: [CatalogEntry] = []
    @Published var outputDir: URL? {
        didSet {
            if let url = outputDir {
                UserDefaults.standard.set(url.path, forKey: "outputDir")
                reload()
            }
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "outputDir") {
            outputDir = URL(fileURLWithPath: saved)
            reload()
        }
    }

    var sections: [String] {
        let all = Set(entries.map(\.section))
        return all.sorted { a, b in
            (Int(a) ?? 99) < (Int(b) ?? 99)
        }
    }

    func filteredEntries(section: String?, query: String) -> [CatalogEntry] {
        entries.filter { entry in
            let matchSection = section == nil || entry.section == section
            let matchQuery = query.isEmpty
                || entry.name.localizedCaseInsensitiveContains(query)
                || entry.description.localizedCaseInsensitiveContains(query)
            return matchSection && matchQuery
        }
    }

    func reload() {
        guard let dir = outputDir else { return }
        let catalogURL = dir.appendingPathComponent("catalog.json")
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: catalogURL),
                  let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
                DispatchQueue.main.async { self.entries = [] }
                return
            }
            DispatchQueue.main.async { self.entries = catalog.entries }
        }
    }

    func pdfURL(for entry: CatalogEntry) -> URL? {
        outputDir?.appendingPathComponent(entry.pdf_path)
    }
}
