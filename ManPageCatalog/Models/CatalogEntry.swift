import Foundation

struct CatalogEntry: Identifiable, Codable, Hashable {
    var id: String { "\(name).\(section)" }
    let name: String
    let section: String
    let description: String
    let pdf_path: String
    let source_path: String?
    let executable_path: String?
}

struct Catalog: Codable {
    let entries: [CatalogEntry]
}
