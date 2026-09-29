import SwiftUI

struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @State private var confirmEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Command Workspace", systemImage: "terminal").font(.headline)
                Text(session.status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("terminalStatus")
                Spacer()
                if session.active {
                    Button("End Session…") { confirmEnd = true }.disabled(session.stopping).accessibilityIdentifier("endTerminalSession")
                }
                Button { session.expanded = false } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Hide command workspace; session continues").accessibilityIdentifier("hideTerminalPane")
            }
            Text("Runs on your Mac with your permissions. This is not a practice sandbox.")
                .font(.caption).foregroundStyle(.secondary)
            if let source = session.draftSource {
                HStack {
                    Text("Draft from \(source.title)").font(.caption).fontWeight(.medium)
                    Text(source.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.accessibilityIdentifier("draftSource")
                if !source.executable.isEmpty {
                    Text("Name resolved on app PATH: \(source.executable) • version compatibility unverified")
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            TextEditor(text: $session.draftText)
                .font(.system(.body, design: .monospaced)).frame(height: 66)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                .accessibilityLabel("Editable command draft").accessibilityIdentifier("commandDraft")
            HStack {
                Text("Run in: \(session.directory.path)").font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .accessibilityIdentifier("draftDirectory")
                Button("Choose Folder…") { chooseFolder() }.accessibilityIdentifier("chooseCommandDirectory")
                Spacer()
                Button("Copy Draft") { copyDraft() }.accessibilityIdentifier("copyDraft")
            }.controlSize(.small)
            if let issue = session.draft.issue {
                Text(issue).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("draftIssue")
            } else {
                Toggle("I reviewed \(session.draft.lineCount) line(s), arguments, quotes, and effects", isOn: $session.reviewed)
                    .font(.caption).toggleStyle(.checkbox).accessibilityIdentifier("reviewCommandDraft")
            }
            HStack {
                Text("\(session.shell) • clean shell, no user startup files").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Start Interactive Shell") { perform { try session.startShell() } }
                    .disabled(session.active || session.stopping).accessibilityIdentifier("startInteractiveShell")
                Button("Run Draft") { perform { try session.runDraft() } }
                    .disabled(session.active || session.stopping || !session.reviewed || session.draft.issue != nil)
                    .accessibilityIdentifier("runCommandDraft")
            }.controlSize(.small)
            if let error = session.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("terminalError") }
            Text(session.active ? "Hide keeps this session running. Closing the browser or quitting ends its shell and attached jobs. End this session to run another draft." : "Run starts a fresh session. Drafts preserve your text exactly; replace placeholders and remove copied prompts. The app cannot recognize every placeholder.")
                .font(.caption2).foregroundStyle(.secondary)
            if let terminal = session.view {
                if let directory = session.startedDirectory {
                    Text("Started in \(directory.path) • current folder may change; use pwd in the terminal")
                        .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("terminalStartDirectory")
                }
                EmbeddedTerminal(terminal: terminal).id(ObjectIdentifier(terminal))
                    .frame(minHeight: 110, maxHeight: .infinity).clipped()
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        .alert("End this terminal session?", isPresented: $confirmEnd) {
            Button("End Session", role: .destructive) { session.stop() }.accessibilityIdentifier("confirmEndTerminal")
            Button("Cancel", role: .cancel) { }.accessibilityIdentifier("cancelEndTerminal")
        } message: { Text("The shell and processes still attached to its session will be stopped. Unsaved work in those programs can be lost.") }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { session.report(error) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = session.directory
        panel.message = "Choose the working folder for the next session."
        if panel.runModal() == .OK, let url = panel.url { session.chooseDirectory(url) }
    }

    private func copyDraft() {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(session.draftText, forType: .string) {
            session.report(TerminalSessionError(message: "The clipboard did not accept the draft."))
        }
    }
}
