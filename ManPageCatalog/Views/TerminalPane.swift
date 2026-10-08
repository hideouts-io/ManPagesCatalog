import SwiftUI

struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @State private var confirmEnd = false
    @State private var editingDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(12)
            Divider()
            if session.view != nil {
                VSplitView {
                    ScrollView { preparation.padding(14) }.frame(minHeight: 100, idealHeight: 240)
                    output.frame(minHeight: 120, idealHeight: 240)
                }
            } else {
                ScrollView { preparation.padding(14) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            execution.padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(.bar)
        .alert("End this terminal session?", isPresented: $confirmEnd) {
            Button("End Session", role: .destructive) { session.stop() }.accessibilityIdentifier("confirmEndTerminal")
            Button("Cancel", role: .cancel) { }.accessibilityIdentifier("cancelEndTerminal")
        } message: { Text("The shell and processes still attached to its session will be stopped. Unsaved work in those programs can be lost.") }
    }

    private var header: some View {
        HStack {
            Label("Terminal & Command Builder", systemImage: "terminal").font(.headline)
            VStack {
                Text(session.outcome.title).font(.caption).foregroundStyle(session.outcome == .failed ? Color.red : Color.secondary)
                    .accessibilityValue(session.outcome.title).accessibilityIdentifier("terminalOutcome")
            }.accessibilityElement(children: .contain).accessibilityLabel("Terminal outcome")
            Spacer()
            if session.active {
                Button("Interrupt") { perform { try session.interrupt() } }.disabled(session.stopping)
                    .help("Sends Ctrl-C to the foreground program.").accessibilityIdentifier("interruptTerminal")
                Button("End Session…") { confirmEnd = true }.disabled(session.stopping).accessibilityIdentifier("endTerminalSession")
            }
            Button { session.maximized.toggle() } label: { Image(systemName: session.maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel(session.maximized ? "Show manual beside terminal" : "Expand terminal workspace")
                .accessibilityIdentifier("expandTerminalPane")
            Button { session.expanded = false } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Hide terminal workspace; session continues").accessibilityIdentifier("hideTerminalPane")
        }.controlSize(.small)
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.draftSource == nil && session.draftText.isEmpty {
                Label("Start with a manual", systemImage: "book.closed").font(.title3).fontWeight(.semibold)
                Text("Open a command's manual and choose Build Command. Choose an action, fill in its inputs, then review the exact command before Run.")
                Text("You can also type a shell draft below or start an interactive shell.").font(.caption).foregroundStyle(.secondary)
            }
            if let source = session.draftSource {
                Text("Manual: \(source.title)").font(.subheadline).fontWeight(.medium)
                VStack(alignment: .leading) { Text(source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel("Manual source").accessibilityValue(source.path).accessibilityIdentifier("draftSource")
            }
            if let target = session.commandTarget {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.generatedText == nil ? "Manual's command target • draft was edited" : "Command target").font(.subheadline).fontWeight(.semibold)
                    VStack(alignment: .leading) { Text(target.path ?? target.explanation).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel("Command target").accessibilityValue(target.path ?? target.explanation)
                        .accessibilityIdentifier("commandExecutablePath")
                    if target.path != nil {
                        Text("Executable availability is checked before Run. Matching a name or path does not verify its version against this manual.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if session.generatedText != nil && canLocateExecutable(target) {
                        Button("Locate Executable…") { locateExecutable() }.accessibilityIdentifier("locateCommandExecutable")
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if !session.guidedRecipes.isEmpty {
                GuidedCommandBuilderView(session: session)
            } else if session.generatedText != nil, session.commandTarget?.path != nil {
                Text("Guided options are currently available for the macOS ls, du, and diskutil system manuals. For this command, consult its manual and edit the draft or prepare a selected example.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { editingDraft.toggle() } label: {
                Label(session.generatedText != nil ? "Edit shell text (leaves the guided builder)" : "Edit shell draft",
                      systemImage: editingDraft ? "chevron.down" : "chevron.right")
            }.buttonStyle(.plain).accessibilityIdentifier("editShellDraft")
            if editingDraft {
                CommandDraftEditor(text: Binding(get: { session.draftText }, set: { session.editDraft(text: $0) }))
                    .frame(minHeight: 76)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var execution: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.guidedRecipe == nil ? "Review your command" : "3  Review the exact command").font(.headline)
            Text(session.commandSummary).font(.caption).textSelection(.enabled)
            VStack(alignment: .leading) {
                Text(session.commandEffects).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityValue(session.commandEffects).accessibilityIdentifier("commandEffects")
            }.accessibilityElement(children: .contain).accessibilityLabel("Command effects")
            if !session.draftText.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(session.draftText).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel("Exact command preview").accessibilityValue(session.draftText)
                        .accessibilityIdentifier("generatedCommandPreview")
                }.frame(maxHeight: 70).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Working folder").font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button("Choose Folder…") { chooseFolder() }.controlSize(.small)
                        .accessibilityIdentifier("chooseCommandDirectory")
                }
                TextField("Type an absolute folder path", text: Binding(
                    get: { session.workingDirectoryPath },
                    set: { session.setWorkingDirectoryPath($0) }
                )).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Working folder path").accessibilityIdentifier("workingDirectoryPath")
                VStack(alignment: .leading) {
                    Text("Selected for Run: \(session.directory.path)")
                        .font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityLabel("Selected working folder")
                        .accessibilityValue(session.directory.path).accessibilityIdentifier("draftDirectory")
                }.accessibilityElement(children: .contain)
            }
            if let issue = session.runIssue {
                VStack(alignment: .leading) { Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel("Command needs attention").accessibilityValue(issue).accessibilityIdentifier("draftIssue")
            } else {
                Toggle("I reviewed all \(session.draft.lineCount) line(s), inputs, working folder, and effects", isOn: $session.reviewed)
                    .font(.caption).toggleStyle(.checkbox).accessibilityIdentifier("reviewCommandDraft")
            }
            HStack {
                Button("Copy Command") { perform { try session.copyDraft() } }.disabled(session.draftText.isEmpty || session.guidanceIssue != nil).accessibilityIdentifier("copyDraft")
                Button("Open in Terminal") { perform { try session.copyAndOpenTerminal() } }
                    .disabled(session.draftText.isEmpty || session.guidanceIssue != nil)
                    .help("Copies this exact preview and opens Terminal.app for you to paste. Choose its working folder there before running. Nothing is executed.")
                    .accessibilityIdentifier("copyDraftOpenTerminal")
                Spacer()
                Button("Start Interactive Shell") { perform { try session.startShell() } }
                    .disabled(session.active || session.stopping || session.directoryIssue != nil).accessibilityIdentifier("startInteractiveShell")
                Button("Run Command") { perform { try session.runDraft() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.active || session.stopping || !session.reviewed || session.runIssue != nil)
                    .accessibilityIdentifier("runCommandDraft")
            }.controlSize(.small)
            if let error = session.errorMessage {
                VStack(alignment: .leading) { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel("Terminal error").accessibilityValue(error).accessibilityIdentifier("terminalError")
            }
            VStack(alignment: .leading) { Text(session.status).font(.caption).textSelection(.enabled) }
                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel("Terminal status").accessibilityValue(session.status).accessibilityIdentifier("terminalStatus")
            if session.outcome == .failed { Text("Review the output for the error. Check inputs and permissions, then review the command before trying again.").font(.caption).foregroundStyle(.secondary) }
            if session.outcome == .interrupted { Text("The program was interrupted. Review its output; any changes it already made may remain.").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Terminal output").font(.headline)
                Spacer()
                Button("Copy Output") { perform { try session.copyOutput() } }.accessibilityIdentifier("copyTerminalOutput")
            }.controlSize(.small)
            if let directory = session.startedDirectory {
                VStack(alignment: .leading) {
                    Text("Started in \(directory.path) • use pwd in an interactive shell to check its current folder")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("Starting working folder").accessibilityValue(directory.path).accessibilityIdentifier("terminalStartDirectory")
            }
            if let command = session.executedDraft {
                VStack(alignment: .leading) {
                    Text("Executed: \(command)").font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                }.accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("Executed command").accessibilityValue(command).accessibilityIdentifier("executedCommand")
            }
            if let explanation = session.executedResultHelp {
                VStack(alignment: .leading) {
                    Text("Reading the results: \(explanation)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("Reading the results").accessibilityValue(explanation).accessibilityIdentifier("terminalResultHelp")
            }
            if let terminal = session.view {
                EmbeddedTerminal(terminal: terminal).id(ObjectIdentifier(terminal)).frame(minHeight: 100, maxHeight: .infinity).clipped()
            }
        }.padding(12)
    }

    private func canLocateExecutable(_ target: CommandExecutableResolution) -> Bool {
        if case .documentationOnly = target { return false }
        return true
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

    private func locateExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the executable for this manual. Verify its identity and version before Run."
        if panel.runModal() == .OK, let url = panel.url { perform { try session.selectExecutable(url: url) } }
    }
}
