import Foundation
import Darwin

struct ManualToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ManualProcessResult: Sendable {
    let bytes: Data
    let diagnostic: String
    let status: Int32
}

struct ManualProcessCleanupError: LocalizedError {
    let cause: Error
    let failures: [String]
    var errorDescription: String? {
        "\(cause.localizedDescription) Capture cleanup also failed: \(failures.joined(separator: "; "))"
    }
}

func runManualTool(executable: URL, arguments: [String], directory: URL, input: Data?) async throws -> Data {
    let result = try await runManualProcess(executable: executable, arguments: arguments, directory: directory, input: input)
    guard result.status == 0 else {
        throw ManualToolError(message: "\(executable.path) \(arguments.joined(separator: " ")) failed (exit \(result.status)): \(result.diagnostic)")
    }
    return result.bytes
}

/// Runs only explicitly selected tools, with file-backed output, cancellation and a deadline.
/// Each output stream is limited to 64 MiB before loading. Polling can permit temporary disk overshoot.
func runManualProcess(executable: URL, arguments: [String], directory: URL, input: Data?) async throws -> ManualProcessResult {
    try Task.checkCancellation()
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let output = temporary.appendingPathComponent("stdout")
    let errors = temporary.appendingPathComponent("stderr")
    let process = Process()
    var handles: [FileHandle] = []
    let result: ManualProcessResult
    do {
        try Data().write(to: output)
        try Data().write(to: errors)
        let outputHandle = try FileHandle(forWritingTo: output)
        handles.append(outputHandle)
        let errorHandle = try FileHandle(forWritingTo: errors)
        handles.append(errorHandle)
        process.executableURL = executable
        process.arguments = arguments
        // Finder and XCTest may inherit the C locale, which makes col discard mdoc's Unicode separator.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let inputURL = temporary.appendingPathComponent("stdin")
        try (input ?? Data()).write(to: inputURL)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        handles.append(inputHandle)
        process.standardInput = inputHandle
        try Task.checkCancellation()
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            try Task.checkCancellation()
            try validateManualProcessOutput(executable: executable, output: outputHandle, errors: errorHandle)
            if Date() > deadline {
                throw ManualToolError(message: "\(executable.path) \(arguments.joined(separator: " ")) exceeded the 30-second timeout.")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        try validateManualProcessOutput(executable: executable, output: outputHandle, errors: errorHandle)
        let bytes = try Data(contentsOf: output)
        let diagnostic = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
        try Task.checkCancellation()
        result = ManualProcessResult(bytes: bytes, diagnostic: diagnostic, status: process.terminationStatus)
    } catch {
        if process.isRunning {
            // No shell or worker descendants; kill a cancelled/timed-out formatter before cleanup.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let failures = cleanupManualProcessCapture(handles: handles, directory: temporary)
        if !failures.isEmpty { throw ManualProcessCleanupError(cause: error, failures: failures) }
        throw error
    }
    let failures = cleanupManualProcessCapture(handles: handles, directory: temporary)
    guard failures.isEmpty else {
        throw ManualToolError(message: "Cannot finish \(executable.path): capture cleanup failed: \(failures.joined(separator: "; "))")
    }
    try Task.checkCancellation()
    return result
}

private func validateManualProcessOutput(executable: URL, output: FileHandle, errors: FileHandle) throws {
    for (handle, name) in [(output, "output"), (errors, "diagnostic output")] {
        var metadata = stat()
        guard fstat(handle.fileDescriptor, &metadata) == 0 else {
            let code = errno
            throw ManualToolError(message: "Cannot measure \(executable.path) \(name) capture (POSIX \(code)): \(String(cString: strerror(code)))")
        }
        guard metadata.st_size <= 64 * 1024 * 1024 else {
            throw ManualToolError(message: "\(executable.path) exceeded the 64 MiB \(name) limit.")
        }
    }
}

private func cleanupManualProcessCapture(handles: [FileHandle], directory: URL) -> [String] {
    var failures: [String] = []
    for handle in handles {
        do { try handle.close() }
        catch { failures.append("Cannot close capture file in \(directory.path): \(error.localizedDescription)") }
    }
    do { try FileManager.default.removeItem(at: directory) }
    catch { failures.append("Cannot remove capture directory \(directory.path): \(error.localizedDescription)") }
    return failures
}
