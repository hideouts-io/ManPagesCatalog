import XCTest
import Darwin
@testable import Man_Page_Catalog

final class CommandExecutableIntegrationTests: XCTestCase {
    func testVerifiedPathWithSpacesAndShellCharactersExecutesOnlyAfterPreparation() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let bin = directory.appendingPathComponent("bin with 'quote' $value ; literal")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("sample-tool")
        let marker = directory.appendingPathComponent("prepared marker.txt")
        let script = "#!/bin/sh\nprintf 'ran' > \(quotedShellWord(marker.path))\nprintf '%s\\n' \"$0\" \"$@\"\n"
        try createExecutable(script, at: executable)
        let resolution = resolveCommandExecutable(name: "sample-tool", section: "1", environment: ["PATH": bin.path])
        XCTAssertEqual(resolution, .executable(path: executable.path))
        let targetText = try generatedCommandText(target: resolution)
        XCTAssertEqual(targetText, quotedShellWord(executable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Resolving and preparing must not execute the command")
        let arguments = ["--optional", "two words", "$HOME; 'literal'", "café ✓"]
        let text = ([targetText] + arguments.map(quotedShellWord)).joined(separator: " ")
        let bytes = try await runManualTool(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", "-c", text], directory: directory, input: nil)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), ([executable.path] + arguments).joined(separator: "\n") + "\n")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "ran")
    }

    func testDeletedOrChangedTargetRequiresLocatingAnExecutableAgain() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let executable = directory.appendingPathComponent("sample-tool")
        try createExecutable("#!/bin/sh\nexit 0\n", at: executable)
        let resolution = resolveCommandExecutable(name: "sample-tool", section: "1", environment: ["PATH": directory.path])
        XCTAssertEqual(resolution.path, executable.path)
        try FileManager.default.removeItem(at: executable)
        XCTAssertThrowsError(try verifyCommandExecutable(path: executable.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains(executable.path))
            XCTAssertTrue(error.localizedDescription.contains("Locate"))
        }
        XCTAssertThrowsError(try generatedCommandText(target: resolution))
        try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: false)
        XCTAssertThrowsError(try verifyCommandExecutable(path: executable.path)) { error in
            guard case CommandExecutableError.notRegularFile(let path) = error else {
                return XCTFail("Expected a nonregular-file failure, received \(error)")
            }
            XCTAssertEqual(path, executable.path)
        }
    }

    func testPathSearchRejectsDirectoriesAndNonExecutableFiles() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let rejected = directory.appendingPathComponent("rejected")
        let accepted = directory.appendingPathComponent("accepted")
        try FileManager.default.createDirectory(at: rejected.appendingPathComponent("sample-tool"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accepted, withIntermediateDirectories: false)
        let executable = accepted.appendingPathComponent("sample-tool")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try verifyCommandExecutable(path: executable.path))
        let environment = ["PATH": rejected.path + ":" + accepted.path]
        guard case .unavailable = resolveCommandExecutable(name: "sample-tool", section: "1", environment: environment) else {
            return XCTFail("Directories and nonexecutable files must not be selected")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertEqual(resolveCommandExecutable(name: "sample-tool", section: "1", environment: environment), .executable(path: executable.path))
        XCTAssertThrowsError(try verifyCommandExecutable(path: "./sample-tool"))
        XCTAssertThrowsError(try verifyCommandExecutable(path: "/tmp/invalid\u{0}path"))
    }

    func testBuiltinsDocumentationAndUnknownCommandsHaveDistinctTargets() throws {
        XCTAssertEqual(resolveCommandExecutable(name: "cd", section: "1", environment: [:]), .shellBuiltin(name: "cd"))
        try verifyCommandExecutable(path: "/usr/bin/cd")
        XCTAssertEqual(resolveCommandExecutable(name: "cd", section: "1", environment: ["PATH": "/usr/bin:/bin"]), .shellBuiltin(name: "cd"),
                       "The system cd wrapper cannot change the terminal shell's working folder")
        XCTAssertEqual(try generatedCommandText(target: .shellBuiltin(name: "cd")), "builtin 'cd'")
        for name in ["bg", "fc", "fg", "type", "ulimit", "unalias"] {
            try verifyCommandExecutable(path: "/usr/bin/" + name)
            XCTAssertEqual(resolveCommandExecutable(name: name, section: "1", environment: ["PATH": "/usr/bin:/bin"]), .shellBuiltin(name: name),
                           "The installed child-shell wrapper must not replace a shell-context built-in")
        }
        let printf = resolveCommandExecutable(name: "printf", section: "1", environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(printf.path, "/usr/bin/printf", "A verified external executable takes precedence over a built-in")
        XCTAssertThrowsError(try generatedCommandText(target: .shellBuiltin(name: "unverified_builtin")))
        for section in ["2", "3", "5", "n"] {
            guard case .documentationOnly = resolveCommandExecutable(name: "printf", section: section, environment: ["PATH": "/usr/bin:/bin"]) else {
                return XCTFail("Section \(section) must retain documentation-only identity")
            }
        }
        for name in ["", "../ls", "ls;touch marker", "ls\n", "..", "$(id)"] {
            guard case .unavailable = resolveCommandExecutable(name: name, section: "1", environment: ["PATH": "/usr/bin:/bin"]) else {
                return XCTFail("Invalid command name must not become a runnable command")
            }
        }
        let missing = resolveCommandExecutable(name: "not-installed-command", section: "1", environment: [:])
        guard case .unavailable(let explanation) = missing else { return XCTFail("Missing PATH must not invent a default search path") }
        XCTAssertTrue(explanation.contains("no PATH"))
        XCTAssertThrowsError(try generatedCommandText(target: missing))
        guard case .unavailable = resolveCommandExecutable(name: "ls", section: "1", environment: ["PATH": ":relative:."]) else {
            return XCTFail("Relative or empty PATH entries must not resolve against an implicit working folder")
        }
    }

    private func createExecutable(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CommandExecutableTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTemporary(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Cannot clean command executable test directory: \(error)") }
    }
}
