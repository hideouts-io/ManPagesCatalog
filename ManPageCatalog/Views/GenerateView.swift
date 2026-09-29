import SwiftUI

struct GenerateView: View {
    @EnvironmentObject var store: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var generator: CatalogGenerator
    @State private var outputPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage Catalog").font(.title2).fontWeight(.semibold)
            Text("Generate PDFs, refresh descriptions without changing PDFs, or open an existing catalog.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Catalog folder…", text: $outputPath)
                    .textFieldStyle(.roundedBorder).disabled(generator.isRunning)
                    .accessibilityIdentifier("catalogOutputPath")
                Button("Choose…") { chooseFolder() }.disabled(generator.isRunning)
                    .accessibilityIdentifier("chooseCatalogFolder")
            }
            if let progress = generator.progress {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                Text("\(progress.completed) / \(progress.total) pages")
                    .font(.caption).accessibilityIdentifier("generationProgress")
            }
            if !generator.status.isEmpty {
                Text(generator.status).font(.caption).accessibilityIdentifier("generationStatus")
            }
            if let error = generator.errorMessage {
                ScrollView { Text(error).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 150).accessibilityIdentifier("generationError")
            }
            Text("Uses the macOS man-page formatter. No Python or Homebrew installation is required. You can keep browsing while generation runs.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("closeCatalog")
                Spacer()
                if generator.isRunning {
                    Button("Stop") { generator.stop() }.accessibilityIdentifier("stopGeneration")
                } else {
                    Button("Open Catalog") {
                        store.outputDir = URL(fileURLWithPath: outputPath)
                        dismiss()
                    }.disabled(!validPath).accessibilityIdentifier("openCatalog")
                    Button("Refresh Metadata") {
                        generator.refresh(output: URL(fileURLWithPath: outputPath), store: store)
                    }.disabled(!validPath).accessibilityIdentifier("refreshMetadata")
                    Button("Generate PDFs") {
                        generator.generate(output: URL(fileURLWithPath: outputPath), store: store)
                    }.disabled(!validPath).accessibilityIdentifier("generatePDFs")
                }
            }
        }.padding(24).frame(width: 650)
            .onAppear { outputPath = store.outputDir?.path ?? "" }
            .interactiveDismissDisabled(generator.isRunning)
    }

    private var validPath: Bool { outputPath.hasPrefix("/") }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Catalog Folder"
        if panel.runModal() == .OK, let url = panel.url { outputPath = url.path }
    }
}
