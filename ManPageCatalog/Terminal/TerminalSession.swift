import SwiftUI
import SwiftTerm
import Darwin

enum TerminalOutcome: Equatable {
    case idle, running, completed, failed, interrupted, ended

    var title: String {
        switch self {
        case .idle: return "Ready to prepare"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .ended: return "Session ended"
        }
    }
}

/// A single explicitly started PTY. Draft runs use a fresh shell, never inject into an existing prompt.
@MainActor
final class TerminalSession: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    @Published var expanded = false
    @Published var maximized = false
    @Published var draftText = "" {
        didSet {
            reviewed = false
            if let generatedText, draftText != generatedText {
                self.generatedText = nil
                guidedRecipes = []
                guidedRecipeID = nil
                guidanceIssue = nil
            }
        }
    }
    @Published var reviewed = false
    @Published private(set) var draftSource: DraftSource?
    @Published private(set) var directory = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var workingDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published private(set) var directoryIssue: String?
    @Published private(set) var view: TerminalView?
    @Published private(set) var active = false
    @Published private(set) var stopping = false
    @Published private(set) var status = "No session started"
    @Published private(set) var errorMessage: String?
    @Published private(set) var startedDirectory: URL?
    @Published private(set) var commandTarget: CommandExecutableResolution?
    @Published private(set) var guidedRecipes: [GuidedCommandRecipe] = []
    @Published private(set) var guidedRecipeID: String?
    @Published private(set) var guidedOptions: Set<String> = []
    @Published private(set) var guidedInputs: [String: String] = [:]
    @Published private(set) var guidanceIssue: String?
    @Published private(set) var generatedText: String?
    @Published private(set) var outcome: TerminalOutcome = .idle
    @Published private(set) var executedDraft: String?
    @Published private(set) var executedResultHelp: String?
    let shell = "/bin/zsh"
    private(set) var process: LocalProcess?
    private var bridge: TerminalProcessBridge?
    private var stopTask: Task<Void, Never>?
    private var commandName = ""
    private var commandDescription = ""
    private var interruptRequested = false

    var draft: CommandDraft { CommandDraft(text: draftText, source: draftSource) }
    /// Structured, quoted arguments are literal values; placeholder heuristics apply only to raw shell drafts.
    var runIssue: String? {
        if let issue = directoryIssue { return issue }
        if let issue = guidanceIssue { return issue }
        if generatedText != nil {
            if draftText.isEmpty { return "Complete the command inputs before review." }
            if draftText.utf8.count > 65_536 { return "The command exceeds 64 KB. Shorten its inputs before Run." }
            return nil
        }
        return draft.issue
    }
    var guidedRecipe: GuidedCommandRecipe? { guidedRecipes.first { $0.id == guidedRecipeID } }
    var commandSummary: String {
        if let recipe = guidedRecipe { return recipe.summary }
        if generatedText != nil { return commandDescription.isEmpty ? "Prepare \(commandName) using the selected command target." : commandDescription }
        return "An editable shell draft. Review every command and argument using its documentation."
    }
    var commandEffects: String {
        if let recipe = guidedRecipe { return recipe.effects }
        return "Runs on your Mac with your permissions. Review the documentation for file changes, network access, or administrator requirements."
    }

    func prepare(text: String, source: DraftSource?) {
        // The caller explicitly chooses Replace when a nonempty draft already exists.
        generatedText = nil
        commandTarget = nil
        guidedRecipes = []
        guidedRecipeID = nil
        guidanceIssue = nil
        draftText = text
        draftSource = source
        expanded = true
        errorMessage = nil
    }

    /// Builds new text only from an explicitly selected manual; examples remain exact shell drafts.
    func buildCommand(page: ManualPage) {
        commandName = page.name
        commandDescription = page.description
        commandTarget = resolveCommandExecutable(name: page.name, section: page.section, environment: ProcessInfo.processInfo.environment)
        draftSource = DraftSource(title: page.title, path: page.source.path, executable: commandTarget?.path ?? "")
        guidedOptions = []
        guidedInputs = [:]
        refreshRecipes()
        regenerateCommand()
        expanded = true
        errorMessage = nil
    }

    func selectExecutable(url: URL) throws {
        guard url.isFileURL else { throw TerminalSessionError(message: "Choose a local executable file.") }
        guard generatedText != nil, commandTarget != nil, let source = draftSource else {
            throw TerminalSessionError(message: "Choose Build Command in a manual before locating its executable.")
        }
        if let target = commandTarget, case .documentationOnly(let reason) = target { throw TerminalSessionError(message: reason) }
        let path = url.standardizedFileURL.path
        try verifyCommandExecutable(path: path)
        commandTarget = .executable(path: path)
        draftSource = DraftSource(title: source.title, path: source.path, executable: path)
        guidedOptions = []
        guidedInputs = [:]
        refreshRecipes()
        regenerateCommand()
    }

    private func refreshRecipes() {
        guidedRecipes = guidedCommandRecipes(name: commandName, executablePath: commandTarget?.path ?? "", manualSourcePath: draftSource?.path ?? "")
        guidedRecipeID = guidedRecipes.first?.id
    }

    func selectGuidedRecipe(id: String) {
        guard guidedRecipes.contains(where: { $0.id == id }) else {
            report(TerminalSessionError(message: "The selected guided action is unavailable. Choose an action shown in this workspace."))
            return
        }
        guidedRecipeID = id
        guidedOptions = []
        guidedInputs = [:]
        regenerateCommand()
    }

    func setGuidedOption(id: String, selected: Bool) {
        guard generatedText != nil, let recipe = guidedRecipe, recipe.options.contains(where: { $0.id == id }) else {
            report(TerminalSessionError(message: "This option is unavailable in the current builder. Choose Build Command to start a guided action."))
            return
        }
        guidedOptions = selected ? guidedOptions.union([id]) : guidedOptions.subtracting([id])
        regenerateCommand()
    }

    func setGuidedInput(id: String, value: String) {
        guard generatedText != nil, let recipe = guidedRecipe, recipe.inputs.contains(where: { $0.id == id }) else {
            report(TerminalSessionError(message: "This input is unavailable in the current builder. Choose Build Command to start a guided action."))
            return
        }
        guidedInputs = guidedInputs.merging([id: value]) { _, new in new }
        regenerateCommand()
    }

    func editDraft(text: String) { draftText = text }

    private func regenerateCommand() {
        reviewed = false
        do {
            guard let target = commandTarget else { throw TerminalSessionError(message: "Choose a command target first.") }
            let text: String
            if let recipe = guidedRecipe, let path = target.path {
                let arguments = try guidedCommandArguments(recipe: recipe, selectedOptions: guidedOptions, inputs: guidedInputs)
                try verifyGuidedInputs(recipe: recipe)
                text = guidedCommandText(executablePath: path, arguments: arguments)
            } else { text = try generatedCommandText(target: target) }
            generatedText = text
            draftText = text
            guidanceIssue = nil
        } catch {
            generatedText = ""
            draftText = ""
            guidanceIssue = error.localizedDescription
        }
    }

    private func verifyGeneratedCommand() throws {
        if let issue = guidanceIssue { throw TerminalSessionError(message: issue) }
        if generatedText != nil, let path = commandTarget?.path { try verifyCommandExecutable(path: path) }
        if generatedText != nil, let recipe = guidedRecipe { try verifyGuidedInputs(recipe: recipe) }
    }

    private func verifyGuidedInputs(recipe: GuidedCommandRecipe) throws {
        for input in recipe.inputs where input.kind != .text {
            guard let path = guidedInputs[input.id], !path.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw TerminalSessionError(message: "\(input.title) does not exist at \(path). Choose an existing \(input.kind.rawValue) before Run.")
            }
            guard isDirectory.boolValue == (input.kind == .directory) else {
                throw TerminalSessionError(message: "\(input.title) must be a \(input.kind.rawValue). Choose the correct item for \(path).")
            }
        }
    }

    func copyDraft() throws {
        try verifyGeneratedCommand()
        guard !draftText.isEmpty else { throw TerminalSessionError(message: "Prepare a command before copying it.") }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(draftText, forType: .string) else {
            throw TerminalSessionError(message: "The clipboard did not accept the command preview. Try Copy Command again.")
        }
    }

    func copyAndOpenTerminal() throws {
        try verifyGeneratedCommand()
        guard !draftText.isEmpty else { throw TerminalSessionError(message: "Prepare a command before opening Terminal.") }
        try copyCommandAndOpenSystemTerminal(text: draftText) { [weak self] error in
            if let error { self?.report(TerminalSessionError(message: "Cannot open Terminal: \(error.localizedDescription) The command remains on the clipboard.")) }
        }
    }

    func setWorkingDirectoryPath(_ path: String) {
        workingDirectoryPath = path
        reviewed = false
        do {
            directory = try verifiedWorkingDirectory(path: path)
            directoryIssue = nil
        } catch {
            directoryIssue = error.localizedDescription
        }
    }

    func chooseDirectory(_ url: URL) {
        setWorkingDirectoryPath(url.path)
    }

    private func verifiedWorkingDirectory(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw TerminalSessionError(message: "Enter an absolute working folder path without control characters, or choose a folder.")
        }
        guard path.utf8.count <= 4_096 else {
            throw TerminalSessionError(message: "The working folder path exceeds 4,096 bytes. Choose a shorter absolute path.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw TerminalSessionError(message: "Working folder \(path) does not exist. Enter an existing absolute path or choose a folder.")
        }
        guard isDirectory.boolValue else {
            throw TerminalSessionError(message: "Working folder \(path) is a file. Enter a folder path or choose a folder.")
        }
        guard access(path, X_OK) == 0 else {
            throw TerminalSessionError(message: "Cannot enter working folder \(path): \(String(cString: strerror(errno))). Choose an accessible folder.")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    func runDraft() throws {
        try verifyGeneratedCommand()
        if let issue = runIssue { throw TerminalSessionError(message: issue) }
        guard reviewed else { throw TerminalSessionError(message: "Review the draft and its working folder before choosing Run.") }
        let selectedDirectory = try verifiedWorkingDirectory(path: workingDirectoryPath)
        guard selectedDirectory.path == directory.path else {
            reviewed = false
            throw TerminalSessionError(message: "The working folder changed since it was selected. Enter or choose it again, then review the command.")
        }
        // An explicit cd also makes a directory disappearing between validation and fork fail visibly.
        let script = "builtin cd -- \(quotedShellWord(selectedDirectory.path)) || exit\n" + draftText
        try start(arguments: ["-f", "-c", script], label: "Running reviewed draft")
        executedDraft = draftText
        executedResultHelp = guidedRecipe?.resultHelp
        reviewed = false
    }

    func startShell() throws {
        try start(arguments: ["-f", "-i"], label: "Interactive shell • type commands directly")
        executedDraft = nil
        executedResultHelp = nil
    }

    private func start(arguments: [String], label: String) throws {
        guard !active && !stopping else {
            throw TerminalSessionError(message: "End the current session before running a draft or starting another shell.")
        }
        if let issue = directoryIssue { throw TerminalSessionError(message: issue) }
        let selectedDirectory = try verifiedWorkingDirectory(path: workingDirectoryPath)
        guard selectedDirectory.path == directory.path else {
            throw TerminalSessionError(message: "The working folder changed since it was selected. Enter or choose it again before starting a session.")
        }
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            throw TerminalSessionError(message: "The system shell is unavailable at \(shell).")
        }
        // URL resource values describe the symlink itself for macOS aliases such as /tmp.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              access(directory.path, X_OK) == 0 else {
            throw TerminalSessionError(message: "Cannot enter \(directory.path). Choose an accessible working folder.")
        }
        let terminal = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 230))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeForegroundColor = .textColor
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminal.linkReporting = .none
        terminal.terminalDelegate = self
        terminal.setAccessibilityIdentifier("embeddedTerminal")
        terminal.setAccessibilityLabel("Local terminal, commands run on this Mac")
        view = terminal
        let bridge = TerminalProcessBridge(owner: self)
        self.bridge = bridge
        let child = LocalProcess(delegate: bridge, dispatchQueue: DispatchQueue.main)
        process = child
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["HISTFILE"] = "/dev/null"
        environment["SAVEHIST"] = "0"
        environment["SHELL"] = shell
        environment["PWD"] = directory.path
        child.startProcess(executable: shell, args: arguments, environment: environment.map { "\($0.key)=\($0.value)" }.sorted(), execName: "zsh", currentDirectory: directory.path)
        guard child.shellPid > 1 else {
            process = nil
            throw TerminalSessionError(message: "Cannot allocate a pseudo-terminal: \(String(cString: strerror(errno)))")
        }
        startedDirectory = directory
        active = true
        outcome = .running
        interruptRequested = false
        errorMessage = nil
        status = label
        expanded = true
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription; expanded = true }

    /// Sends the terminal interrupt character to its foreground program without injecting shell text.
    func interrupt() throws {
        guard active, !stopping, let process else { throw TerminalSessionError(message: "There is no running terminal program to interrupt.") }
        process.send(data: [3])
        interruptRequested = true
        status = "Interrupt requested • waiting for the program"
    }

    func copyOutput() throws {
        guard let view else { throw TerminalSessionError(message: "Run a command or start a shell before copying terminal output.") }
        let output = terminalOutputText(terminal: view.getTerminal())
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(output, forType: .string) else {
            throw TerminalSessionError(message: "The clipboard did not accept terminal output. Try Copy Output again.")
        }
    }

    /// Hiding preserves the session; End, closing the browser, and quitting end its process session.
    func stop() {
        guard let child = process, active, !stopping else { return }
        stopping = true
        status = "Ending session…"
        let sessionID = child.shellPid
        stopTask = Task {
            do {
                try signalTerminalSession(sessionID: sessionID, signal: SIGHUP)
                try await Task.sleep(nanoseconds: 500_000_000)
                try signalTerminalSession(sessionID: sessionID, signal: SIGKILL)
                for _ in 0..<100 where active { try await Task.sleep(nanoseconds: 10_000_000) }
                guard !active else { throw TerminalSessionError(message: "The terminal has not reported process exit. Retry End Session.") }
                stopping = false
            } catch {
                stopping = false
                report(error)
            }
        }
    }

    /// App termination cannot leave an asynchronous cleanup task behind.
    func shutdown() {
        guard let child = process, active else { return }
        do {
            try signalTerminalSession(sessionID: child.shellPid, signal: SIGKILL)
            var result: Int32 = 0
            if waitpid(child.shellPid, &result, 0) < 0 && errno != ECHILD {
                throw TerminalSessionError(message: "Cannot reap terminal process: \(String(cString: strerror(errno)))")
            }
            active = false
        } catch { report(error) }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === process else { return }
        active = false
        if let code = exitCode {
            let signal = code & 0x7f
            let exit = (code >> 8) & 0xff
            status = signal == 0 ? "Session ended • exit \((code >> 8) & 0xff)" : "Session ended • signal \(signal)"
            outcome = stopping ? .ended : signal == SIGINT || interruptRequested && exit == 130 ? .interrupted : signal == 0 && exit == 0 ? .completed : .failed
        } else { status = "Session ended without an exit status"; outcome = .failed }
        do { try signalTerminalSession(sessionID: source.shellPid, signal: SIGKILL) }
        catch { report(error) }
        // Keep the connection alive to drain final PTY output; replaced only on an explicit new session.
    }

    func dataReceived(slice: ArraySlice<UInt8>) { view?.feed(byteArray: slice) }

    func getWindowSize() -> winsize {
        let terminal = view?.getTerminal()
        return winsize(ws_row: UInt16(terminal?.rows ?? 24), ws_col: UInt16(terminal?.cols ?? 80), ws_xpixel: 0, ws_ypixel: 0)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let child = process, active, child.childfd >= 0 else { return }
        var size = getWindowSize()
        if PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: child.childfd, windowSize: &size) != 0 {
            report(TerminalSessionError(message: "Cannot resize terminal: \(String(cString: strerror(errno)))"))
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if active && !stopping { process?.send(data: data) }
    }

    // Terminal escape sequences are not trusted application actions or verified filesystem context.
    func setTerminalTitle(source: TerminalView, title: String) { }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
    func scrolled(source: TerminalView, position: Double) { }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { }
}

/// A distinct weak delegate per connection prevents late output from reaching a newer terminal.
@MainActor
private final class TerminalProcessBridge: @preconcurrency LocalProcessDelegate {
    weak var owner: TerminalSession?
    init(owner: TerminalSession) { self.owner = owner }
    func dataReceived(slice: ArraySlice<UInt8>) { owner?.dataReceived(slice: slice) }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { owner?.processTerminated(source, exitCode: exitCode) }
    func getWindowSize() -> winsize { owner?.getWindowSize() ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
}

struct EmbeddedTerminal: NSViewRepresentable {
    let terminal: TerminalView
    func makeNSView(context: Context) -> TerminalView {
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        return terminal
    }
    func updateNSView(_ nsView: TerminalView, context: Context) { }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 760, height: proposal.height ?? 140)
    }
}

/// SwiftTerm 1.x supplies selection but its macOS accessibility service is a stub.
/// Expose readable terminal text and keyboard focus without treating AX text edits as shell input.
final class AccessibleTerminalView: TerminalView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? {
        terminalOutputText(terminal: getTerminal())
    }
    override func accessibilitySelectedText() -> String? { getSelection() }
    override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }
}

/// SwiftTerm clamps the requested final row to the retained active buffer. Its text API
/// preserves blank cells and wide characters, and rejoins visually wrapped lines.
func terminalOutputText(terminal: Terminal) -> String {
    terminal.getText(start: Position(col: 0, row: 0), end: Position(col: terminal.cols, row: Int.max))
}
