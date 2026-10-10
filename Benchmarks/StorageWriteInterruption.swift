import Foundation
import Darwin

struct StorageWriteObservation: Codable {
    let processID: Int32
    let descriptor: Int32
    let path: String
    let bytes: Int64
    let openFlags: UInt32
    let boundary: String
    let stoppedUptime: Double
}

struct StorageInterruptionResult: Codable {
    let operation: String
    let observation: StorageWriteObservation?
    let status: Int32
    let workerOutput: String
    let workerErrors: String
    let limitation: String?
}

struct StorageObservationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// libproc reads only descriptors of the child this controller launches; it does not inspect other apps.
@main
struct StorageWriteInterruption {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Storage write observation failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5 else { throw StorageObservationError(message: "Usage: storage-write-interruption /path/storage-recovery inventory-write|checkpoint-write|index-write|export-write /owned/volume TOKEN LIBRARY-NAME") }
        let worker = URL(fileURLWithPath: arguments[0])
        let operation = arguments[1]
        let volume = URL(fileURLWithPath: arguments[2])
        let library = volume.appendingPathComponent(arguments[4])
        guard worker.lastPathComponent == "storage-recovery", FileManager.default.isExecutableFile(atPath: worker.path) else {
            throw StorageObservationError(message: "Expected the executable native storage-recovery harness: \(worker.path).")
        }
        guard ["inventory-write", "checkpoint-write", "index-write", "export-write"].contains(operation) else {
            throw StorageObservationError(message: "Unsupported observation operation: \(operation).")
        }
        let process = Process()
        process.executableURL = worker
        process.arguments = Array(arguments[1...])
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGCONT); process.terminate() } }
        let began = ProcessInfo.processInfo.systemUptime
        var observation: StorageWriteObservation?
        while process.isRunning, ProcessInfo.processInfo.systemUptime - began < 30 {
            if let opened = try writeDescriptor(processID: process.processIdentifier, operation: operation, volume: volume, library: library) {
                guard kill(process.processIdentifier, SIGSTOP) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var state: Int32 = 0
                guard waitpid(process.processIdentifier, &state, WUNTRACED) == process.processIdentifier,
                      (state & 0xFF) == 0x7F else { throw StorageObservationError(message: "Worker PID \(process.processIdentifier) did not stop at the observed write boundary.") }
                if let stopped = try writeDescriptor(processID: process.processIdentifier, operation: operation, volume: volume, library: library),
                   stopped.descriptor == opened.descriptor, stopped.path == opened.path {
                    observation = stopped
                }
                guard kill(process.processIdentifier, SIGKILL) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            usleep(500)
        }
        if observation == nil, process.isRunning { process.terminate() }
        process.waitUntilExit()
        let result = StorageInterruptionResult(operation: operation, observation: observation, status: process.terminationStatus,
            workerOutput: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            workerErrors: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            limitation: observation == nil ? "No active writable temporary descriptor was observed; this attempt is not active-write interruption evidence." : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
    }
}

func writeDescriptor(processID: Int32, operation: String, volume: URL, library: URL) throws -> StorageWriteObservation? {
    let expected = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
    guard expected > 0 else {
        if errno == ESRCH { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(expected) / MemoryLayout<proc_fdinfo>.stride + 32)
    let bytes = descriptors.withUnsafeMutableBytes {
        proc_pidinfo(processID, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard bytes > 0 else {
        if errno == ESRCH { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    for descriptor in descriptors.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var opened = vnode_fdinfowithpath()
        let size = proc_pidfdinfo(processID, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &opened, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
        if size != MemoryLayout<vnode_fdinfowithpath>.size {
            if [EBADF, ENOENT, ESRCH].contains(errno) { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let path = withUnsafeBytes(of: opened.pvip.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let bytes = opened.pvip.vip_vi.vi_stat.vst_size
        guard opened.pfi.fi_openflags & UInt32(FWRITE) != 0, path.hasPrefix(volume.path + "/"), bytes > 0 else { continue }
        let journal = operation == "index-write" && path.hasSuffix("/search.sqlite-journal") && bytes > 4096
        let stableDestinations = [library.appendingPathComponent("discovery-v1.json").path,
                                  library.appendingPathComponent("scan-checkpoint-v1.json").path,
                                  volume.appendingPathComponent("exports/coverage.json").path,
                                  volume.appendingPathComponent("exports/coverage.performance.json").path]
        let atomic = operation != "index-write" && !stableDestinations.contains(path) &&
            !path.hasPrefix(library.appendingPathComponent("search.sqlite").path) && bytes < 64 * 1024 * 1024 &&
            (operation != "export-write" || bytes > 1024 * 1024)
        if journal || atomic {
            return StorageWriteObservation(processID: processID, descriptor: descriptor.proc_fd, path: path,
                bytes: bytes, openFlags: opened.pfi.fi_openflags,
                boundary: journal ? "Open writable SQLite rollback journal before transaction completion" : "Open writable Foundation atomic temporary output before replacement",
                stoppedUptime: ProcessInfo.processInfo.systemUptime)
        }
    }
    return nil
}
