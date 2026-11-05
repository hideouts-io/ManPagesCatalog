import XCTest
import PDFKit
import Darwin
import Compression
@testable import Man_Page_Catalog

final class CatalogIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 120
    }

    func testNativeXZDecodesInstalledManualAndPreservesIncludePipeline() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let original = try Data(contentsOf: URL(fileURLWithPath: "/usr/share/man/man1/zshroadmap.1"))
        let compressed = try encodedXZTestData(bytes: original)
        for name in ["reference.1.xz", "renamed-xz", "misleading.1.gz", "misleading.1.lzma", "misleading.1.zst"] {
            let source = directory.appendingPathComponent(name)
            try compressed.write(to: source)
            let decoded = try await manualBytes(source: source)
            XCTAssertEqual(decoded, original, name)
        }
        let legacyRoot = directory.appendingPathComponent("legacy")
        let legacySection = legacyRoot.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: legacySection, withIntermediateDirectories: true)
        let legacySource = legacySection.appendingPathComponent("reference.1.xz")
        try compressed.write(to: legacySource)
        let output = directory.appendingPathComponent("xz-catalog")
        try await generateCatalog(directory: output, roots: [legacyRoot], environment: [:], progress: { _ in })
        let entries = try loadCatalog(directory: output).entries
        XCTAssertEqual(entries.map(\.name), ["reference"])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(entry.source_path)).resolvingSymlinksInPath(),
                       legacySource.resolvingSymlinksInPath())
        let legacyPDF = try Data(contentsOf: output.appendingPathComponent(entry.pdf_path))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: legacyPDF)?.string).localizedCaseInsensitiveContains("zshroadmap"))
        let section = directory.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: false)
        let body = section.appendingPathComponent("body.1.xz")
        let marker = Data("XZ embedded dependency marker.\n".utf8)
        try encodedXZTestData(bytes: marker).write(to: body)
        let source = section.appendingPathComponent("aggregate.1")
        try ".TH XZAGGREGATE 1\n.SH NAME\nxzaggregate \\- native XZ integration\n.SH DESCRIPTION\n.so man1/body.1\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let input = try await manualInput(source: source)
        XCTAssertEqual(input.dependencies.map { $0.resolved.lastPathComponent }, ["aggregate.1", "body.1.xz"])
        XCTAssertEqual(input.dependencies.map(\.parent), [nil, 0])
        XCTAssertEqual(input.dependencies.last?.digest, manualContentDigest(marker))
        let text = try await formattedManualText(input: input)
        XCTAssertTrue(text.diagnostic.isEmpty, text.diagnostic)
        XCTAssertTrue(text.text.contains("XZ embedded dependency marker."))
        let html = try await manualHTML(input: input)
        XCTAssertTrue(html.contains("XZ embedded dependency marker."))
        let pdf = try await renderedManualPDF(input: input)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: pdf)?.string).contains("XZ embedded dependency marker."))
        let scope = ManualSourceScope(traversalRoots: [directory], resolvedTraversalRoots: [directory.resolvingSymlinksInPath()],
            traversalExclusions: [DiscoveryIssue(path: body.path, kind: .excluded, reason: "Owned XZ target excluded.")],
            resolvedTraversalExclusions: [body.resolvingSymlinksInPath()], excludedMountedVolumes: [])
        do {
            _ = try await sourceManualInput(source: source, scope: scope,
                access: ManualSourceAccess(generation: UUID(), allowedNetworkRoots: []))
            XCTFail("A compressed include must not bypass its source policy.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Owned XZ target excluded"), error.localizedDescription) }
    }

    func testXZExternalContainersRejectEveryIntegrityFailure() throws {
        let source = URL(fileURLWithPath: "/owned-xz-fixture.1.xz")
        let expected = externalXZTestPlaintext()
        XCTAssertEqual(manualContentDigest(expected), "3c8bc382633f1bde506293997d6078ab1571f3f730c875d5ebea54f56e52302f")
        for fixture in try externalXZTestContainers() {
            XCTAssertEqual(try decodeXZManual(bytes: fixture.bytes, source: source), expected)
            for offset in fixture.checksumOffsets {
                var corrupt = fixture.bytes
                corrupt[offset] ^= 1
                XCTAssertThrowsError(try decodeXZManual(bytes: corrupt, source: source)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("XZ decompression failed"), error.localizedDescription)
                }
            }
        }
    }

    func testXZRejectsTrailingDataTruncationAndUnsupportedLZMA() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let valid = try XCTUnwrap(externalXZTestContainers().first).bytes
        let source = directory.appendingPathComponent("fixture.1.xz")
        for invalid in [valid + valid, valid + Data([0, 0, 0, 0]), valid + Data("trailing".utf8)] {
            XCTAssertThrowsError(try decodeXZManual(bytes: invalid, source: source)) { error in
                XCTAssertTrue(error.localizedDescription.contains("concatenated streams, padding or trailing data"), error.localizedDescription)
            }
        }
        for invalid in [Data(valid.dropLast()), Data(valid.dropLast(12)), Data(valid.prefix(valid.count / 2))] {
            XCTAssertThrowsError(try decodeXZManual(bytes: invalid, source: source)) { error in
                XCTAssertTrue(error.localizedDescription.contains("truncated"), error.localizedDescription)
            }
        }
        try externalXZTestPlaintext().write(to: source)
        do {
            _ = try await manualBytes(source: source)
            XCTFail("A declared XZ source without XZ magic must fail before formatting.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid XZ manual header"), error.localizedDescription) }
        let alone = try XCTUnwrap(Data(base64Encoded: "XQAAgAD//////////wAXFQUCAmm3QyI3bP1js6dYsUXA+0xUXT0tGcAxTHAOBcE50SN30gDi/tqsfjqlBrcEF+5T24kEvVR7brttg3gKjBtxdL2FfQMaaPRd+CIQ8TfgJVt/+hNtTuolrgRe0KMc5x8Hn+s79q6rz9srxuYH+DKC/+HquAA="))
        XCTAssertThrowsError(try decodeXZManual(bytes: alone, source: source)) { error in
            XCTAssertTrue(error.localizedDescription.contains(".lzma-alone and raw LZMA are unsupported"), error.localizedDescription)
        }
        let lzmaSource = directory.appendingPathComponent("fixture.1.lzma")
        try alone.write(to: lzmaSource)
        do {
            _ = try await manualBytes(source: lzmaSource)
            XCTFail("Undocumented native .lzma-alone decoding must remain unsupported.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Unsupported lzma"), error.localizedDescription) }
        let empty = try encodedXZTestData(bytes: Data())
        XCTAssertEqual(try decodeXZManual(bytes: empty, source: source), Data())
    }

    func testXZDecodedOutputLimitAndCancellation() async throws {
        let source = URL(fileURLWithPath: "/owned-xz-limit.1.xz")
        let compressed = try encodedXZTestData(bytes: Data(repeating: 65, count: 64 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try decodeXZManual(bytes: compressed, source: source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("64 MiB decoded output limit"), error.localizedDescription)
        }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try decodeXZManual(bytes: compressed, source: source)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled XZ acquisition must not publish plaintext.")
        } catch is CancellationError { }
    }

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
        Self.deniedCleanupStage("test-enter")
        let directory = try temporaryDirectory()
        defer {
            Self.deniedCleanupStage("fixture-cleanup-enter")
            removeTemporary(directory)
            Self.deniedCleanupStage("fixture-cleanup-leave")
        }
        Self.deniedCleanupStage("compiler-helper-enter")
        let writer = try await compileManualOutputWriter(directory: directory)
        Self.deniedCleanupStage("compiler-helper-return")
        let receipt = directory.appendingPathComponent("cleanup-denied")
        let task = Task { try await runManualProcess(executable: writer, arguments: ["0", "0", "60", receipt.path], directory: directory, input: nil) }
        Self.deniedCleanupStage("writer-readiness-enter")
        let recorded = try await readyManualOutputWriter(task: task, receipt: receipt)
        Self.deniedCleanupStage("writer-ready")
        addTeardownBlock {
            Self.deniedCleanupStage("capture-teardown-enter")
            defer { Self.deniedCleanupStage("capture-teardown-leave") }
            guard FileManager.default.fileExists(atPath: recorded.captureDirectory.path) else { return }
            Self.deniedCleanupStage("capture-permissions-restore-enter")
            guard chmod(recorded.captureDirectory.path, 0o700) == 0 else {
                throw ManualToolError(message: "Cannot restore owned capture-directory permissions (POSIX \(errno)).")
            }
            Self.deniedCleanupStage("capture-permissions-restore-return")
            Self.deniedCleanupStage("capture-remove-enter")
            try FileManager.default.removeItem(at: recorded.captureDirectory)
            Self.deniedCleanupStage("capture-remove-return")
        }
        Self.deniedCleanupStage("cleanup-denial-enter")
        guard chmod(recorded.captureDirectory.path, 0o500) == 0 else {
            let code = errno
            Self.deniedCleanupStage("failure-cancel-enter")
            task.cancel()
            Self.deniedCleanupStage("failure-task-drain-enter")
            do { _ = try await task.value }
            catch is CancellationError { }
            throw ManualToolError(message: "Cannot deny owned capture-directory cleanup (POSIX \(code)).")
        }
        Self.deniedCleanupStage("cleanup-denial-return")
        Self.deniedCleanupStage("cancel-enter")
        task.cancel()
        Self.deniedCleanupStage("cancel-return")
        Self.deniedCleanupStage("task-completion-enter")
        do {
            _ = try await task.value
            XCTFail("Cancellation with denied cleanup returned apparent success.")
        } catch let error as ManualProcessCleanupError {
            Self.deniedCleanupStage("task-threw-cleanup-error")
            XCTAssertTrue(error.cause is CancellationError)
            XCTAssertTrue(error.failures.contains(where: { $0.contains("Cannot remove capture directory") }), error.localizedDescription)
        }
        Self.deniedCleanupStage("task-completion-return")
        let present = kill(recorded.processID, 0)
        let code = errno
        XCTAssertEqual(present, -1)
        XCTAssertEqual(code, ESRCH)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorded.captureDirectory.path))
        Self.deniedCleanupStage("postconditions-completed")
    }

    /// Diagnostic-only repeated real cancellation; owned capture teardowns run after this invocation.
    func testManualProcessDeniedCleanupTwentyDiagnosticInvocations() async throws {
        for _ in 0..<20 {
            Self.deniedCleanupStage("repetition-enter")
            try await testManualProcessPreservesCancellationWhenCaptureCleanupIsDenied()
            Self.deniedCleanupStage("repetition-body-return")
        }
        Self.deniedCleanupStage("all-repetition-bodies-returned")
    }

    /// Write bounded static stages directly without stdio buffering or the production Process runner.
    private static func deniedCleanupStage(_ stage: StaticString) {
        let bytes: [UInt8] = Array(("DENIED-CLEANUP-STAGE " + String(describing: stage) + "\n").utf8)
        let result: (written: Int, code: Int32) = bytes.withUnsafeBytes { buffer in
            let written: Int = Darwin.write(STDERR_FILENO, buffer.baseAddress, buffer.count)
            return (written, written < 0 ? errno : 0)
        }
        if result.written != bytes.count {
            XCTFail("Cannot write the static denied-cleanup stage marker: wrote \(result.written) of \(bytes.count) bytes (POSIX \(result.code)).")
        }
    }

    func testRealInstalledManualDescriptions() async throws {
        for (name, section, expected) in [("launchctl", "1", "launchd"), ("ping", "8", "ICMP"),
                                           ("ifconfig", "8", "network"), ("netstat", "1", "network"),
                                           ("scutil", "8", "configuration")] {
            let description = try await manualDescription(source: URL(fileURLWithPath: "/usr/share/man/man\(section)/\(name).\(section)"))
            XCTAssertTrue(description.localizedCaseInsensitiveContains(expected), "\(name): \(description)")
        }
    }

    func testInstalledAtosPartialFormattingExplainsPDFRefusalAndPreservesDestination() async throws {
        let source = URL(fileURLWithPath: "/usr/share/man/man1/atos.1")
        let input = try await manualInput(source: source)
        let formatted = try await formattedManualText(input: input)
        XCTAssertTrue(formatted.text.localizedCaseInsensitiveContains("atos"))
        XCTAssertFalse(formatted.diagnostic.isEmpty, "The installed partial-output control must retain its actual parsing diagnostic.")
        let html = try await manualHTML(input: input)
        XCTAssertTrue(html.contains("<aside role=\"note\">"))
        XCTAssertTrue(html.contains("<pre>" + escapedHTML(formatted.diagnostic) + "</pre>"), formatted.diagnostic)

        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let destination = directory.appendingPathComponent("existing.pdf")
        try await renderManual(source: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), destination: destination)
        let retained = try Data(contentsOf: destination)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: retained)?.string).contains("bootstrap"))
        do {
            try await renderManual(source: source, destination: destination)
            XCTFail("Partial manual output must not replace an existing error-free PDF.")
        } catch let error as ManualToolError {
            XCTAssertTrue(error.localizedDescription.hasPrefix("mandoc PDF rendering failed (exit 3):"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("inserting missing end of block"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: destination), retained)
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

    func testInstalledZshallExpandedIncludesMatchSystemTextAndPDF() async throws {
        let source = URL(fileURLWithPath: "/usr/share/man/man1/zshall.1")
        let root = source.deletingLastPathComponent().deletingLastPathComponent()
        let input = try await manualInput(source: source)
        XCTAssertEqual(input.dependencies.count, 15, "The installed aggregate has fourteen included manuals.")
        XCTAssertEqual(input.dependencies.first?.resolved, source.resolvingSymlinksInPath())
        XCTAssertEqual(input.dependencies.dropFirst().map(\.parent), Array(repeating: Optional(0), count: 14))
        XCTAssertEqual(Set(input.dependencies.map(\.resolved)).count, 15)
        let original = try Data(contentsOf: source)
        let systemText = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/mandoc"),
            arguments: ["-Werror", "-Tutf8", "-O", "width=1000"], directory: root, input: original)
        let plain = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/col"),
            arguments: ["-b"], directory: root, input: systemText)
        let expandedText = try await formattedManualText(input: input)
        XCTAssertTrue(expandedText.diagnostic.isEmpty, expandedText.diagnostic)
        XCTAssertEqual(Data(expandedText.text.utf8), plain)
        XCTAssertTrue(expandedText.text.contains("DESCRIPTION OF OPTIONS"))
        let systemPDF = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/mandoc"),
            arguments: ["-Werror", "-Tpdf"], directory: root, input: original)
        let expandedPDF = try await renderedManualPDF(input: input)
        XCTAssertEqual(expandedPDF, systemPDF)
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(data: expandedPDF)).pageCount, 100)
    }

    func testEmbeddedIncludesResolveCompressedRepeatedAndNestedTargets() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let section = directory.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: false)
        let source = section.appendingPathComponent("aggregate.1")
        try ".TH AGGREGATE 1\n.SH NAME\naggregate \\- include integration\n.SH DESCRIPTION\n.so man1/body.1\n.so man1/body.1\n.so man1/nested.1\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let body = section.appendingPathComponent("body.1")
        try "Repeated compressed include marker.\n".write(to: body, atomically: true, encoding: .utf8)
        let gzip = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/gzip"),
            arguments: ["-c", body.path], directory: directory, input: nil)
        try gzip.write(to: body.appendingPathExtension("gz"))
        try FileManager.default.removeItem(at: body)
        try ".PP\n.so man1/leaf.1\n".write(to: section.appendingPathComponent("nested.1"), atomically: true, encoding: .utf8)
        let leaf = section.appendingPathComponent("leaf.1")
        try "Nested bzip include marker.\n".write(to: leaf, atomically: true, encoding: .utf8)
        let bzip = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/bzip2"),
            arguments: ["-c", leaf.path], directory: directory, input: nil)
        try bzip.write(to: leaf.appendingPathExtension("bz2"))
        try FileManager.default.removeItem(at: leaf)
        let input = try await manualInput(source: source)
        XCTAssertEqual(input.dependencies.map { $0.resolved.lastPathComponent },
            ["aggregate.1", "body.1.gz", "body.1.gz", "nested.1", "leaf.1.bz2"])
        XCTAssertEqual(input.dependencies.map(\.parent), [nil, 0, 0, 0, 3])
        XCTAssertEqual(input.dependencies.dropFirst().map(\.line), [5, 6, 7, 2])
        let text = try await formattedManualText(input: input)
        XCTAssertTrue(text.diagnostic.isEmpty, text.diagnostic)
        XCTAssertEqual(text.text.components(separatedBy: "Repeated compressed include marker.").count - 1, 2)
        XCTAssertTrue(text.text.contains("Nested bzip include marker."))
        let html = try await manualHTML(input: input)
        XCTAssertTrue(html.contains("Nested bzip include marker."))
        let pdf = try await renderedManualPDF(input: input)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: pdf)?.string).contains("Nested bzip include marker."))
    }

    func testWholeFileAliasPreservesExactTargetIdentityWithoutFinalNewline() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let section = directory.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: false)
        let target = section.appendingPathComponent("original.1")
        let bytes = Data(".TH ORIGINAL 1\n.SH NAME\noriginal \\- exact alias identity\n.SH DESCRIPTION\nNo final newline.".utf8)
        try bytes.write(to: target)
        let alias = section.appendingPathComponent("alias.1")
        try ".\\\" Alias package comment\n\n.so man1/original.1\n\n".write(to: alias, atomically: true, encoding: .utf8)
        let input = try await manualInput(source: alias)
        XCTAssertEqual(input.bytes, bytes, "Alias comments and newline normalization must not change the target's content identity.")
        XCTAssertEqual(input.dependencies.count, 2)
        let scan = try await discoverLibrary(plan: DiscoveryPlan(roots: [directory], allowedNetworkRoots: [], exclusions: []),
            previous: [], progress: { _ in })
        XCTAssertEqual(scan.pages.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(scan.pages.first).locations.map(\.name)), ["alias", "original"])
    }

    func testEmbeddedIncludeMissingCycleDepthAndExpansionFailuresAreExplicit() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let section = directory.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: false)
        let source = section.appendingPathComponent("aggregate.1")
        let prefix = ".TH AGGREGATE 1\n.SH NAME\naggregate \\- bounded include integration\n.SH DESCRIPTION\n"
        try (prefix + ".so man1/missing.1\n").write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await manualInput(source: source)
            XCTFail("A missing include must not become partial output.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing.1"), error.localizedDescription) }
        try (prefix + ".so " + String(repeating: "x", count: Int(MAXPATHLEN)) + "\n")
            .write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await manualInput(source: source)
            XCTFail("An overlong include target must fail before constructing filesystem candidates.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("filesystem path limit"), error.localizedDescription) }
        try (prefix + ".so man1/cycle.1\n").write(to: source, atomically: true, encoding: .utf8)
        try ".so man1/aggregate.1\n".write(to: section.appendingPathComponent("cycle.1"), atomically: true, encoding: .utf8)
        do {
            _ = try await manualInput(source: source)
            XCTFail("A recursive include must fail.")
        } catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("cycle"), error.localizedDescription) }
        try (prefix + ".so man1/depth0.1\n").write(to: source, atomically: true, encoding: .utf8)
        for index in 0..<34 {
            let contents = index == 33 ? "Bounded leaf.\n" : ".so man1/depth\(index + 1).1\n"
            try contents.write(to: section.appendingPathComponent("depth\(index).1"), atomically: true, encoding: .utf8)
        }
        do {
            _ = try await manualInput(source: source)
            XCTFail("A graph beyond the depth limit must fail.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("32"), error.localizedDescription) }
        let large = section.appendingPathComponent("large.1")
        try (String(repeating: "x", count: 1024 * 1024) + "\n").write(to: large, atomically: true, encoding: .utf8)
        try (prefix + String(repeating: ".so man1/large.1\n", count: 65)).write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await manualInput(source: source)
            XCTFail("Repeated includes must count toward the decoded/expanded byte limit.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("64 MiB"), error.localizedDescription) }
        try "".write(to: section.appendingPathComponent("empty.1"), atomically: true, encoding: .utf8)
        try (prefix + String(repeating: ".so man1/empty.1\n", count: 1025)).write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await manualInput(source: source)
            XCTFail("Empty includes must still count toward the graph occurrence limit.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("1024"), error.localizedDescription) }
    }

    func testGeneratedIncludesCannotReadTheOriginalSourceDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let section = directory.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: false)
        let source = section.appendingPathComponent("generated.1")
        let marker = "OwnedIncludeCanary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try (marker + "\n").write(to: directory.appendingPathComponent("canary.1"), atomically: true, encoding: .utf8)
        let prefix = ".TH GENERATED 1\n.SH NAME\ngenerated \\- controlled include boundary\n.SH DESCRIPTION\n"
        let requests: [String] = [
            ".nop .so canary.1\n", ".if 1 .so canary.1\n", ".ds xx .so canary.1\n\\*[xx]\n",
            ".s\\*[undefined]o canary.1\n", ".s\\\no canary.1\n", ".cc !\n!so canary.1\n",
            ".de xx\n.so canary.1\n..\n.xx\n", ".mso canary.1\n"
        ]
        let witness = try await runManualProcess(executable: URL(fileURLWithPath: "/usr/bin/mandoc"),
            arguments: ["-Werror", "-Tutf8"], directory: directory, input: Data((prefix + requests[0]).utf8))
        XCTAssertTrue(String(decoding: witness.bytes, as: UTF8.self).contains(marker),
            "The owned witness must demonstrate mandoc's implicit source read before testing its boundary.")
        for request in requests {
            try (prefix + request).write(to: source, atomically: true, encoding: .utf8)
            do {
                let formatted = try await formattedManualText(source: source)
                XCTAssertFalse(formatted.text.contains(marker), "Unvalidated source bytes escaped into output: \(request)")
                XCTFail("Generated or macro includes must fail explicitly: \(request)")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        // Ordinary string and macro definitions remain supported when they perform no includes.
        try (prefix + ".ds xx HarmlessStringMarker\n.de yy\nHarmlessMacroMarker\n..\n\\*[xx]\n.yy\n")
            .write(to: source, atomically: true, encoding: .utf8)
        let ordinary = try await formattedManualText(source: source)
        XCTAssertTrue(ordinary.text.contains("HarmlessStringMarker"))
        XCTAssertTrue(ordinary.text.contains("HarmlessMacroMarker"))
        XCTAssertFalse(ordinary.text.contains(marker))
    }

    func testCatalogRegenerationUsesCurrentSourceWhenModificationTimeIsUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let root = directory.appendingPathComponent("manuals")
        let section = root.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        let source = section.appendingPathComponent("revision.1")
        try ".TH REVISION 1\n.SH NAME\nrevision \\- old package description\n.SH DESCRIPTION\nOriginalSourceRevisionMarker.\n"
            .write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: source.path)
        let originalDate = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let output = directory.appendingPathComponent("catalog")
        try await generateCatalog(directory: output, roots: [root], environment: [:], progress: { _ in })
        let first = try XCTUnwrap(loadCatalog(directory: output).entries.first)
        let pdf = output.appendingPathComponent(first.pdf_path)
        let originalPDF = try Data(contentsOf: pdf)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: originalPDF)?.string).contains("OriginalSourceRevisionMarker"))
        try ".TH REVISION 1\n.SH NAME\nrevision \\- new package description\n.SH DESCRIPTION\nUpdatedSourceRevisionMarker.\n"
            .write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: source.path)
        let observedDate = try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(observedDate, originalDate, "The fixture must preserve the timestamp used by the former PDF cache.")
        try await generateCatalog(directory: output, roots: [root], environment: [:], progress: { _ in })
        let regenerated = try XCTUnwrap(loadCatalog(directory: output).entries.first)
        let currentDescription = try await manualDescription(source: source)
        let currentText = try await manualText(source: source)
        XCTAssertEqual(regenerated.description, currentDescription)
        XCTAssertEqual(regenerated.description, "new package description")
        XCTAssertTrue(currentText.contains("UpdatedSourceRevisionMarker"))
        let updatedPDF = try Data(contentsOf: output.appendingPathComponent(regenerated.pdf_path))
        let updatedText = try XCTUnwrap(PDFDocument(data: updatedPDF)?.string)
        XCTAssertNotEqual(updatedPDF, originalPDF)
        XCTAssertTrue(updatedText.contains("UpdatedSourceRevisionMarker"))
        XCTAssertFalse(updatedText.contains("OriginalSourceRevisionMarker"))
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

    func testMetadataRefreshRejectsFormattingDiagnosticsAndPreservesPriorArtifacts() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let root = directory.appendingPathComponent("manuals")
        let section = root.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        let source = section.appendingPathComponent("refresh.1")
        try ".TH REFRESH 1\n.SH NAME\nrefresh \\- original verified description\n.SH DESCRIPTION\nOriginal body.\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("catalog")
        try await generateCatalog(directory: output, roots: [root], environment: [:], progress: { _ in })
        let catalog = try loadCatalog(directory: output)
        let pdf = output.appendingPathComponent(try XCTUnwrap(catalog.entries.first).pdf_path)
        let catalogURL = output.appendingPathComponent("catalog.json")
        let catalogBytes = try Data(contentsOf: catalogURL)
        let pdfBytes = try Data(contentsOf: pdf)
        try ".TH REFRESH 1\n.SH NAME\nrefresh \\- changed unverified description\n.SH DESCRIPTION\n.NotARealMacro markup failure\nChanged body.\n"
            .write(to: source, atomically: true, encoding: .utf8)
        do {
            try await refreshCatalogMetadata(directory: output, environment: [:], progress: { _ in })
            XCTFail("Metadata refresh must not silently publish a description from incomplete formatting.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("skipping unknown macro"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("NotARealMacro"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBytes)
        XCTAssertEqual(try Data(contentsOf: pdf), pdfBytes)
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
        let toolchain = try toolchainForLoadedXCTest()
        _ = try await runManualTool(executable: toolchain.compiler,
                                    arguments: ["-isysroot", toolchain.sdk.path, "-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path], directory: directory, input: nil)
        return executable
    }

    /// Use the compiler and SDK beside loaded XCTest; system shims can select another Xcode and incompatible frameworks.
    private func toolchainForLoadedXCTest() throws -> (compiler: URL, sdk: URL) {
        let framework: URL = Bundle(for: XCTestCase.self).bundleURL.resolvingSymlinksInPath()
        guard framework.isFileURL, framework.pathExtension == "framework" else {
            throw ManualToolError(message: "Cannot compile the owned output fixture: loaded XCTest has an unexpected framework location at \(framework.path).")
        }
        var container: URL = framework
        while container.path != "/" {
            if container.pathExtension == "app", Bundle(url: container)?.bundleIdentifier == "com.apple.dt.Xcode" {
                let developer: URL = container.appendingPathComponent("Contents/Developer", isDirectory: true).resolvingSymlinksInPath()
                let compiler: URL = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang").resolvingSymlinksInPath()
                let values: URLResourceValues
                do { values = try compiler.resourceValues(forKeys: [.isRegularFileKey]) }
                catch { throw ManualToolError(message: "Cannot inspect the compiler for loaded XCTest at \(compiler.path): \(error.localizedDescription)") }
                guard compiler.path.hasPrefix(developer.path + "/Toolchains/XcodeDefault.xctoolchain/"),
                      values.isRegularFile == true, FileManager.default.isExecutableFile(atPath: compiler.path) else {
                    throw ManualToolError(message: "Cannot compile the owned output fixture: loaded XCTest's Xcode has no executable default-toolchain compiler at \(compiler.path).")
                }
                let sdk: URL = developer.appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", isDirectory: true).resolvingSymlinksInPath()
                let sdkValues: URLResourceValues
                do { sdkValues = try sdk.resourceValues(forKeys: [.isDirectoryKey]) }
                catch { throw ManualToolError(message: "Cannot inspect the macOS SDK for loaded XCTest at \(sdk.path): \(error.localizedDescription)") }
                guard sdk.path.hasPrefix(developer.path + "/Platforms/MacOSX.platform/Developer/SDKs/"), sdkValues.isDirectory == true else {
                    throw ManualToolError(message: "Cannot compile the owned output fixture: loaded XCTest's Xcode has no macOS SDK at \(sdk.path).")
                }
                return (compiler: compiler, sdk: sdk)
            }
            container = container.deletingLastPathComponent()
        }
        throw ManualToolError(message: "Cannot compile the owned output fixture: loaded XCTest at \(framework.path) is not inside a validated Xcode application.")
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

/// Independent XZ Utils 5.8.4 containers use CRC32, CRC64 and SHA-256; offsets touch checks only.
func externalXZTestContainers() throws -> [(bytes: Data, checksumOffsets: [Int])] {
    let fixtures: [(String, [Int])] = [
        ("/Td6WFoAAAFpIt42AgAhARYAAAB0L+Wj4AB5AHNdABcVBQICabdDIjds/WOzp1ixRcD7TFRdPS0ZwDFMcA4FwTnRI3fSAOL+2qx+OqUGtwQX7lPbiQS9VHtuu22DeAqMG3F0vYV9Axpo9F34IhDxN+AlW3/6E21O6iWuBF7QoxznHwef6zv2rqvP2yvG5aIEwAAAAKcl8ZYAAYsBegAAAI5ZwI4+MA2LAgAAAAABWVo=", [8, 20, 148, 160, 164]),
        ("/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4AB5AHNdABcVBQICabdDIjds/WOzp1ixRcD7TFRdPS0ZwDFMcA4FwTnRI3fSAOL+2qx+OqUGtwQX7lPbiQS9VHtuu22DeAqMG3F0vYV9Axpo9F34IhDxN+AlW3/6E21O6iWuBF7QoxznHwef6zv2rqvP2yvG5aIEwAAAAOfstmkdJs1kAAGPAXoAAACYG1EVscRn+wIAAAAABFla", [8, 20, 148, 164, 168]),
        ("/Td6WFoAAArh+wyhAgAhARYAAAB0L+Wj4AB5AHNdABcVBQICabdDIjds/WOzp1ixRcD7TFRdPS0ZwDFMcA4FwTnRI3fSAOL+2qx+OqUGtwQX7lPbiQS9VHtuu22DeAqMG3F0vYV9Axpo9F34IhDxN+AlW3/6E21O6iWuBF7QoxznHwef6zv2rqvP2yvG5aIEwAAAADyLw4JjPxveUGKTmX1geKsVcfP3MMh11evqVPVuUjAvAAGnAXoAAADDnK7+tunfHAIAAAAAClla", [8, 20, 148, 188, 192])
    ]
    return try fixtures.map { (bytes: try XCTUnwrap(Data(base64Encoded: $0.0)), checksumOffsets: $0.1) }
}

func externalXZTestPlaintext() -> Data {
    Data(".TH XZFIXTURE 1\n.SH NAME\nxzfixture \\- independently encoded XZ manual\n.SH DESCRIPTION\nExternal container checksum marker.\n".utf8)
}

/// Use the real Apple stream encoder so CI needs no external compression tool or installed package.
func encodedXZTestData(bytes: Data) throws -> Data {
    try bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        let capacity = 65_536
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        // Empty input still supplies a valid non-null pointer with a zero byte count.
        let source = input.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(destination)
        var stream = compression_stream(dst_ptr: destination, dst_size: capacity,
                                        src_ptr: source, src_size: input.count, state: nil)
        let initialized = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZMA)
        guard initialized == COMPRESSION_STATUS_OK else {
            throw ManualToolError(message: "Cannot initialize the owned XZ test encoder (status \(initialized.rawValue)).")
        }
        stream.src_ptr = source
        stream.src_size = input.count
        let encoded: Data
        do {
            var output = Data()
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ManualToolError(message: "Owned XZ test encoding exceeded 30 seconds.") }
                let remaining = stream.src_size
                stream.dst_ptr = destination
                stream.dst_size = capacity
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw ManualToolError(message: "Owned XZ test encoding failed (status \(status.rawValue)).")
                }
                let produced = capacity - stream.dst_size
                output.append(destination, count: produced)
                if status == COMPRESSION_STATUS_END { break }
                guard stream.src_size < remaining || produced > 0 else { throw ManualToolError(message: "Owned XZ test encoder made no progress.") }
            }
            encoded = output
        } catch {
            let cleanup = compression_stream_destroy(&stream)
            guard cleanup == COMPRESSION_STATUS_OK else {
                throw ManualDecompressionCleanupError(cause: error, source: URL(fileURLWithPath: "/owned-xz-test-encoder"), status: cleanup.rawValue)
            }
            throw error
        }
        let cleanup = compression_stream_destroy(&stream)
        guard cleanup == COMPRESSION_STATUS_OK else {
            throw ManualDecompressionCleanupError(cause: nil, source: URL(fileURLWithPath: "/owned-xz-test-encoder"), status: cleanup.rawValue)
        }
        return encoded
    }
}
