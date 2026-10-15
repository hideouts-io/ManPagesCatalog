import AppKit
import SwiftUI
import OSLog
import Darwin

enum InteractionOperation: String, Codable, Sendable {
    case search, reader, findNext, findPrevious, indexingProgress
}

enum InteractionOutcome: String, Codable, Sendable {
    case completed, failed, superseded, blocked, reused
}

enum InteractionStartBoundary: String, Codable, Sendable {
    case controlHandler, binding, readerHandler, findHandler, metadataPublication
}

struct SearchServiceTiming: Codable, Sendable {
    let executionStartedUptime: Double
    let fullTextStartedUptime: Double?
    let fullTextFinishedUptime: Double?
    let rankingQueuedUptime: Double
    let rankingStartedUptime: Double
    let rankingFinishedUptime: Double
    let resultsPublicationStartedUptime: Double?
    let resultsCommittedUptime: Double
}

struct InteractionSpan: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let operation: InteractionOperation
    let startedUptime: Double
    let eventUptime: Double?
    let startBoundary: InteractionStartBoundary
    let query: String
    let queryTruncated: Bool
    let documentID: String?
    var documentGeneration: UUID?
    var generation: UUID?
    var section: String?
    var sourceRoot: String?
    var fullText: Bool?
    var serviceFinishedUptime: Double?
    var viewAppliedUptime: Double?
    var outcome: InteractionOutcome?
    var resultCount: Int?
    var detail: String?
    var searchTiming: SearchServiceTiming?
    var coalescedSearchRefreshes: Int?
}

struct InteractionDiagnosticRecord: Codable, Sendable {
    let sequence: Int
    let sessionID: UUID
    let processID: Int32
    let phase: String
    let clock: String
    let endpointLimit: String
    let span: InteractionSpan
}

private struct InteractionDiagnosticError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Serial local file output; recording never waits for filesystem I/O on MainActor.
actor InteractionDiagnosticWriter {
    let destination: URL
    private var handle: FileHandle?
    private let maximumFileBytes: Int64 = 32 * 1024 * 1024
    private let maximumRecordBytes = 65_536

    init(destination: URL) { self.destination = destination }

    func append(_ record: InteractionDiagnosticRecord) throws {
        if handle == nil { handle = try openLocalHandle() }
        guard let handle else {
            throw InteractionDiagnosticError(message: "Interaction diagnostics has no writable handle for \(destination.path).")
        }
        var line = try JSONEncoder().encode(record)
        line.append(0x0a)
        guard line.count <= maximumRecordBytes else {
            throw InteractionDiagnosticError(message: "Interaction record exceeds the 64 KiB limit at \(destination.path). Shorten diagnostic queries or paths before another probe.")
        }
        let metadata = try requireRegularLocalFile(handle.fileDescriptor)
        guard metadata.st_size <= maximumFileBytes - Int64(line.count) else {
            throw InteractionDiagnosticError(message: "Interaction diagnostics would exceed its 32 MiB file limit at \(destination.path). Choose a new JSONL file and relaunch.")
        }
        try handle.write(contentsOf: line)
    }

    private func openLocalHandle() throws -> FileHandle {
        let parentPath = destination.deletingLastPathComponent().path
        guard let physicalParent = realpath(parentPath, nil) else {
            throw fileError(action: "resolve the existing parent directory", path: parentPath, code: errno)
        }
        defer { free(physicalParent) }
        // Foundation restores /var aliases; the no-symlink open needs the physical /private/var path.
        let parent = URL(fileURLWithPath: String(cString: physicalParent), isDirectory: true)
        var filesystem = statfs()
        guard statfs(parent.path, &filesystem) == 0 else {
            throw fileError(action: "inspect the existing parent directory", path: parent.path, code: errno)
        }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw InteractionDiagnosticError(message: "Interaction diagnostics parent \(parent.path) is on a network or unidentified volume. Choose an existing writable local directory.")
        }
        var ancestor = parent
        while true {
            var metadata = stat()
            guard lstat(ancestor.path, &metadata) == 0 else {
                throw fileError(action: "inspect a parent directory", path: ancestor.path, code: errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_flags & UInt32(SF_DATALESS) == 0,
                  ancestor.pathExtension != "icloud" else {
                throw InteractionDiagnosticError(message: "Interaction diagnostics parent \(ancestor.path) is not a materialized directory. Choose an existing writable local folder; diagnostics never download cloud placeholders.")
            }
            if ancestor.path == "/" { break }
            ancestor = ancestor.deletingLastPathComponent()
        }
        let resolved = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: false)
        var existing = stat()
        let exists = lstat(resolved.path, &existing) == 0
        if exists {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_flags & UInt32(SF_DATALESS) == 0,
                  destination.pathExtension != "icloud", existing.st_size >= 0, existing.st_size <= maximumFileBytes else {
                throw InteractionDiagnosticError(message: "Interaction diagnostics destination \(resolved.path) is a symlink, placeholder, nonregular file or exceeds 32 MiB. Choose a regular local JSONL file.")
            }
        } else if errno != ENOENT {
            throw fileError(action: "inspect the destination", path: resolved.path, code: errno)
        }
        let creationFlags: Int32 = exists ? 0 : O_CREAT | O_EXCL
        let descriptor = Darwin.open(resolved.path, O_WRONLY | O_APPEND | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC | creationFlags, 0o600)
        guard descriptor >= 0 else { throw fileError(action: "open the destination without following symlinks", path: resolved.path, code: errno) }
        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let bound = try requireRegularLocalFile(descriptor)
            guard !exists || (bound.st_dev == existing.st_dev && bound.st_ino == existing.st_ino) else {
                throw InteractionDiagnosticError(message: "Interaction diagnostics destination \(resolved.path) changed identity while opening. Choose a stable local JSONL path and relaunch.")
            }
            return opened
        } catch {
            do { try opened.close() }
            catch let closing {
                throw InteractionDiagnosticError(message: "Cannot validate interaction diagnostics at \(resolved.path): \(error.localizedDescription). Closing its rejected descriptor also failed: \(closing.localizedDescription).")
            }
            throw error
        }
    }

    private func requireRegularLocalFile(_ descriptor: Int32) throws -> stat {
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else {
            throw fileError(action: "verify the opened volume", path: destination.path, code: errno)
        }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw InteractionDiagnosticError(message: "Interaction diagnostics at \(destination.path) is not on a verified local volume. No diagnostic data was appended.")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw fileError(action: "verify the opened file", path: destination.path, code: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_flags & UInt32(SF_DATALESS) == 0,
              metadata.st_size >= 0, metadata.st_size <= maximumFileBytes else {
            throw InteractionDiagnosticError(message: "Interaction diagnostics at \(destination.path) is no longer a materialized regular file within 32 MiB. No diagnostic data was appended.")
        }
        return metadata
    }

    private func fileError(action: String, path: String, code: Int32) -> InteractionDiagnosticError {
        InteractionDiagnosticError(message: "Cannot \(action) for interaction diagnostics at \(path): \(String(cString: strerror(code))) (errno \(code)). Choose an existing writable local JSONL path and relaunch.")
    }
}

/// Opt-in service/view-application timings, never event-to-pixel measurements.
@MainActor
final class InteractionDiagnostics {
    private static let shared = InteractionDiagnostics()
    private static let logger = Logger(subsystem: "com.local.ManPageCatalog", category: "InteractionDiagnostics")
    private let writer: InteractionDiagnosticWriter?
    private var activeSearch: InteractionSpan?
    private var searchQuery: String?
    private var pendingReader: InteractionSpan?
    private var pendingFind: InteractionSpan?
    private var pendingFindQuery: String?
    private var active: [InteractionOperation: InteractionSpan] = [:]
    private var completed: [UUID: InteractionSpan] = [:]
    private var completedOrder: [UUID] = []
    private var sequence = 0
    private let sessionID = UUID()
    private var outputFailed = false
    private let maximumRecords = 2_000
    private let maximumCompleted = 64

    private init() {
        guard let path = ProcessInfo.processInfo.environment["MANPAGES_INTERACTION_DIAGNOSTICS"] else {
            writer = nil
            return
        }
        guard (path as NSString).isAbsolutePath else {
            writer = nil
            Self.logger.error("Interaction diagnostics requires an absolute JSONL path; configured path: \(path, privacy: .public)")
            return
        }
        writer = InteractionDiagnosticWriter(destination: URL(fileURLWithPath: path))
    }

    static var isEnabled: Bool { shared.writer != nil && !shared.outputFailed }

    static func searchInput(query: String, window: NSWindow?) {
        guard isEnabled else { return }
        shared.supersedeSearch()
        shared.searchQuery = query
        shared.activeSearch = shared.newSpan(operation: .search, query: query, documentID: nil,
                                            boundary: .controlHandler, eventUptime: eventTimestamp(window: window))
    }

    static func searchStarted(generation: UUID, query: String, section: String?, root: String?, fullText: Bool) {
        guard isEnabled else { return }
        let prior = shared.activeSearch
        let changedScope = prior?.generation != nil && (prior?.section != section || prior?.sourceRoot != root || prior?.fullText != fullText)
        if shared.searchQuery != query || prior == nil || changedScope {
            shared.supersedeSearch()
            shared.searchQuery = query
            shared.activeSearch = shared.newSpan(operation: .search, query: query, documentID: nil,
                                                boundary: .binding, eventUptime: nil)
        }
        guard var span = shared.activeSearch else { return }
        span.generation = generation
        span.section = section
        span.sourceRoot = root
        span.fullText = fullText
        shared.activeSearch = span
    }

    static func searchRefreshQueued() {
        guard isEnabled, var span = shared.activeSearch else { return }
        span.coalescedSearchRefreshes = (span.coalescedSearchRefreshes ?? 0) + 1
        shared.activeSearch = span
    }

    static func searchMeasured(generation: UUID, timing: SearchServiceTiming) {
        guard isEnabled, var span = shared.activeSearch, span.generation == generation else { return }
        span.searchTiming = timing
        shared.activeSearch = span
    }

    static func searchFinished(generation: UUID, resultCount: Int?, outcome: InteractionOutcome, detail: String?) {
        guard isEnabled, let span = shared.activeSearch, span.generation == generation else { return }
        shared.activeSearch = nil
        shared.finish(span, outcome: outcome, resultCount: resultCount, detail: detail)
    }

    /// A canceled older job must not close the user's interaction linked to a newer refresh.
    static func searchSuperseded(generation: UUID) {
        guard isEnabled, let span = shared.activeSearch, span.generation == generation else { return }
        shared.supersedeSearch()
    }

    static func progressStarted(generation: UUID) {
        started(operation: .indexingProgress, generation: generation, query: "", documentID: nil)
    }

    static func progressFinished(generation: UUID, indexedCount: Int) {
        guard isEnabled, let span = shared.active[.indexingProgress], span.generation == generation else { return }
        shared.active.removeValue(forKey: .indexingProgress)
        shared.finish(span, outcome: .completed, resultCount: indexedCount, detail: "Committed indexed-manual count publication; excludes pixel presentation.")
    }

    static func readerInput(window: NSWindow?) {
        guard isEnabled else { return }
        if let prior = shared.pendingReader { shared.finish(prior, outcome: .superseded, resultCount: nil, detail: "Another reader activation replaced this input.") }
        shared.pendingReader = shared.newSpan(operation: .reader, query: "", documentID: nil,
                                             boundary: .controlHandler, eventUptime: eventTimestamp(window: window))
    }

    static func readerInputCancelled() {
        guard isEnabled, let span = shared.pendingReader else { return }
        shared.pendingReader = nil
        shared.finish(span, outcome: .blocked, resultCount: nil, detail: "The activation did not open a manual.")
    }

    static func findInput(query: String, documentID: String?, window: NSWindow?) {
        guard isEnabled else { return }
        if let prior = shared.pendingFind { shared.finish(prior, outcome: .superseded, resultCount: nil, detail: "Another Find input replaced this binding.") }
        shared.pendingFindQuery = query
        shared.pendingFind = shared.newSpan(operation: .findNext, query: query, documentID: documentID,
                                           boundary: .binding, eventUptime: eventTimestamp(window: window))
    }

    static func findInputCancelled() {
        guard isEnabled, let span = shared.pendingFind else { return }
        shared.pendingFind = nil
        shared.pendingFindQuery = nil
        shared.finish(span, outcome: .superseded, resultCount: nil, detail: "The document changed before this Find binding was submitted.")
    }

    static func started(operation: InteractionOperation, generation: UUID, query: String, documentID: String?) {
        guard isEnabled else { return }
        if shared.active[operation]?.generation == generation { return }
        if let prior = shared.active.removeValue(forKey: operation) {
            shared.finish(prior, outcome: .superseded, resultCount: nil, detail: "A newer operation replaced this request.")
        }
        let pending: InteractionSpan?
        if operation == .reader { pending = shared.pendingReader }
        else if operation == .findNext, shared.pendingFindQuery == query { pending = shared.pendingFind }
        else { pending = nil }
        if operation == .reader { shared.pendingReader = nil }
        if operation == .findNext {
            if pending == nil, let prior = shared.pendingFind {
                shared.finish(prior, outcome: .superseded, resultCount: nil, detail: "The submitted query differs from this pending Find binding.")
            }
            shared.pendingFind = nil
            shared.pendingFindQuery = nil
        }
        let boundary: InteractionStartBoundary = operation == .indexingProgress ? .metadataPublication : operation == .reader ? .readerHandler : .findHandler
        var span = shared.newSpan(operation: operation, query: query, documentID: documentID,
                                  boundary: boundary, eventUptime: nil)
        if let pending {
            span = InteractionSpan(schemaVersion: 1, id: pending.id, operation: operation,
                                   startedUptime: pending.startedUptime, eventUptime: pending.eventUptime,
                                   startBoundary: pending.startBoundary, query: span.query, queryTruncated: span.queryTruncated,
                                   documentID: documentID, documentGeneration: nil, generation: nil, section: nil, sourceRoot: nil, fullText: nil,
                                   serviceFinishedUptime: nil, viewAppliedUptime: nil, outcome: nil, resultCount: nil, detail: nil)
        }
        span.generation = generation
        shared.active[operation] = span
    }

    static func documentBound(operation: InteractionOperation, generation: UUID, documentGeneration: UUID) {
        guard isEnabled, var span = shared.active[operation], span.generation == generation else { return }
        span.documentGeneration = documentGeneration
        shared.active[operation] = span
    }

    static func finished(operation: InteractionOperation, generation: UUID, outcome: InteractionOutcome, detail: String?) {
        guard isEnabled, let span = shared.active[operation], span.generation == generation else { return }
        shared.active.removeValue(forKey: operation)
        shared.finish(span, outcome: outcome, resultCount: nil, detail: detail)
    }

    static func viewApplied(operation: InteractionOperation, generation: UUID) {
        guard isEnabled, var span = shared.completed[generation], span.operation == operation,
              span.outcome == .completed || span.outcome == .reused, span.viewAppliedUptime == nil else { return }
        span.viewAppliedUptime = ProcessInfo.processInfo.systemUptime
        shared.completed[generation] = span
        shared.emit(span, phase: "view-applied")
    }

    private static func eventTimestamp(window: NSWindow?) -> Double? {
        guard let window, let event = NSApp.currentEvent, event.windowNumber == window.windowNumber,
              event.type == .keyDown || event.type == .leftMouseUp || event.type == .leftMouseDown else { return nil }
        return event.timestamp
    }

    private func newSpan(operation: InteractionOperation, query: String, documentID: String?, boundary: InteractionStartBoundary, eventUptime: Double?) -> InteractionSpan {
        InteractionSpan(schemaVersion: 1, id: UUID(), operation: operation, startedUptime: ProcessInfo.processInfo.systemUptime,
                        eventUptime: eventUptime, startBoundary: boundary, query: String(String.UnicodeScalarView(query.unicodeScalars.prefix(4_096))),
                        queryTruncated: query.unicodeScalars.count > 4_096, documentID: documentID, documentGeneration: nil, generation: nil,
                        section: nil, sourceRoot: nil, fullText: nil, serviceFinishedUptime: nil,
                        viewAppliedUptime: nil, outcome: nil, resultCount: nil, detail: nil)
    }

    private func supersedeSearch() {
        if let span = activeSearch { finish(span, outcome: .superseded, resultCount: nil, detail: "A different input replaced this search.") }
        activeSearch = nil
    }

    private func finish(_ original: InteractionSpan, outcome: InteractionOutcome, resultCount: Int?, detail: String?) {
        var span = original
        span.serviceFinishedUptime = ProcessInfo.processInfo.systemUptime
        span.outcome = outcome
        span.resultCount = resultCount
        span.detail = detail.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(2_048))) }
        if let generation = span.generation, outcome == .completed || outcome == .reused {
            completed[generation] = span
            completedOrder.append(generation)
            if completedOrder.count > maximumCompleted { completed.removeValue(forKey: completedOrder.removeFirst()) }
        }
        emit(span, phase: "service-finished")
    }

    private func emit(_ span: InteractionSpan, phase: String) {
        guard let writer, !outputFailed else { return }
        guard sequence < maximumRecords else {
            outputFailed = true
            Self.logger.error("Interaction diagnostics reached its 2000-record session limit. Relaunch with a new output path for another bounded probe.")
            return
        }
        sequence += 1
        let record = InteractionDiagnosticRecord(sequence: sequence, sessionID: sessionID,
            processID: ProcessInfo.processInfo.processIdentifier, phase: phase,
            clock: "Handler/service/view times use ProcessInfo.systemUptime. Optional eventUptime observes NSApp.currentEvent.timestamp; it is not verified as the causal input event and may be unrelated to AX actions.",
            endpointLimit: "Handler/binding to service completion or native view state applied; excludes pixel presentation and does not measure every lazy list row. Do not derive event-to-UI latency from the optional currentEvent observation.", span: span)
        Task {
            do { try await writer.append(record) }
            catch {
                outputFailed = true
                Self.logger.error("Cannot append local interaction diagnostics at \(writer.destination.path, privacy: .public): \(error.localizedDescription, privacy: .public). Choose a writable local JSONL path and relaunch.")
            }
        }
    }
}

/// A generation acknowledgement from SwiftUI to AppKit, not a paint/presentation callback.
struct InteractionViewProbe: NSViewRepresentable {
    let operation: InteractionOperation
    let generation: UUID?

    func makeNSView(context: Context) -> InteractionProbeView { InteractionProbeView() }

    func updateNSView(_ view: InteractionProbeView, context: Context) {
        view.operation = operation
        view.generation = generation
        view.acknowledge()
    }
}

@MainActor
final class InteractionProbeView: NSView {
    var operation: InteractionOperation?
    var generation: UUID?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        acknowledge()
    }

    func acknowledge() {
        guard window != nil, let operation, let generation else { return }
        InteractionDiagnostics.viewApplied(operation: operation, generation: generation)
    }
}
