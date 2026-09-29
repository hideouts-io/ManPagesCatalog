import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sources & Search Index").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Search Manuals") {
                    openWindow(id: "browser")
                    NotificationCenter.default.post(name: .searchCommands, object: nil)
                }.accessibilityIdentifier("sourcesSearch")
            }
            Text("Only configured manual directories are scanned. Names appear immediately; descriptions and full text are indexed in the background. Original manuals and existing PDF catalogs remain untouched.")
                .foregroundStyle(.secondary)
            Text(library.status).font(.caption).accessibilityIdentifier("sourceIndexStatus")
            if let error = library.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            List {
                ForEach(library.coverage) { source in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.root.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("\(source.count) manuals • \(source.problems.isEmpty ? "Scanned" : "Partial or unavailable")").font(.caption)
                        if !source.problems.isEmpty {
                            DisclosureGroup("\(source.problems.count) discovery issues") {
                                ForEach(Array(source.problems.enumerated()), id: \.offset) { _, problem in Text(problem).font(.caption).textSelection(.enabled) }
                            }
                        }
                        if library.additionalRoots.contains(source.root.path) {
                            Button("Remove Added Source") { library.removeRoot(source.root.path) }
                                .accessibilityIdentifier("removeSource-\(source.root.path)")
                        }
                    }.padding(.vertical, 5)
                }
                if !library.problemPages.isEmpty {
                    DisclosureGroup("\(library.problemPages.count) manuals with indexing or formatting issues") {
                        ForEach(library.problemPages) { page in
                            VStack(alignment: .leading) {
                                Text(page.source.path).fontWeight(.semibold)
                                Text(page.problem ?? "")
                            }.font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }.accessibilityIdentifier("sourceCoverage")
            HStack {
                Button("Add Manual Folder…") { addFolder() }.accessibilityIdentifier("addManualSource")
                Button("Refresh Sources") { library.scan() }.disabled(library.isIndexing).accessibilityIdentifier("refreshSources")
                if library.isIndexing { Button("Stop Indexing") { library.stop() }.accessibilityIdentifier("sourcesStop") }
                Spacer()
                Text("Local SQLite index • no network service").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(minWidth: 670, minHeight: 450)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose a directory containing man1, man8, or other manual-section folders."
        if panel.runModal() == .OK, let url = panel.url { library.addRoot(url) }
    }
}
