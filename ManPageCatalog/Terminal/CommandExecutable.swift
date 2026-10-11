import Foundation
import Darwin

func quotedShellWord(_ word: String) -> String {
    "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// An executable match establishes local availability, not compatibility with a manual's version.
enum CommandExecutableResolution: Equatable {
    case executable(path: String)
    case shellBuiltin(name: String)
    case unavailable(reason: String)
    case documentationOnly(reason: String)

    var path: String? {
        if case .executable(let path) = self { return path }
        return nil
    }

    var explanation: String {
        switch self {
        case .executable(let path):
            return "Executable verified at \(path). Its version and options may differ from this manual."
        case .shellBuiltin(let name):
            return "\(name) is a zsh shell built-in and has no executable path. Its options may differ from this manual."
        case .unavailable(let reason), .documentationOnly(let reason):
            return reason
        }
    }
}

enum CommandExecutableError: LocalizedError {
    case invalidPath
    case relativePath(path: String)
    case cannotInspect(path: String, code: Int32)
    case notRegularFile(path: String)
    case notExecutable(path: String, code: Int32)
    case unavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "The executable path is empty or contains a control character. Choose an executable file using the file picker."
        case .relativePath(let path):
            return "\(path) is a relative executable path. Choose the executable's absolute path using the file picker."
        case .cannotInspect(let path, let code):
            return "Cannot inspect executable \(path): \(String(cString: strerror(code))) (\(code)). Locate the installed executable and prepare the command again."
        case .notRegularFile(let path):
            return "\(path) is not a regular executable file. Choose an executable file rather than a folder or device."
        case .notExecutable(let path, let code):
            return "Cannot execute \(path): \(String(cString: strerror(code))) (\(code)). Choose an executable that your account can run."
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Resolve only a command name against explicit absolute PATH entries; never run the command.
func resolveCommandExecutable(name: String, section: String, environment: [String: String]) -> CommandExecutableResolution {
    guard isCommandManualSection(section) else {
        return .documentationOnly(reason: "Section \(section) documents an API, format, or other reference rather than a shell command. Select a command manual to build a runnable command.")
    }
    guard isCommandExecutableName(name) else {
        return .unavailable(reason: "The manual name is not a single command name. Choose an executable file or select a command manual; copied examples remain editable without automatic rewriting.")
    }
    // System wrappers such as /usr/bin/cd cannot change this terminal shell's state.
    if isShellContextBuiltin(name) { return .shellBuiltin(name: name) }
    if let searchPath = environment["PATH"] {
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) where directory.hasPrefix("/") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).standardizedFileURL.path
            do {
                try verifyCommandExecutable(path: path)
                return .executable(path: path)
            } catch let error as CommandExecutableError {
                // PATH search continues past unavailable entries, as the shell does.
                switch error {
                case .cannotInspect, .notRegularFile, .notExecutable, .invalidPath, .relativePath:
                    continue
                case .unavailable:
                    return .unavailable(reason: error.localizedDescription)
                }
            } catch {
                return .unavailable(reason: "Cannot resolve \(name): \(error.localizedDescription). Choose an executable file and prepare the command again.")
            }
        }
    }
    if isKnownZshBuiltin(name) { return .shellBuiltin(name: name) }
    guard environment["PATH"] != nil else {
        return .unavailable(reason: "This app's environment has no PATH to locate \(name). Choose the installed executable using the file picker, or launch the app with its installation folder in PATH.")
    }
    return .unavailable(reason: "No executable file for \(name) was found in the absolute folders in this app's PATH. Choose its installed executable using the file picker, or add its installation folder to PATH and reopen the app. Relative and empty PATH entries are not used for generated commands.")
}

/// Recheck the selected exact path immediately before copying or running a generated command.
/// Follows symlinks to support installed command aliases, but rejects nonregular and inaccessible targets.
func verifyCommandExecutable(path: String) throws {
    guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
        throw CommandExecutableError.invalidPath
    }
    guard path.hasPrefix("/") else { throw CommandExecutableError.relativePath(path: path) }
    var metadata = stat()
    guard stat(path, &metadata) == 0 else {
        throw CommandExecutableError.cannotInspect(path: path, code: errno)
    }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw CommandExecutableError.notRegularFile(path: path)
    }
    guard access(path, X_OK) == 0 else {
        throw CommandExecutableError.notExecutable(path: path, code: errno)
    }
}

/// Generate only the resolved target word. Arguments and user-written shell text stay separate.
func generatedCommandText(target: CommandExecutableResolution) throws -> String {
    switch target {
    case .executable(let path):
        try verifyCommandExecutable(path: path)
        return quotedShellWord(path)
    case .shellBuiltin(let name):
        guard isKnownZshBuiltin(name) else {
            throw CommandExecutableError.unavailable(reason: "\(name) is not a verified zsh built-in. Select a command manual or choose an executable file.")
        }
        return "builtin " + quotedShellWord(name)
    case .unavailable(let reason), .documentationOnly(let reason):
        throw CommandExecutableError.unavailable(reason: reason)
    }
}

private func isCommandManualSection(_ section: String) -> Bool {
    guard let first = section.first, first == "1" || first == "8" else { return false }
    return section.dropFirst().unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
}

private func isCommandExecutableName(_ name: String) -> Bool {
    if [".", ":", "["].contains(name) { return true }
    guard !name.isEmpty, name != ".." else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.+-")
    return name.unicodeScalars.allSatisfy { allowed.contains($0) }
}

private func isKnownZshBuiltin(_ name: String) -> Bool {
    // Verified locally with /bin/zsh -f and `builtin whence -w`; -f still allows /etc/zshenv.
    // Resolution uses this fixed list without launching a shell or evaluating command text.
    let builtins: Set<String> = [".", ":", "[", "alias", "bg", "bindkey", "break", "builtin", "cd", "command", "continue",
                                 "dirs", "echo", "eval", "export", "false", "fc", "fg", "getopts", "hash", "history", "jobs", "kill",
                                 "let", "local", "popd", "printf", "pushd", "pwd", "read", "readonly", "return", "set",
                                 "shift", "source", "test", "true", "type", "typeset", "ulimit", "umask", "unalias", "unhash", "unset", "wait", "whence"]
    return builtins.contains(name)
}

private func isShellContextBuiltin(_ name: String) -> Bool {
    guard isKnownZshBuiltin(name) else { return false }
    let externalEquivalents: Set<String> = ["[", "echo", "false", "kill", "printf", "pwd", "test", "true"]
    return !externalEquivalents.contains(name)
}
