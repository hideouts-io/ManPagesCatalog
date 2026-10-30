import XCTest
import PDFKit
import Darwin
@testable import Man_Page_Catalog

final class CatalogIntegrationTests: XCTestCase {
    func testManualProcessPreservesSmallOutputStreams() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let writer = try await compileManualOutputWriter(directory: directory)
        let receipt = directory.appendingPathComponent("completed")
        let result = try await runManualProcess(executable: writer, arguments: ["13", "7", "0", receipt.path], directory: directory, input: nil)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.bytes, Data(repeating: 79, count: 13))
        XCTAssertEqual(result.diagnostic, String(repeating: "E", count: 7))
        try assertManualOutputWriterReleased(receipt: receipt)
    }

    func testManualProcessRejectsCompletedOversizedDiagnostics() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let writer = try await compileManualOutputWriter(directory: directory)
        let receipt = directory.appendingPathComponent("completed")
        do {
            let result = try await runManualProcess(executable: writer, arguments: ["13", "67108865", "0", receipt.path], directory: directory, input: nil)
            XCTFail("Oversized diagnostics returned apparent success with \(result.diagnostic.utf8.count) bytes.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("64 MiB diagnostic output limit"), error.localizedDescription)
        }
        try assertManualOutputWriterReleased(receipt: receipt)
    }

    func testManualProcessAcceptsIndependentStreamLimits() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let writer = try await compileManualOutputWriter(directory: directory)
        for (name, counts, outputCount, diagnosticCount) in [("stdout", ["67108864", "1"], 67_108_864, 1),
                                                             ("stderr", ["1", "67108864"], 1, 67_108_864)] {
            let receipt = directory.appendingPathComponent(name)
            let result = try await runManualProcess(executable: writer, arguments: counts + ["0", receipt.path], directory: directory, input: nil)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.bytes.count, outputCount)
            XCTAssertEqual(result.diagnostic.utf8.count, diagnosticCount)
            try assertManualOutputWriterReleased(receipt: receipt)
        }
    }

    func testManualProcessRejectsActiveOversizedStreamsAndReapsWriters() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let writer = try await compileManualOutputWriter(directory: directory)
        for (name, counts, expected) in [("stdout", ["67108865", "7"], "64 MiB output limit"),
                                          ("stderr", ["13", "67108865"], "64 MiB diagnostic output limit")] {
            let receipt = directory.appendingPathComponent(name)
            do {
                _ = try await runManualProcess(executable: writer, arguments: counts + ["60", receipt.path], directory: directory, input: nil)
                XCTFail("An active writer exceeded its \(name) limit without failing.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
            }
            try assertManualOutputWriterReleased(receipt: receipt)
        }
    }

    func testManualProcessCancellationReapsWriterAndRemovesCaptures() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let writer = try await compileManualOutputWriter(directory: directory)
        let receipt = directory.appendingPathComponent("cancelled")
        let task = Task { try await runManualProcess(executable: writer, arguments: ["0", "0", "60", receipt.path], directory: directory, input: nil) }
        _ = try await readyManualOutputWriter(task: task, receipt: receipt)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled writer returned apparent success.")
        } catch is CancellationError { }
        try assertManualOutputWriterReleased(receipt: receipt)
    }

    func testManualProcessDeadlineReapsWriterAndRemovesCaptures() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let writer = try await compileManualOutputWriter(directory: directory)
        let receipt = directory.appendingPathComponent("timed-out")
        do {
            _ = try await runManualProcess(executable: writer, arguments: ["0", "0", "60", receipt.path], directory: directory, input: nil)
            XCTFail("A writer outlived its process deadline without failing.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("30-second timeout"), error.localizedDescription)
        }
        try assertManualOutputWriterReleased(receipt: receipt)
    }

    func testManualProcessPreservesCancellationWhenCaptureCleanupIsDenied() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let writer = try await compileManualOutputWriter(directory: directory)
        let receipt = directory.appendingPathComponent("cleanup-denied")
        let task = Task { try await runManualProcess(executable: writer, arguments: ["0", "0", "60", receipt.path], directory: directory, input: nil) }
        let recorded = try await readyManualOutputWriter(task: task, receipt: receipt)
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: recorded.captureDirectory.path) else { return }
            guard chmod(recorded.captureDirectory.path, 0o700) == 0 else {
                throw ManualToolError(message: "Cannot restore owned capture-directory permissions (POSIX \(errno)).")
            }
            try FileManager.default.removeItem(at: recorded.captureDirectory)
        }
        guard chmod(recorded.captureDirectory.path, 0o500) == 0 else {
            let code = errno
            task.cancel()
            do { _ = try await task.value }
            catch is CancellationError { }
            throw ManualToolError(message: "Cannot deny owned capture-directory cleanup (POSIX \(code)).")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation with denied cleanup returned apparent success.")
        } catch let error as ManualProcessCleanupError {
            XCTAssertTrue(error.cause is CancellationError)
            XCTAssertTrue(error.failures.contains(where: { $0.contains("Cannot remove capture directory") }), error.localizedDescription)
        }
        let present = kill(recorded.processID, 0)
        let code = errno
        XCTAssertEqual(present, -1)
        XCTAssertEqual(code, ESRCH)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorded.captureDirectory.path))
    }

    func testRealInstalledManualDescriptions() async throws {
        for (name, section, expected) in [("launchctl", "1", "launchd"), ("ping", "8", "ICMP"),
                                           ("ifconfig", "8", "network"), ("netstat", "1", "network"),
                                           ("scutil", "8", "configuration")] {
            let description = try await manualDescription(source: URL(fileURLWithPath: "/usr/share/man/man\(section)/\(name).\(section)"))
            XCTAssertTrue(description.localizedCaseInsensitiveContains(expected), "\(name): \(description)")
        }
    }

    func testManMdocMultilineGzipAndMissingDescription() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let samples: [(String, String)] = [
            (".Dd September 28, 2026\n.Dt SAMPLE 1\n.Os\n.Sh NAME\n.Nm sample\n.Nm alias\n.Nd inspect network\nconnections and routes\n.Sh DESCRIPTION\nBody.\n", "inspect network connections and routes"),
            (".TH SAMPLE 1\n.SH \"NAME\"\nsample, alias \\- inspect network\nconnections and routes\n.SH DESCRIPTION\nBody.\n", "inspect network connections and routes"),
            (".TH SAMPLE 1\n.SH DESCRIPTION\nNo NAME section.\n", "")
        ]
        for (index, sample) in samples.enumerated() {
            let source = directory.appendingPathComponent("sample\(index).1")
            try sample.0.write(to: source, atomically: true, encoding: .utf8)
            let description = try await manualDescription(source: source)
            XCTAssertEqual(description, sample.1)
            let compressed = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c", source.path], directory: directory, input: nil)
            let gzip = source.appendingPathExtension("gz")
            try compressed.write(to: gzip)
            let gzipDescription = try await manualDescription(source: gzip)
            XCTAssertEqual(gzipDescription, sample.1)
        }
        do {
            _ = try await manualDescription(source: directory.appendingPathComponent("missing.1"))
            XCTFail("Missing source must throw, not become an empty description")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing.1")) }
    }

    func testGenerationAndMetadataRefreshPreservePDFsAndFailedRefreshPreservesCatalog() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let root = directory.appendingPathComponent("manuals")
        let section = root.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        let source = section.appendingPathComponent("launchctl.1")
        try FileManager.default.copyItem(atPath: "/usr/share/man/man1/launchctl.1", toPath: source.path)
        let output = directory.appendingPathComponent("catalog")
        try await generateCatalog(directory: output, roots: [root], environment: [:], progress: { _ in })
        var catalog = try loadCatalog(directory: output)
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries[0].description, "Interfaces with launchd")
        let pdf = output.appendingPathComponent(catalog.entries[0].pdf_path)
        let bytes = try Data(contentsOf: pdf)
        let modified = try pdf.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: pdf)?.string).contains("launchctl"))
        let entry = catalog.entries[0]
        try writeCatalog(entries: [CatalogEntry(name: entry.name, section: entry.section, description: "",
                                                pdf_path: entry.pdf_path, source_path: entry.source_path,
                                                executable_path: entry.executable_path)], directory: output)
        try await refreshCatalogMetadata(directory: output, environment: [:], progress: { _ in })
        catalog = try loadCatalog(directory: output)
        XCTAssertEqual(catalog.entries[0].description, "Interfaces with launchd")
        XCTAssertEqual(try Data(contentsOf: pdf), bytes)
        XCTAssertEqual(try pdf.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        let catalogBytes = try Data(contentsOf: output.appendingPathComponent("catalog.json"))
        try FileManager.default.removeItem(at: source)
        do {
            try await refreshCatalogMetadata(directory: output, environment: [:], progress: { _ in })
            XCTFail("Refresh with missing source must fail")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("catalog.json")), catalogBytes)
    }

    @MainActor
    func testPDFReaderRetainsDocumentScaleAndSelectionAndFindsText() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let url = directory.appendingPathComponent("launchctl.pdf")
        try await renderManual(source: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), destination: url)
        let reader = PDFReader()
        reader.load(url: url)
        XCTAssertNil(reader.errorMessage)
        let document = try XCTUnwrap(reader.view.document)
        let page = try XCTUnwrap(document.page(at: 1))
        reader.view.autoScales = false
        reader.view.scaleFactor = 1.7
        reader.view.go(to: page)
        let selection = try XCTUnwrap(document.findString("bootstrap", withOptions: .caseInsensitive).first)
        reader.view.setCurrentSelection(selection, animate: false)
        let selectedText = reader.view.currentSelection?.string
        reader.load(url: url)
        XCTAssertTrue(reader.view.document === document)
        XCTAssertEqual(reader.view.scaleFactor, 1.7, accuracy: 0.01)
        XCTAssertEqual(reader.view.currentSelection?.string, selectedText)
        reader.search(query: "bootstrap")
        for _ in 0..<200 where reader.searching { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(reader.searching)
        XCTAssertGreaterThan(reader.matchCount, 1)
        XCTAssertEqual(reader.matchIndex, 1)
        reader.nextMatch()
        XCTAssertEqual(reader.matchIndex, 2)
        reader.previousMatch()
        XCTAssertEqual(reader.matchIndex, 1)
        let corrupt = directory.appendingPathComponent("corrupt.pdf")
        try Data("invalid PDF".utf8).write(to: corrupt)
        reader.load(url: corrupt)
        XCTAssertNotNil(reader.errorMessage)
        XCTAssertNil(reader.view.document)
        reader.load(url: directory.appendingPathComponent("missing.pdf"))
        XCTAssertTrue(reader.errorMessage?.contains("missing.pdf") == true)
    }

    @MainActor
    func testCatalogErrorsAndRapidReloadsRetainNewestValidData() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let suite = "ManPagesCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CatalogStore(defaults: defaults)
        XCTAssertEqual(store.state, .firstLaunch)
        let old = directory.appendingPathComponent("old")
        let newest = directory.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newest, withIntermediateDirectories: true)
        let first = CatalogEntry(name: "old", section: "1", description: "old", pdf_path: "old.pdf", source_path: nil, executable_path: nil)
        let last = CatalogEntry(name: "new", section: "8", description: "new network", pdf_path: "new.pdf", source_path: nil, executable_path: nil)
        try writeCatalog(entries: [first], directory: old)
        try writeCatalog(entries: [last], directory: newest)
        store.outputDir = old
        store.outputDir = newest
        for _ in 0..<200 where store.state == .loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.entries.map(\.name), ["new"])
        XCTAssertEqual(store.filteredEntries(section: "1", query: "network").count, 0)
        XCTAssertEqual(store.filteredEntries(section: nil, query: "network").count, 1)
        try Data("{invalid".utf8).write(to: newest.appendingPathComponent("catalog.json"))
        store.reload()
        for _ in 0..<200 where store.state == .loading { try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .failed = store.state else { return XCTFail("Invalid catalog must surface an error") }
        XCTAssertEqual(store.entries.map(\.name), ["new"])
        try writeCatalog(entries: [], directory: newest)
        store.reload()
        for _ in 0..<200 where store.state == .loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.state, .empty)
    }

    func testCancellationPreservesExistingCatalog() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        try writeCatalog(entries: [], directory: directory)
        let before = try Data(contentsOf: directory.appendingPathComponent("catalog.json"))
        let task = Task {
            try await generateCatalog(directory: directory, roots: [URL(fileURLWithPath: "/usr/share/man")], environment: [:], progress: { _ in })
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled operation must throw") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("catalog.json")), before)
    }

    private func compileManualOutputWriter(directory: URL) async throws -> URL {
        let source = directory.appendingPathComponent("output-writer.c")
        let executable = directory.appendingPathComponent("output-writer")
        try #"""
        #include <errno.h>
        #include <fcntl.h>
        #include <limits.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        int main(int argc, char **argv) {
            if (argc != 5) return 64;
            char input[PATH_MAX], pending[PATH_MAX];
            if (fcntl(STDIN_FILENO, F_GETPATH, input) == -1) return 65;
            int length = snprintf(pending, sizeof(pending), "%s.pending", argv[4]);
            if (length < 0 || (size_t)length >= sizeof(pending)) return 66;
            int receipt = open(pending, O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (receipt == -1) return 67;
            if (dprintf(receipt, "%d\n%s\n", getpid(), input) < 0 || close(receipt) == -1) return 68;
            if (rename(pending, argv[4]) == -1) return 69;
            uint64_t counts[] = { strtoull(argv[1], NULL, 10), strtoull(argv[2], NULL, 10) };
            unsigned char block[65536];
            for (int stream = 0; stream < 2; stream++) {
                memset(block, stream == 0 ? 'O' : 'E', sizeof(block));
                while (counts[stream] > 0) {
                    size_t amount = counts[stream] < sizeof(block) ? (size_t)counts[stream] : sizeof(block);
                    ssize_t written = write(stream == 0 ? STDOUT_FILENO : STDERR_FILENO, block, amount);
                    if (written < 0) return 70;
                    counts[stream] -= (uint64_t)written;
                }
            }
            unsigned int remaining = (unsigned int)strtoul(argv[3], NULL, 10);
            while (remaining > 0) remaining = sleep(remaining);
            return 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        _ = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/clang"),
                                    arguments: ["-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path], directory: directory, input: nil)
        return executable
    }

    private func readyManualOutputWriter(task: Task<ManualProcessResult, Error>, receipt: URL) async throws -> (processID: Int32, captureDirectory: URL) {
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !FileManager.default.fileExists(atPath: receipt.path) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw ManualToolError(message: "Owned output writer did not publish its readiness receipt within ten seconds.")
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return try manualOutputWriterReceipt(receipt: receipt)
        } catch let readinessError {
            task.cancel()
            do { _ = try await task.value }
            catch is CancellationError { }
            catch { XCTFail("Writer cleanup after readiness failure failed: \(error)") }
            throw readinessError
        }
    }

    private func assertManualOutputWriterReleased(receipt: URL) throws {
        let recorded = try manualOutputWriterReceipt(receipt: receipt)
        let present = kill(recorded.processID, 0)
        let code = errno
        XCTAssertEqual(present, -1, "Owned output writer is still present.")
        XCTAssertEqual(code, ESRCH, "Owned output writer was not reaped.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.captureDirectory.path), "Formatter captures were retained after completion or failure.")
    }

    private func manualOutputWriterReceipt(receipt: URL) throws -> (processID: Int32, captureDirectory: URL) {
        let fields = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(fields.count, 2)
        guard fields.count == 2, let processID = Int32(fields[0]) else {
            throw ManualToolError(message: "Owned output writer produced an invalid receipt.")
        }
        let input = URL(fileURLWithPath: String(fields[1]))
        let captureDirectory = input.deletingLastPathComponent()
        let captureParent = captureDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard processID > 0, input.lastPathComponent == "stdin", captureParent.path == temporary.path,
              UUID(uuidString: captureDirectory.lastPathComponent) != nil else {
            throw ManualToolError(message: "Owned output writer receipt does not identify its UUID capture directory.")
        }
        return (processID: processID, captureDirectory: captureDirectory)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManPagesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeTemporary(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Cannot clean test directory \(directory.path): \(error)") }
    }
}
