import SwiftUI

struct ManualDetailView: View {
    @EnvironmentObject var terminal: TerminalSession
    @State private var pendingDraft: CommandDraft?
    @State private var pendingCommand: ManualPage?
    @ObservedObject var reader: ManualReader
    @FocusState private var findFocused: Bool
    @State private var showOutline = false
    @State private var showSource = false

    var body: some View {
        VStack(spacing: 0) {
            if let page = reader.page {
                header(page)
                if reader.showFind {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        TextField("Find in \(page.title)…", text: Binding(get: { reader.findQuery }, set: { reader.setFindQuery($0) }))
                            .textFieldStyle(.roundedBorder).focused($findFocused)
                            .accessibilityIdentifier("readerFind")
                            .onSubmit { reader.findNext() }
                        Text(reader.findStatus).font(.caption).accessibilityIdentifier("readerFindStatus")
                            .background {
                                if InteractionDiagnostics.isEnabled {
                                    InteractionViewProbe(operation: reader.findOperation, generation: reader.findGeneration).frame(width: 0, height: 0)
                                }
                            }
                        Button { reader.findPrevious() } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel("Previous match").accessibilityIdentifier("previousMatch")
                        Button { reader.findNext() } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("Next match").accessibilityIdentifier("nextMatch")
                        Button { reader.showFind = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close Find").accessibilityIdentifier("closeReaderFind")
                    }.padding(10).background(.bar)
                }
                if !reader.message.isEmpty {
                    Text(reader.message).font(.caption).textSelection(.enabled).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("readerMessage")
                }
                Divider()
                ZStack {
                    ManualWebView(reader: reader)
                    if reader.loading { ProgressView("Opening \(page.title)…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                    if let error = reader.errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                            Text("Manual unavailable").font(.title2)
                            Text(error).textSelection(.enabled)
                            Button("Retry") { reader.retry() }.accessibilityIdentifier("retryManual")
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                            .accessibilityIdentifier("readerError")
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().interpolation(.high).scaledToFit().frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("Your Mac’s manuals, within reach").font(.title2).fontWeight(.semibold)
                    Text("Find a command, understand its options, and follow its references.\nSearch by name or try a topic such as network.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("⌘K  Search manuals       ⌘F  Find in the open page").font(.caption).foregroundStyle(.secondary)
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            if InteractionDiagnostics.isEnabled {
                InteractionViewProbe(operation: .reader, generation: reader.readerGeneration).frame(width: 0, height: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInPage)) { _ in
            reader.showFind = true
            findFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchCommands)) { _ in findFocused = false }
        .onReceive(NotificationCenter.default.publisher(for: .nextMatch)) { _ in reader.findNext() }
        .onReceive(NotificationCenter.default.publisher(for: .previousMatch)) { _ in reader.findPrevious() }
        .onChange(of: reader.findQuery) { _ in if !reader.loading { reader.findNext() } }
        .onExitCommand { reader.showFind = false }
        .alert("Replace the existing command draft?", isPresented: Binding(get: { pendingDraft != nil || pendingCommand != nil }, set: { if !$0 { pendingDraft = nil; pendingCommand = nil } })) {
            Button("Replace Draft") {
                if let draft = pendingDraft { terminal.prepare(text: draft.text, source: draft.source) }
                else if let page = pendingCommand { terminal.buildCommand(page: page) }
                pendingDraft = nil
                pendingCommand = nil
            }.accessibilityIdentifier(pendingCommand != nil ? "replaceWithGuidedCommand" : "replaceCommandDraft")
            Button("Cancel", role: .cancel) { pendingDraft = nil; pendingCommand = nil }
                .accessibilityIdentifier(pendingCommand != nil ? "cancelGuidedCommand" : "cancelReplaceDraft")
        } message: { Text("Your current draft will be replaced. Preparing or building a command never starts a shell or runs it.") }
    }

    private func header(_ page: ManualPage) -> some View {
        let target = resolveCommandExecutable(name: page.name, section: page.section, environment: ProcessInfo.processInfo.environment)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title).font(.system(.title2, design: .monospaced)).fontWeight(.semibold)
                        .accessibilityIdentifier("readerTitle")
                    if let path = target.path {
                        VStack(alignment: .leading) { Text(path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel("Executable path").accessibilityValue(path)
                            .accessibilityIdentifier("readerExecutablePath").help(target.explanation)
                    } else if case .shellBuiltin = target {
                        Text("zsh built-in • no executable path").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { build(page) } label: { Label("Build Command", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("buildCommand")
                Menu {
                    Button("Prepare Command Name") { build(page) }
                        .accessibilityIdentifier("prepareCommandName")
                    Button("Prepare Selected Example") {
                        Task {
                            do {
                                guard let text = try await reader.webView.evaluateJavaScript("window.getSelection().toString()") as? String, !text.isEmpty else {
                                    throw TerminalSessionError(message: "Select an example in the manual first, then choose Prepare Selected Example.")
                                }
                                prepare(text: text, page: page)
                            } catch { terminal.expanded = true; terminal.report(error) }
                        }
                    }.accessibilityIdentifier("prepareSelectedExample")
                } label: { Label("Prepare", systemImage: "square.and.pencil") }
                .accessibilityIdentifier("prepareCommandMenu")
                Button { showOutline.toggle() } label: { Label("Contents", systemImage: "list.bullet") }
                    .accessibilityIdentifier("readerOutline").disabled(reader.loading)
                    .popover(isPresented: $showOutline) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(reader.headings) { heading in
                                    Button(heading.title) { reader.jump(to: heading); showOutline = false }
                                        .buttonStyle(.plain).accessibilityIdentifier("heading-\(heading.id)")
                                }
                            }.padding()
                        }.frame(width: 280, height: 320)
                    }
                Button { reader.showFind = true; findFocused = true } label: { Label("Find", systemImage: "magnifyingglass") }
                    .accessibilityLabel("Find in Page").accessibilityIdentifier("showReaderFind")
            }
            if !page.description.isEmpty { Text(page.description).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button { showSource.toggle() } label: { Label("Source Details", systemImage: "info.circle") }
                    .accessibilityIdentifier("sourceDetails")
                    .popover(isPresented: $showSource) { sourceDetails(page).padding().frame(width: 440) }
                Spacer()
                Button { reader.reduce() } label: { Image(systemName: "textformat.size.smaller") }
                    .accessibilityLabel("Smaller text").accessibilityIdentifier("smallerText")
                Button { reader.enlarge() } label: { Image(systemName: "textformat.size.larger") }
                    .accessibilityLabel("Larger text").accessibilityIdentifier("largerText")
                Button { reader.exportPDF() } label: { Label(reader.exporting ? "Exporting…" : "Export PDF", systemImage: "square.and.arrow.up") }
                    .disabled(reader.exporting || reader.loading).accessibilityIdentifier("exportPDF")
                Menu {
                    Button("Copy Command Name") { reader.copy(page.name) }
                        .accessibilityIdentifier("copyCommandName")
                    Button("Copy Source Path") { reader.copy(page.source.path) }
                        .accessibilityIdentifier("copySourcePath")
                    Button("Copy Selected Text / Example") { reader.copySelection() }
                        .accessibilityIdentifier("copySelectedText")
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("copyMenu")
                Button("Copy & Open Terminal") { reader.copyCommandAndOpenTerminal() }
                    .help("Copies the verified absolute executable path, or an identified shell built-in, and opens Terminal for you to paste.")
                    .disabled(!["1", "8"].contains(String(page.section.prefix(1))))
                    .accessibilityIdentifier("copyOpenTerminal")
            }.controlSize(.small)
        }.padding(16).background(.bar)
    }

    private func prepare(text: String, page: ManualPage) {
        let source = DraftSource(title: page.title, path: page.source.path,
                                 executable: executablePath(name: page.name, section: page.section, environment: ProcessInfo.processInfo.environment))
        if terminal.draftText.isEmpty { terminal.prepare(text: text, source: source) }
        else { pendingDraft = CommandDraft(text: text, source: source) }
    }

    private func build(_ page: ManualPage) {
        if terminal.draftText.isEmpty { terminal.buildCommand(page: page) }
        else { pendingCommand = page }
    }

    private func sourceDetails(_ page: ManualPage) -> some View {
        let target = resolveCommandExecutable(name: page.name, section: page.section, environment: ProcessInfo.processInfo.environment)
        let executable = target.path ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            Text("Original documentation").font(.headline)
            Text(page.source.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Collection: \(page.root.path)\nLanguage: \(page.language == "unspecified" ? "Not declared" : page.language)").font(.caption).textSelection(.enabled)
            if page.locations.count > 1 {
                DisclosureGroup("\(page.locations.count) locations / aliases with identical content") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(page.locations, id: \.source) { location in
                                Text("\(location.name)(\(location.section)) • \(location.language)\n\(location.source.path)")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }.frame(maxHeight: 180)
                }.accessibilityIdentifier("manualLocations")
            }
            Text("Identical content is grouped above. Different content versions remain separate search results; compare their original headers and source paths.\n\(sectionLabel(page.section))").font(.caption)
            Button("Reveal Source in Finder") { NSWorkspace.shared.activateFileViewerSelecting([page.source]) }
                .accessibilityIdentifier("revealManualSource")
            if executable.isEmpty {
                Text(target.explanation).font(.caption).foregroundStyle(.secondary)
            } else {
                Divider()
                Text("Executable found on PATH").font(.headline)
                Text(executable).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("A matching name does not prove this manual describes that executable version.").font(.caption).foregroundStyle(.secondary)
                Button("Copy Executable Path") { reader.copy(executable) }.accessibilityIdentifier("copyExecutable")
            }
        }
    }
}
