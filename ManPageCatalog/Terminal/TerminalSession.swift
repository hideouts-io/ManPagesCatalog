import SwiftUI
import SwiftTerm
import Darwin

/// A single explicitly started PTY. Draft runs use a fresh shell, never inject into an existing prompt.
@MainActor
final class TerminalSession: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    @Published var expanded = false
    @Published var draftText = "" { didSet { reviewed = false } }
    @Published var reviewed = false
    @Published private(set) var draftSource: DraftSource?
    @Published private(set) var directory = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var view: TerminalView?
    @Published private(set) var active = false
    @Published private(set) var stopping = false
    @Published private(set) var status = "No session started"
    @Published private(set) var errorMessage: String?
    @Published private(set) var startedDirectory: URL?
    let shell = "/bin/zsh"
    private(set) var process: LocalProcess?
    private var bridge: TerminalProcessBridge?
    private var stopTask: Task<Void, Never>?

    var draft: CommandDraft { CommandDraft(text: draftText, source: draftSource) }

    func prepare(text: String, source: DraftSource?) {
        // The caller explicitly chooses Replace when a nonempty draft already exists.
        draftText = text
        draftSource = source
        expanded = true
        errorMessage = nil
    }

    func chooseDirectory(_ url: URL) {
        directory = url.resolvingSymlinksInPath().standardizedFileURL
        reviewed = false
    }

    func runDraft() throws {
        if let issue = draft.issue { throw TerminalSessionError(message: issue) }
        guard reviewed else { throw TerminalSessionError(message: "Review the draft and its working folder before choosing Run.") }
        // An explicit cd also makes a directory disappearing between validation and fork fail visibly.
        let script = "builtin cd -- \(quotedShellWord(directory.path)) || exit\n" + draftText
        try start(arguments: ["-f", "-c", script], label: "Running reviewed draft")
        reviewed = false
    }

    func startShell() throws {
        try start(arguments: ["-f", "-i"], label: "Interactive shell • type commands directly")
    }

    private func start(arguments: [String], label: String) throws {
        guard !active && !stopping else {
            throw TerminalSessionError(message: "End the current session before running a draft or starting another shell.")
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
        errorMessage = nil
        status = label
        expanded = true
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription; expanded = true }

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
            status = signal == 0 ? "Session ended • exit \((code >> 8) & 0xff)" : "Session ended • signal \(signal)"
        } else { status = "Session ended without an exit status" }
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
        String(decoding: getTerminal().getBufferAsData(kind: .active, encoding: .utf8), as: UTF8.self)
            .replacingOccurrences(of: "\0", with: "")
    }
    override func accessibilitySelectedText() -> String? { getSelection() }
    override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }
}
