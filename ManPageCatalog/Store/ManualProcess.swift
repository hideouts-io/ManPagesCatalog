import Foundation

struct ManualToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ManualProcessResult: Sendable {
    let bytes: Data
    let diagnostic: String
    let status: Int32
}

func runManualTool(executable: URL, arguments: [String], directory: URL, input: Data?) async throws -> Data {
    let result = try await runManualProcess(executable: executable, arguments: arguments, directory: directory, input: input)
    guard result.status == 0 else {
        throw ManualToolError(message: "\(executable.path) \(arguments.joined(separator: " ")) failed (exit \(result.status)): \(result.diagnostic)")
    }
    return result.bytes
}

/// Runs only explicitly selected tools, with file-backed output, cancellation and a deadline.
func runManualProcess(executable: URL, arguments: [String], directory: URL, input: Data?) async throws -> ManualProcessResult {
    try Task.checkCancellation()
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let output = temporary.appendingPathComponent("stdout")
    let errors = temporary.appendingPathComponent("stderr")
    try Data().write(to: output)
    try Data().write(to: errors)
    let outputHandle = try FileHandle(forWritingTo: output)
    let errorHandle = try FileHandle(forWritingTo: errors)
    let process = Process()
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
    process.standardInput = inputHandle
    do {
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            try Task.checkCancellation()
            if Date() > deadline {
                throw ManualToolError(message: "\(executable.path) \(arguments.joined(separator: " ")) exceeded the 30-second timeout.")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let bytes = try Data(contentsOf: output)
        let diagnostic = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
        try inputHandle.close()
        try outputHandle.close()
        try errorHandle.close()
        try FileManager.default.removeItem(at: temporary)
        return ManualProcessResult(bytes: bytes, diagnostic: diagnostic, status: process.terminationStatus)
    } catch {
        if process.isRunning {
            // No shell or worker descendants; kill a cancelled/timed-out formatter before cleanup.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try inputHandle.close()
        try outputHandle.close()
        try errorHandle.close()
        try FileManager.default.removeItem(at: temporary)
        throw error
    }
}
