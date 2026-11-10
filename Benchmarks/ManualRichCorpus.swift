import Foundation
import Darwin

/// Native, dependency-free manual-rich corpus CLI. Scan only ROOT/manuals with the production app.
/// generate --root ABS --owner-token TOKEN --seed UINT --manuals N --large-every N --large-paragraphs N
///          --batch-size N --max-files N --max-storage-bytes UINT --free-reserve-bytes UINT
/// verify|cleanup --root ABS --owner-token TOKEN
/// verify-production --root ABS --owner-token TOKEN --inventory ABSJSON --index ABSSQLITE --output ABSJSON
/// Signals pause generation at the next bounded batch with a committed checkpoint; exact options resume it.
@main
struct ManualRichCorpus {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw ManualRichError.invalid("Use generate, verify, verify-production or cleanup; see ManualRichCorpus.swift for the explicit CLI arguments.") }
            let values = try manualRichArguments(Array(arguments.dropFirst()))
            let root = try manualRichURL(values, "--root")
            guard let token = values["--owner-token"], token.count >= 16 else { throw ManualRichError.invalid("Require --owner-token with at least 16 characters.") }
            switch command {
            case "generate":
                try manualRichKeys(values, ["--root", "--owner-token", "--seed", "--manuals", "--large-every", "--large-paragraphs", "--batch-size", "--max-files", "--max-storage-bytes", "--free-reserve-bytes"])
                let options = ManualRichOptions(seed: try manualRichUInt(values, "--seed"), manuals: try manualRichInt(values, "--manuals"),
                    largeEvery: try manualRichInt(values, "--large-every"), largeParagraphs: try manualRichInt(values, "--large-paragraphs"),
                    batchSize: try manualRichInt(values, "--batch-size"), maxFiles: try manualRichInt(values, "--max-files"),
                    maxStorageBytes: try manualRichUInt(values, "--max-storage-bytes"), freeReserveBytes: try manualRichUInt(values, "--free-reserve-bytes"))
                let interrupt = ManualRichInterrupt()
                signal(SIGINT, SIG_IGN)
                signal(SIGTERM, SIG_IGN)
                let first = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
                let second = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
                first.setEventHandler { Task { await interrupt.request() } }
                second.setEventHandler { Task { await interrupt.request() } }
                first.resume()
                second.resume()
                let completed = try await manualRichGenerate(root, token, options, interrupt)
                first.cancel()
                second.cancel()
                if !completed { exit(2) }
            case "verify":
                try manualRichKeys(values, ["--root", "--owner-token"])
                try manualRichVerify(root, token)
            case "verify-production":
                try manualRichKeys(values, ["--root", "--owner-token", "--inventory", "--index", "--output"])
                try manualRichVerifyProduction(root, token, manualRichURL(values, "--inventory"), manualRichURL(values, "--index"), manualRichURL(values, "--output"))
            case "cleanup":
                try manualRichKeys(values, ["--root", "--owner-token"])
                try manualRichCleanup(root, token)
            default: throw ManualRichError.invalid("Unknown command \(command); use generate, verify, verify-production or cleanup.")
            }
        } catch {
            FileHandle.standardError.write(Data("Manual-rich corpus failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

func manualRichArguments(_ arguments: [String]) throws -> [String: String] {
    guard arguments.count % 2 == 0 else { throw ManualRichError.invalid("Every CLI option requires an explicit value.") }
    var values: [String: String] = [:]
    for position in stride(from: 0, to: arguments.count, by: 2) {
        let key = arguments[position]
        guard key.hasPrefix("--"), values[key] == nil, !arguments[position + 1].isEmpty else {
            throw ManualRichError.invalid("Invalid or duplicated CLI option: \(key)")
        }
        values[key] = arguments[position + 1]
    }
    return values
}

func manualRichKeys(_ values: [String: String], _ expected: Set<String>) throws {
    guard Set(values.keys) == expected else { throw ManualRichError.invalid("Required options are \(expected.sorted().joined(separator: ", ")); no extra or omitted options are accepted.") }
}

func manualRichURL(_ values: [String: String], _ key: String) throws -> URL {
    guard let path = values[key], path.hasPrefix("/"), !path.contains("\0") else { throw ManualRichError.invalid("Require absolute local path for \(key).") }
    return URL(fileURLWithPath: path).standardizedFileURL
}

func manualRichInt(_ values: [String: String], _ key: String) throws -> Int {
    guard let text = values[key], let value = Int(text) else { throw ManualRichError.invalid("Require an integer for \(key).") }
    return value
}

func manualRichUInt(_ values: [String: String], _ key: String) throws -> UInt64 {
    guard let text = values[key], let value = UInt64(text) else { throw ManualRichError.invalid("Require an unsigned 64-bit integer for \(key).") }
    return value
}
