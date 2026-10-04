import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @State private var reportError: String?
    @State private var reportMessage: String?
    @State private var exportingCoverage = false
    @State private var exportAnchor = NSView(frame: .zero)
    @AppStorage("manualAppearance") private var appearance = "system"

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
            HStack(alignment: .top, spacing: 12) {
                scanChoice(title: "Standard Scan", explanation: "Start here. Searches configured manual folders, package managers and known developer SDKs.", identifier: "standardScan", action: library.scan)
                scanChoice(title: "Deep Scan", explanation: "Looks throughout local mounted volumes, including hidden folders and apps. Can take a long time; pause and resume anytime.", identifier: "deepScan", action: library.deepScan)
            }
            Text("Network folders are included only when you select them. Cloud-only files are skipped; scanning never downloads them or runs documented commands.")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(library.phase.rawValue, systemImage: library.phase == .indexing ? "text.magnifyingglass" : "folder.badge.gearshape").font(.headline)
                            .accessibilityIdentifier("scanPhase").accessibilityValue(library.phase.rawValue)
                        Spacer()
                        if library.isIndexing {
                            Button(library.phase == .discovering ? "Pause Scan" : "Pause Indexing") { library.stop() }.accessibilityIdentifier("sourcesStop")
                        } else {
                            if library.resumableScan { Button("Resume Discovery") { library.resumeScan() }.accessibilityIdentifier("resumeDiscovery") }
                            if library.pages.contains(where: { !$0.indexed && $0.problem == nil }) {
                                Button("Index Discovered Manuals") { library.continueIndexing() }.accessibilityIdentifier("resumeIndexing")
                            }
                        }
                    }
                    Text(library.status).font(.caption).textSelection(.enabled).accessibilityIdentifier("sourceIndexStatus").accessibilityValue(library.status)
                    if library.phase == .indexing {
                        ProgressView(value: Double(library.indexCompleted), total: Double(max(1, library.indexTotal)))
                            .accessibilityIdentifier("descriptionIndexProgress")
                        Text("Names and reading are ready. Descriptions and full-text search become available as each manual is indexed.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let progress = library.scanProgress {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(progress.path).font(.system(.caption, design: .monospaced)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                .accessibilityIdentifier("discoveryCurrentPath").accessibilityLabel("Current scanning location").accessibilityValue(progress.path)
                        }
                    }
                    if let report = library.performanceReport {
                        Text("Discovery: \(report.discovery.cumulative.filesPerSecond.formatted(.number.precision(.fractionLength(0)))) files/sec • \(report.discovery.cumulative.directoriesPerSecond.formatted(.number.precision(.fractionLength(0)))) folders/sec • \(report.discovery.pendingQueue) queued • peak \(report.discovery.peakPendingQueue)")
                            .font(.caption).monospacedDigit().accessibilityIdentifier("scanPerformanceSummary")
                        Text("Local diagnostics only. Export Coverage saves a separate .performance.json report alongside the coverage file.")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("localDiagnosticsExplanation")
                    }
                    if library.resumableScan, let date = library.checkpointDate {
                        HStack {
                            Text("\(library.pendingLocations) queued locations • checkpoint saved")
                            Text(date, style: .time)
                        }.font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("checkpointStatus")
                        Text("Resume continues the saved traversal. A new scan replaces that checkpoint and rechecks previously visited folders. Queued folder contents are not counted yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("scanProgressPanel")
            }
            if let error = library.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let reportError {
                Text(reportError).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("coverageExportError")
            }
            if let reportMessage {
                Text(reportMessage).font(.caption).textSelection(.enabled).accessibilityIdentifier("coverageExportStatus")
            }
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
                    Section("Measured coverage") {
                        Text("Checked folders and files are counted below. Pending, excluded, inaccessible, failed and unsupported paths are reported separately; these counts do not prove complete-machine coverage.")
                            .font(.caption).foregroundStyle(.secondary)
                        if library.coverage.isEmpty { Text("No scan coverage yet. Choose a scan above to start.").foregroundStyle(.secondary) }
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
            HStack {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system").accessibilityIdentifier("appearanceSystem")
                    Text("Light").tag("light").accessibilityIdentifier("appearanceLight")
                    Text("Dark").tag("dark").accessibilityIdentifier("appearanceDark")
                }.pickerStyle(.segmented).frame(width: 300).accessibilityIdentifier("appAppearance")
                Spacer()
                Button(exportingCoverage ? "Exporting…" : "Export Coverage…") { exportCoverage() }
                    .disabled(exportingCoverage).accessibilityIdentifier("exportCoverage")
            }
            Text("Original files and PDF catalogs are unchanged. Results from earlier scans stay available when a location is inaccessible or a scan is cancelled. Deep scanning can take time; no complete-machine guarantee is made.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 780, minHeight: 700)
            .background(SourceWindowAnchor(view: exportAnchor).frame(width: 0, height: 0))
    }

    private func scanChoice(title: String, explanation: String, identifier: String, action: @escaping () -> Void) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Button(title, action: action).disabled(library.isIndexing).accessibilityIdentifier(identifier)
                Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Select a folder or mounted volume to scan recursively. Selecting a network location authorizes reading that folder."
        if panel.runModal() == .OK, let url = panel.url { library.addRoot(url) }
    }

    private func exportCoverage() {
        guard !exportingCoverage else { return }
        reportError = nil
        reportMessage = nil
        guard let window = exportAnchor.window else {
            reportError = "Cannot open coverage export: Sources & Discovery is not attached to a window. Reopen Scan & Sources and try again."
            return
        }
        exportingCoverage = true
        Task {
            defer { exportingCoverage = false }
            var destination: URL?
            do {
                destination = try await chooseExportDestination(window: window, filename: "ManPages-scan-coverage.json",
                    contentType: .json, title: "Export Scan Coverage", identifier: "coverageExportPanel")
                guard let destination else { return }
                try library.exportCoverage(to: destination)
                reportMessage = "Exported \(destination.lastPathComponent) and its .performance.json diagnostics report"
            } catch {
                if let destination {
                    reportError = "Coverage export did not complete for \(destination.path): \(error.localizedDescription)"
                } else { reportError = "Cannot open coverage export: \(error.localizedDescription)" }
            }
        }
    }
}

private struct SourceWindowAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }

    func updateNSView(_ nsView: NSView, context: Context) { }
}
