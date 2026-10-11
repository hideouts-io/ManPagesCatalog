import Foundation
import AppKit

struct DraftSource: Equatable {
    let title: String
    let path: String
    let executable: String
}

struct CommandDraft: Equatable {
    let text: String
    let source: DraftSource?

    var lineCount: Int { text.components(separatedBy: "\n").count }

    /// This catches common notation, not arbitrary shell semantics or every manual's placeholders.
    var issue: String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a command to review." }
        if text.utf8.count > 65_536 { return "The draft exceeds 64 KB. Use a script file for larger programs." }
        if text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" || $0.value == 127 }) {
            return "Remove control characters or carriage returns before running this draft."
        }
        if text.range(of: #"\{\{[^}]*\}\}|<[A-Za-z_][^<>\n]*>|\[(?:options|arguments)[^\]\n]*\]|\.\.\.|…"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "Replace placeholder notation ({{value}}, <value>, [options], or …) with real arguments. Quote paths containing spaces."
        }
        if text.hasPrefix("$ ") || text.hasPrefix("% ") || text.hasPrefix("# ") {
            return "Remove the copied shell prompt before reviewing the command."
        }
        return nil
    }
}

struct TerminalSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Copies reviewable text and opens Terminal.app; never inserts or executes shell input.
@MainActor
func copyCommandAndOpenSystemTerminal(text: String, completion: @escaping @MainActor (Error?) -> Void) throws {
    guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
        throw TerminalSessionError(message: "Terminal.app could not be located. Use Copy Command and paste into your terminal application.")
    }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else {
        throw TerminalSessionError(message: "The clipboard did not accept the command. Try Copy Command again.")
    }
    NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        Task { @MainActor in completion(error) }
    }
}

/// Snapshot only processes in this PTY's session; never signal unrelated user terminals.
func terminalSessionMembers(sessionID: pid_t) throws -> [pid_t] {
    guard sessionID > 1 else { throw TerminalSessionError(message: "Invalid terminal session identifier.") }
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { throw TerminalSessionError(message: "Cannot enumerate terminal processes: \(String(cString: strerror(errno)))") }
    var pids = [pid_t](repeating: 0, count: Int(capacity) + 256)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0, count < pids.count else {
        throw TerminalSessionError(message: "Cannot obtain a complete process snapshot for terminal cleanup. Try Stop again.")
    }
    return pids.prefix(Int(count)).filter { $0 > 1 && getsid($0) == sessionID }
}

func signalTerminalSession(sessionID: pid_t, signal: Int32) throws {
    // Signal jobs before the shell. Recheck session membership immediately before each signal.
    let members = try terminalSessionMembers(sessionID: sessionID).sorted { $0 != sessionID && $1 == sessionID }
    for pid in members where getsid(pid) == sessionID {
        if kill(pid, signal) != 0 && errno != ESRCH {
            throw TerminalSessionError(message: "Cannot stop terminal process \(pid): \(String(cString: strerror(errno)))")
        }
    }
}
