import SwiftUI

struct ProgressState: Codable {
    var completed: Int
    var total: Int
    var rendered: Int
    var failed: Int
    var done: Bool
}

struct GenerateView: View {
    @EnvironmentObject var store: CatalogStore
    @Environment(\.dismiss) private var dismiss

    @State private var outputPath: String = UserDefaults.standard.string(forKey: "outputDir") ?? ""
    @State private var process: Process? = nil
    @State private var progressState: ProgressState? = nil
    @State private var isRunning = false
    @State private var statusMessage = ""
    @State private var timer: Timer? = nil
    @State private var showMissingAlert = false

    private var progressFile: URL? {
        guard !outputPath.isEmpty else { return nil }
        return URL(fileURLWithPath: outputPath).appendingPathComponent("progress.json")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Generate Man Page PDFs")
                .font(.title2).fontWeight(.semibold)

            // Output folder picker
            HStack {
                TextField("Output folder…", text: $outputPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRunning)
                Button("Choose…") { chooseFolder() }
                    .disabled(isRunning)
            }

            // Progress
            if let p = progressState {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(p.completed), total: Double(max(p.total, 1)))
                    HStack {
                        Text("\(p.completed) / \(p.total)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("✓ \(p.rendered)  ✗ \(p.failed)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if isRunning {
                ProgressView("Discovering man pages…")
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusMessage.hasPrefix("Error") ? .red : .secondary)
            }

            Spacer()

            // Action buttons
            HStack {
                Button("Cancel") {
                    if isRunning { stopProcess() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isRunning {
                    Button("Stop", role: .destructive) { stopProcess() }
                } else {
                    Button("Generate") { startGenerate() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(outputPath.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .alert("Python or groff not found", isPresented: $showMissingAlert) {
            Button("OK") {}
        } message: {
            Text("Install dependencies first:\n\nbrew install groff ghostscript python")
        }
        .onDisappear { timer?.invalidate() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Output Folder"
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
        }
    }

    private func startGenerate() {
        guard !outputPath.isEmpty else { return }

        guard let python = findPython() else {
            showMissingAlert = true
            return
        }

        let outURL = URL(fileURLWithPath: outputPath)
        store.outputDir = outURL

        let progressPath = outURL.appendingPathComponent("progress.json").path
        progressState = nil
        statusMessage = ""
        isRunning = true

        // Workspace root where manpage_pdf_catalog/ package lives
        let workspaceDir = "/Users/macbookpro/Projects/Manpages"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [
            "-m", "manpage_pdf_catalog",
            "--output-dir", outputPath,
            "--progress-file", progressPath,
            "--jobs", "\(ProcessInfo.processInfo.processorCount)",
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: workspaceDir)
        // Ensure Python can find the package
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = workspaceDir
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env

        proc.terminationHandler = { p in
            DispatchQueue.main.async {
                self.isRunning = false
                self.timer?.invalidate()
                self.pollProgress() // final read
                if p.terminationStatus == 0 {
                    self.statusMessage = "Done. Catalog ready."
                    self.store.reload()
                } else if p.terminationStatus != 15 { // 15 = SIGTERM (user stopped)
                    self.statusMessage = "Error: process exited with code \(p.terminationStatus)"
                }
            }
        }

        do {
            try proc.run()
            process = proc
            startPolling()
        } catch {
            isRunning = false
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func stopProcess() {
        process?.terminate()
        isRunning = false
        timer?.invalidate()
        statusMessage = "Stopped."
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.pollProgress()
        }
    }

    private func pollProgress() {
        guard let url = progressFile,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ProgressState.self, from: data) else { return }
        progressState = state
    }

    private func findPython() -> String? {
        for candidate in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
