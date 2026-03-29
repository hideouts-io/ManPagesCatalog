import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: CatalogStore
    @State private var selectedSection: String? = nil
    @State private var selectedEntry: CatalogEntry? = nil
    @State private var searchQuery = ""
    @State private var showGenerate = false

    var body: some View {
        NavigationSplitView {
            // Sidebar — sections
            List(selection: $selectedSection) {
                Label("All", systemImage: "books.vertical")
                    .tag(Optional<String>.none)
                ForEach(store.sections, id: \.self) { section in
                    Label("Section \(section)", systemImage: "doc.text")
                        .tag(Optional(section))
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Sections")
        } content: {
            // Middle column — man page list
            List(store.filteredEntries(section: selectedSection, query: searchQuery),
                 selection: $selectedEntry) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.name)(\(entry.section))")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    if !entry.description.isEmpty {
                        Text(entry.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(entry)
            }
            .searchable(text: $searchQuery, prompt: "Search man pages…")
            .navigationTitle(selectedSection.map { "Section \($0)" } ?? "All Pages")
            .navigationSubtitle("\(store.filteredEntries(section: selectedSection, query: searchQuery).count) pages")
        } detail: {
            // Detail — PDF viewer
            if let entry = selectedEntry, let url = store.pdfURL(for: entry) {
                PDFDetailView(url: url, title: "\(entry.name)(\(entry.section))", sourcePath: entry.source_path, executablePath: entry.executable_path)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a Man Page")
                        .font(.title2).fontWeight(.semibold)
                    Text("Choose a man page from the list to view its PDF.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showGenerate = true
                } label: {
                    Label("Generate", systemImage: "arrow.clockwise.circle")
                }
                .help("Generate PDFs from man pages")
            }
        }
        .sheet(isPresented: $showGenerate) {
            GenerateView()
                .environmentObject(store)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
