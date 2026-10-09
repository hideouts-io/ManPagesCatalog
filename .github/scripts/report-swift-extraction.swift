import Foundation

enum InvocationSummaryError: Error {
    case invalidLog(String)
    case ioFailure(String, NSError)
}

struct SwiftInvocationSummary: Encodable {
    let module: String
    let target: String
    let sdk: String
    let sourceArgumentCount: Int
    let moduleEmission: Bool
    let objcHeaderEmission: Bool
    let executableEmission: Bool
    let accessibilityAmbiguityCount: Int
    let otherCompilerErrorCount: Int
}

struct SwiftLogSummary: Encodable {
    let examinedInvocationLogCount: Int
    let invocations: [SwiftInvocationSummary]
}

func capturedValues(_ pattern: String, _ text: String) throws -> [String] {
    let regex: NSRegularExpression = try NSRegularExpression(pattern: pattern)
    let range: NSRange = NSRange(text.startIndex..<text.endIndex, in: text)
    return try regex.matches(in: text, range: range).map { match in
        guard let valueRange: Range<String.Index> = Range(match.range(at: 1), in: text) else {
            throw InvocationSummaryError.invalidLog("Extractor metadata capture lacks its required field")
        }
        return String(text[valueRange])
    }
}

func singleValue(_ pattern: String, _ text: String, _ field: String) throws -> String {
    let values: [String] = try capturedValues(pattern, text)
    guard values.count == 1 else {
        throw InvocationSummaryError.invalidLog("Expected one extractor " + field + " value")
    }
    return values[0]
}

/// Only closed module names, validated public toolchain identifiers and counts leave the log boundary.
/// Source argument counts are metadata from joined argv; SARIF paths establish owned source extraction.
func summarizeInvocation(_ text: String) throws -> SwiftInvocationSummary {
    let lines: [String] = text.components(separatedBy: "\n")
    guard lines.count <= 100_000, lines.allSatisfy({ $0.utf8.count <= 256 * 1024 }) else {
        throw InvocationSummaryError.invalidLog("Extractor log line bounds exceeded")
    }
    let commands: [String] = lines.filter { $0.contains("calling extractor with arguments \"") }
    guard commands.count == 1 else {
        throw InvocationSummaryError.invalidLog("Expected one command record per extractor invocation log")
    }
    let command: String = commands[0]
    let module: String = try singleValue(#"-module-name\s+([^\s\"]+)"#, command, "module")
    let modules: Set<String> = ["SwiftTerm", "Man_Page_Catalog", "SwiftExtractionSummary"]
    guard modules.contains(module) else {
        throw InvocationSummaryError.invalidLog("Extractor module is outside the closed diagnostic contract")
    }
    let target: String = try singleValue(#"-target\s+((?:arm64|x86_64)-apple-macosx?[0-9]{1,2}(?:\.[0-9]{1,2}){0,2})(?=\s|\")"#, command, "target")
    let sdk: String = try singleValue(#"-sdk\s+[^\s\"]*/(MacOSX[0-9]{1,2}(?:\.[0-9]{1,2}){0,2}\.sdk)(?=\s|\")"#, command, "SDK")
    let sources: [String] = try capturedValues(#"(?:\s|^)([^\s\"]+\.swift)(?=\s|\")"#, command)
    let compilerErrors: [String] = lines.filter { $0.contains("ERRO [extractor/compiler]") }
    let ambiguities: Int = compilerErrors.filter { $0.contains("reference to 'NSAccessibilityElement' is ambiguous") }.count
    return SwiftInvocationSummary(
        module: module, target: target, sdk: sdk, sourceArgumentCount: sources.count,
        moduleEmission: !(try capturedValues(#"(?:\s|")(-emit-module)(?=\s|")"#, command)).isEmpty,
        objcHeaderEmission: !(try capturedValues(#"(?:\s|")(-emit-objc-header)(?=\s|")"#, command)).isEmpty,
        executableEmission: !(try capturedValues(#"(?:\s|")(-emit-executable)(?=\s|")"#, command)).isEmpty,
        accessibilityAmbiguityCount: ambiguities,
        otherCompilerErrorCount: compilerErrors.count - ambiguities
    )
}

func checkedDirectory(_ url: URL) throws -> URL {
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch let error as NSError {
        throw InvocationSummaryError.ioFailure("inspect extractor log directory", error)
    }
    guard values.isDirectory == true, values.isSymbolicLink == false else {
        throw InvocationSummaryError.invalidLog("Extractor log directory is missing or is a symbolic link")
    }
    return url
}

func readInvocationLogs(_ temporaryDirectory: URL) throws -> [String] {
    var extractorDirectory: URL = try checkedDirectory(temporaryDirectory.resolvingSymlinksInPath())
    for component in ["codeql_databases", "swift", "log", "swift", "extractor"] {
        extractorDirectory = try checkedDirectory(extractorDirectory.appendingPathComponent(component))
    }
    let files: [URL]
    do {
        files = try FileManager.default.contentsOfDirectory(at: extractorDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    } catch let error as NSError {
        throw InvocationSummaryError.ioFailure("list Swift extractor invocation logs", error)
    }
    let logs: [URL] = files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !logs.isEmpty, logs.count <= 500 else {
        throw InvocationSummaryError.invalidLog("Swift invocation log count must be between 1 and 500")
    }
    var totalBytes: Int = 0
    return try logs.map { url in
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch let error as NSError {
            throw InvocationSummaryError.ioFailure("inspect Swift extractor invocation log", error)
        }
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              let size: Int = values.fileSize, size >= 0, size <= 20 * 1024 * 1024 else {
            throw InvocationSummaryError.invalidLog("Invocation log must be a bounded regular file without a symbolic link")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as NSError {
            throw InvocationSummaryError.ioFailure("read Swift extractor invocation log", error)
        }
        guard data.count <= 20 * 1024 * 1024 else {
            throw InvocationSummaryError.invalidLog("Swift invocation log changed beyond the byte limit during reading")
        }
        totalBytes += data.count
        guard totalBytes <= 80 * 1024 * 1024 else {
            throw InvocationSummaryError.invalidLog("Swift invocation logs exceed the total byte limit")
        }
        guard let text: String = String(data: data, encoding: .utf8) else {
            throw InvocationSummaryError.invalidLog("Swift invocation log must contain valid UTF-8")
        }
        return text
    }
}

func writeSummary(_ arguments: [String]) throws {
    guard arguments.count == 2 else {
        throw InvocationSummaryError.invalidLog("Expected the runner temporary directory and summary output path")
    }
    let temporaryDirectory: URL = URL(fileURLWithPath: arguments[0])
    let output: URL = URL(fileURLWithPath: arguments[1])
    guard output.standardizedFileURL.path == temporaryDirectory.appendingPathComponent("swift-invocation-summary.json").standardizedFileURL.path else {
        throw InvocationSummaryError.invalidLog("Summary output must use the fixed task-owned temporary file")
    }
    let logs: [String] = try readInvocationLogs(temporaryDirectory)
    let summary: SwiftLogSummary = SwiftLogSummary(examinedInvocationLogCount: logs.count, invocations: try logs.map(summarizeInvocation))
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data = try encoder.encode(summary)
    guard data.count <= 256 * 1024 else {
        throw InvocationSummaryError.invalidLog("Bounded invocation metadata exceeds the output byte limit")
    }
    do {
        try data.write(to: output, options: .withoutOverwriting)
    } catch let error as NSError {
        throw InvocationSummaryError.ioFailure("write bounded Swift invocation summary", error)
    }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

do {
    try writeSummary(Array(CommandLine.arguments.dropFirst()))
} catch InvocationSummaryError.invalidLog(let reason) {
    FileHandle.standardError.write(Data("Swift invocation summary rejected: \(reason).\n".utf8))
    exit(1)
} catch InvocationSummaryError.ioFailure(let operation, let error) {
    FileHandle.standardError.write(Data("Swift invocation summary I/O failed: operation=\(operation) domain=\(error.domain) code=\(error.code).\n".utf8))
    exit(1)
}
