import XCTest
import PDFKit
@testable import Man_Page_Catalog

final class CatalogIntegrationTests: XCTestCase {
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
