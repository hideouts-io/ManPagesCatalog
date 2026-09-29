import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @State private var reportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sources & Discovery").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Search Manuals") {
                    openWindow(id: "browser")
                    NotificationCenter.default.post(name: .searchCommands, object: nil)
                }.accessibilityIdentifier("sourcesSearch")
            }
            Text("Standard Scan searches configured and common manual folders. Deep Scan explores local volumes, including hidden folders and apps. Network folders require explicit selection; cloud-only files remain undownloaded.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Standard Scan") { library.scan() }.disabled(library.isIndexing).accessibilityIdentifier("standardScan")
                Button("Deep Scan") { library.deepScan() }.disabled(library.isIndexing).accessibilityIdentifier("deepScan")
                if library.isIndexing { Button("Cancel Scan / Indexing") { library.stop() }.accessibilityIdentifier("sourcesStop") }
                Spacer()
                Button("Export Coverage…") { exportCoverage() }.accessibilityIdentifier("exportCoverage")
            }
            Text(library.status).font(.caption).accessibilityIdentifier("sourceIndexStatus").accessibilityValue(library.status)
            if let progress = library.scanProgress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress.path).font(.system(.caption, design: .monospaced)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityIdentifier("discoveryCurrentPath").accessibilityLabel("Current scanning location").accessibilityValue(progress.path)
                }
            }
            if let error = library.errorMessage ?? reportError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Section("Selected folders / volumes") {
                        ForEach(library.additionalRoots, id: \.self) { path in
                            HStack {
                                Text(path).textSelection(.enabled)
                                Spacer()
                                Button("Remove") { library.removeRoot(path) }.disabled(library.isIndexing).accessibilityIdentifier("removeSource-\(path)")
                            }
                        }
                        HStack {
                            Button("Add Folder or Volume…") { addFolder() }.disabled(library.isIndexing).accessibilityIdentifier("addManualSource")
                            Button("Scan Selected Folders") { library.scanSelectedRoots() }.disabled(library.isIndexing || library.additionalRoots.isEmpty)
                                .accessibilityIdentifier("scanSelectedRoots")
                        }
                    }
                    Section("Latest scan coverage — exclusions mean coverage is incomplete") {
                        ForEach(library.coverage) { source in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.root.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Text("\(source.completed ? "Traversal finished" : "Not fully traversed") • \(source.directories) folders • \(source.files) files checked • \(source.count) manual locations").font(.caption)
                                ForEach(CoverageKind.allCases, id: \.self) { kind in
                                    let issues = source.issues.filter { $0.kind == kind }
                                    if !issues.isEmpty {
                                        DisclosureGroup("\(kind.rawValue.capitalized): \(issues.count)") {
                                            ForEach(Array(issues.prefix(100).enumerated()), id: \.offset) { _, issue in
                                                Text("\(issue.path)\n\(issue.reason)").font(.caption).textSelection(.enabled)
                                            }
                                            if issues.count > 100 { Text("First 100 shown. Export Coverage includes every recorded location.").font(.caption) }
                                        }.accessibilityIdentifier("coverage-\(kind.rawValue)-\(source.root.path)")
                                    }
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                    if !library.problemPages.isEmpty {
                        DisclosureGroup("\(library.problemPages.count) manuals with indexing or formatting issues") {
                            ForEach(library.problemPages) { page in
                                Text("\(page.source.path)\n\(page.problem ?? "")").font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.accessibilityIdentifier("sourceCoverage")
            Text("Original files and PDF catalogs are unchanged. Results from earlier scans stay available when a location is inaccessible or a scan is cancelled. Deep scanning can take time; no complete-machine guarantee is made.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 740, minHeight: 560)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Select a folder or mounted volume to scan recursively. Selecting a network location authorizes reading that folder."
        if panel.runModal() == .OK, let url = panel.url { library.addRoot(url) }
    }

    private func exportCoverage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ManPages-scan-coverage.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library.coverage).write(to: url, options: .atomic)
            reportError = nil
        } catch { reportError = "Cannot write coverage report to \(url.path): \(error.localizedDescription)" }
    }
}
