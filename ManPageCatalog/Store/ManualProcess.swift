import Foundation
import Darwin
import os

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

private struct ManualProcessExit: Sendable {
    let status: Int32
    let observedAt: ContinuousClock.Instant
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
/// A native completion handler permits asynchronous retirement; unconfirmed termination retains private captures.
func runManualProcess(executable: URL, arguments: [String], directory: URL, input: Data?) async throws -> ManualProcessResult {
    try Task.checkCancellation()
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let output = temporary.appendingPathComponent("stdout")
    let errors = temporary.appendingPathComponent("stderr")
    let process = Process()
    let completion = OSAllocatedUnfairLock<ManualProcessExit?>(initialState: nil)
    var launched = false
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
        process.terminationHandler = { [completion] finished in
            let exit = ManualProcessExit(status: finished.terminationStatus, observedAt: ContinuousClock.now)
            completion.withLock { $0 = exit }
        }
        try Task.checkCancellation()
        try process.run()
        launched = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while completion.withLock({ $0?.status }) == nil {
            try Task.checkCancellation()
            try validateManualProcessOutput(executable: executable, output: outputHandle, errors: errorHandle)
            if ContinuousClock.now > deadline {
                throw ManualToolError(message: "\(executable.path) \(arguments.joined(separator: " ")) exceeded the 30-second timeout.")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        try validateManualProcessOutput(executable: executable, output: outputHandle, errors: errorHandle)
        let bytes = try Data(contentsOf: output)
        let diagnostic = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
        try Task.checkCancellation()
        guard let status = completion.withLock({ $0?.status }) else {
            throw ManualToolError(message: "Cannot finish \(executable.path): native termination did not record an exit status.")
        }
        result = ManualProcessResult(bytes: bytes, diagnostic: diagnostic, status: status)
    } catch let operationError {
        if launched {
            do { try await retireManualProcess(process: process, completion: completion) }
            catch let retirementError {
                let failures = ["Cannot confirm \(executable.path) termination: \(retirementError.localizedDescription) Captures retained at \(temporary.path)."]
                    + closeManualProcessCapture(handles: handles, directory: temporary)
                throw ManualProcessCleanupError(cause: operationError, failures: failures)
            }
        }
        let failures = cleanupManualProcessCapture(handles: handles, directory: temporary)
        if !failures.isEmpty { throw ManualProcessCleanupError(cause: operationError, failures: failures) }
        throw operationError
    }
    let failures = cleanupManualProcessCapture(handles: handles, directory: temporary)
    guard failures.isEmpty else {
        throw ManualToolError(message: "Cannot finish \(executable.path): capture cleanup failed: \(failures.joined(separator: "; "))")
    }
    try Task.checkCancellation()
    return result
}

/// Await the native completion callback independently of the caller's cancelled task.
/// The deadline bounds completion observation; it is not a hard OS scheduling or descendant-process bound.
private func retireManualProcess(process: Process, completion: OSAllocatedUnfairLock<ManualProcessExit?>) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    if completion.withLock({ $0?.status }) != nil { return }
    if process.isRunning {
        let childPID = process.processIdentifier
        guard childPID > 0 else {
            throw ManualToolError(message: "Cannot retire a launched formatter with invalid process identifier \(childPID).")
        }
        if kill(childPID, SIGKILL) != 0 {
            let code = errno
            guard code == ESRCH else {
                throw ManualToolError(message: "Cannot send SIGKILL to owned formatter process \(childPID) (POSIX \(code)): \(String(cString: strerror(code)))")
            }
        }
    }
    try await Task.detached(priority: Task.currentPriority) {
        while true {
            if let exit = completion.withLock({ $0 }) {
                guard exit.observedAt <= deadline else {
                    throw ManualToolError(message: "Native formatter termination was observed after its five-second retirement deadline.")
                }
                return
            }
            guard ContinuousClock.now < deadline else {
                throw ManualToolError(message: "Native formatter termination was not observed within its five-second retirement deadline.")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }.value
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

private func closeManualProcessCapture(handles: [FileHandle], directory: URL) -> [String] {
    var failures: [String] = []
    for handle in handles {
        do { try handle.close() }
        catch { failures.append("Cannot close capture file in \(directory.path): \(error.localizedDescription)") }
    }
    return failures
}

private func cleanupManualProcessCapture(handles: [FileHandle], directory: URL) -> [String] {
    var failures = closeManualProcessCapture(handles: handles, directory: directory)
    do { try FileManager.default.removeItem(at: directory) }
    catch { failures.append("Cannot remove capture directory \(directory.path): \(error.localizedDescription)") }
    return failures
}
