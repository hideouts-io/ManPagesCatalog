import XCTest
import WebKit
import PDFKit
@testable import Man_Page_Catalog

final class NativeBrowserIntegrationTests: XCTestCase {
    func testDiscoveryAliasesCompressionAndFTSSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeManuals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot clean test collection: \(error)") }
        }
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        for root in [first, second] {
            let section = root.appendingPathComponent("man1")
            try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: section.appendingPathComponent("launchctl.1"))
        }
        let section = first.appendingPathComponent("man1")
        let compressed = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c", section.appendingPathComponent("launchctl.1").path], directory: directory, input: nil)
        try compressed.write(to: section.appendingPathComponent("compressed.1.gz"))
        let alias = section.appendingPathComponent("alias.1")
        try ".so man1/compressed.1\n".write(to: alias, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: section.appendingPathComponent("symlink.1"), withDestinationURL: section.appendingPathComponent("launchctl.1"))
        let scan = try scanLibrary(roots: [first, second, directory.appendingPathComponent("missing")])
        XCTAssertEqual(scan.pages.count, 5)
        XCTAssertEqual(scan.pages.filter { $0.name == "launchctl" }.count, 2)
        XCTAssertEqual(scan.coverage.last?.problems.count, 1)
        let description = try await manualDescription(source: alias)
        XCTAssertEqual(description, "Interfaces with launchd")
        let html = try await manualHTML(source: alias)
        XCTAssertTrue(html.contains("manpagescatalog://open?name="))
        XCTAssertTrue(html.contains("SUBCOMMANDS"))
        let pdf = directory.appendingPathComponent("export.pdf")
        try await renderManual(source: alias, destination: pdf)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: pdf)?.string).contains("bootstrap"))
        let index = try ManualSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        var page = try XCTUnwrap(scan.pages.first { $0.name == "alias" })
        let text = try await manualText(source: alias)
        try await index.store(page: page, text: text, description: description, diagnostic: "")
        page.indexed = true
        page.description = description
        let matches = try await index.matchingIDs(query: "bootstrap")
        XCTAssertEqual(matches, [page.id])
        XCTAssertEqual(rankedManuals(pages: [page], query: "bootstrap", section: nil, root: nil, fullText: matches).first?.reason, "Full text")
        XCTAssertTrue(rankedManuals(pages: [page], query: "bootstrap", section: "8", root: nil, fullText: matches).isEmpty)
        XCTAssertEqual(rankedManuals(pages: scan.pages, query: "launchct", section: nil, root: nil, fullText: []).count, 2)
        let reopened = try ManualSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let cached = try await reopened.metadata()
        XCTAssertEqual(cached.first?.description, description)
        try ".so man1/alias.1\n".write(to: alias, atomically: true, encoding: .utf8)
        do { _ = try await manualDescription(source: alias); XCTFail("Alias cycle must fail explicitly") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cycle")) }
        let badIndex = directory.appendingPathComponent("invalid.sqlite")
        try Data("not a database".utf8).write(to: badIndex)
        XCTAssertThrowsError(try ManualSearchIndex(url: badIndex))
    }

    @MainActor
    func testHTMLReadingFindSelectionAndHistory() async throws {
        let scan = try scanLibrary(roots: [URL(fileURLWithPath: "/usr/share/man")])
        let launchctl = try XCTUnwrap(scan.pages.first { $0.name == "launchctl" && $0.section == "1" })
        let ping = try XCTUnwrap(scan.pages.first { $0.name == "ping" && $0.section == "8" })
        let reader = ManualReader()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader.webView
        let context = BrowseContext(query: "launchctl", section: nil, root: nil, fullText: false)
        await reader.open(page: launchctl, context: context)
        try await waitForReader(reader)
        XCTAssertTrue(reader.headings.contains { $0.title == "SUBCOMMANDS" })
        reader.findQuery = "bootstrap"
        reader.findNext()
        for _ in 0..<200 where reader.findStatus.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(reader.findStatus, "Match found")
        reader.findPrevious()
        reader.webView.pageZoom = 1.2
        _ = try await reader.webView.evaluateJavaScript("window.scrollTo(0,600); window.testDocumentIdentity='retained'; const range=document.createRange(); range.selectNodeContents(document.querySelector('h2')); window.getSelection().removeAllRanges(); window.getSelection().addRange(range);")
        let selection = try await reader.webView.evaluateJavaScript("window.getSelection().toString()") as? String
        await reader.open(page: launchctl, context: BrowseContext(query: "network", section: "8", root: nil, fullText: false))
        let identity = try await reader.webView.evaluateJavaScript("window.testDocumentIdentity") as? String
        XCTAssertEqual(identity, "retained")
        let preservedSelection = try await reader.webView.evaluateJavaScript("window.getSelection().toString()") as? String
        XCTAssertEqual(preservedSelection, selection)
        XCTAssertEqual(reader.webView.pageZoom, 1.2)
        _ = try await reader.webView.evaluateJavaScript("window.scrollTo(0,600)")
        let beforeValue = try await reader.webView.evaluateJavaScript("window.scrollY") as? Double
        let before = try XCTUnwrap(beforeValue)
        await reader.open(page: ping, context: BrowseContext(query: "ping", section: "8", root: nil, fullText: false))
        try await waitForReader(reader)
        XCTAssertEqual(reader.page?.name, "ping")
        let restored = await reader.back()
        try await waitForReader(reader)
        XCTAssertEqual(restored, context)
        XCTAssertEqual(reader.page?.name, "launchctl")
        XCTAssertEqual(reader.webView.pageZoom, 1.2)
        let afterValue = try await reader.webView.evaluateJavaScript("window.scrollY") as? Double
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(before, after, accuracy: 1)
        XCTAssertEqual(reader.findQuery, "bootstrap")
        XCTAssertTrue(reader.canForward)
        window.close()
    }

    @MainActor
    func testLibraryRefreshCancellationAndSearchWithRealSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryIntegration-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("manuals")
        let section = root.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        let source = section.appendingPathComponent("launchctl.1")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: source)
        let suite = "LibraryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot clean library test: \(error)") }
        }
        let library = LibraryStore(directory: directory.appendingPathComponent("index"), defaults: defaults)
        library.addRoot(root)
        library.stop()
        library.scan()
        for _ in 0..<500 where library.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(library.isIndexing)
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.pages.count, 1)
        XCTAssertEqual(library.pages.first?.description, "Interfaces with launchd")
        library.query = "nonexistent"
        library.query = "launchctl"
        let submitted = await library.firstResultForCurrentSearch()
        XCTAssertEqual(submitted?.name, "launchctl")
        XCTAssertEqual(library.results.first?.page.name, "launchctl")
        library.section = "8"
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(library.results.isEmpty)
        library.searchAll()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(library.results.count, 1)
        library.scan()
        for _ in 0..<500 where library.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(library.indexedCount, 1)
        try FileManager.default.removeItem(at: source)
        library.scan()
        for _ in 0..<500 where library.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(library.pages.isEmpty)
        XCTAssertNil(library.errorMessage)
    }

    @MainActor
    private func waitForReader(_ reader: ManualReader) async throws {
        for _ in 0..<500 where reader.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(reader.loading, "Reader did not finish within ten seconds")
        XCTAssertNil(reader.errorMessage)
    }
}
