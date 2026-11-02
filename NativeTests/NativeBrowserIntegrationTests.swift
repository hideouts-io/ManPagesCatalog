import XCTest
import WebKit
import PDFKit
@testable import Man_Page_Catalog

final class NativeBrowserIntegrationTests: XCTestCase {
    func testDiscoveryAliasesCompressionAndFTSSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeManuals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = await LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            do { try await fixture.remove() }
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
        let scan = try await scanLibrary(roots: [first, second, directory.appendingPathComponent("missing")])
        XCTAssertEqual(scan.pages.count, 1)
        XCTAssertEqual(scan.pages.first?.locations.count, 5)
        XCTAssertEqual(scan.pages.flatMap(\.locations).filter { $0.name == "launchctl" }.count, 2)
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
        var page = try XCTUnwrap(scan.pages.first)
        let text = try await manualText(source: alias)
        try await index.store(page: page, text: text, description: description, diagnostic: "")
        page.indexed = true
        page.description = description
        let matches = try await index.matchingIDs(query: "bootstrap")
        XCTAssertEqual(matches, [page.id])
        XCTAssertEqual(rankedManuals(pages: [page], query: "bootstrap", section: nil, root: nil, fullText: matches).first?.reason, "Full text")
        XCTAssertTrue(rankedManuals(pages: [page], query: "bootstrap", section: "8", root: nil, fullText: matches).isEmpty)
        XCTAssertEqual(rankedManuals(pages: scan.pages, query: "launchct", section: nil, root: nil, fullText: []).count, 1)
        let reopened = try ManualSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let cached = try await reopened.metadata()
        XCTAssertEqual(cached.first?.description, description)
        let legacy = directory.appendingPathComponent("retained-v3.sqlite")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("index.sqlite"), to: legacy)
        _ = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                                    arguments: [legacy.path, "DROP TABLE manuals_rowids_v1;"], directory: directory, input: nil)
        let migrated = try ManualSearchIndex(url: legacy)
        let migratedMetadata = try await migrated.metadata()
        XCTAssertEqual(migratedMetadata.count, 1)
        XCTAssertEqual(migratedMetadata.first?.id, page.id)
        try await migrated.store(page: page, text: text, description: description, diagnostic: "")
        let replacedMetadata = try await migrated.metadata()
        let retainedMatches = try await migrated.matchingIDs(query: "bootstrap")
        XCTAssertEqual(replacedMetadata.count, 1)
        XCTAssertEqual(retainedMatches, [page.id])
        try ".so man1/alias.1\n".write(to: alias, atomically: true, encoding: .utf8)
        do { _ = try await manualDescription(source: alias); XCTFail("Alias cycle must fail explicitly") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cycle")) }
        let badIndex = directory.appendingPathComponent("invalid.sqlite")
        try Data("not a database".utf8).write(to: badIndex)
        XCTAssertThrowsError(try ManualSearchIndex(url: badIndex))
    }

    @MainActor
    func testHTMLReadingFindSelectionAndHistory() async throws {
        let scan = try await scanLibrary(roots: [URL(fileURLWithPath: "/usr/share/man")])
        let launchctl = try XCTUnwrap(scan.pages.first { $0.name == "launchctl" && $0.section == "1" })
        let ping = try XCTUnwrap(scan.pages.first { $0.name == "ping" && $0.section == "8" })
        let names = Set(scan.pages.flatMap(\.locations).map(\.name))
        for name in ["bzdiff", "ruby", "kswitch", "usdcat", "MetalPerformanceHUD"] {
            if FileManager.default.fileExists(atPath: "/usr/share/man/man1/\(name).1") { XCTAssertTrue(names.contains(name), "Installed manual rejected: \(name)") }
        }
        if FileManager.default.fileExists(atPath: "/usr/share/man/mann/iwidgets_buttonbox.n") { XCTAssertTrue(names.contains("iwidgets_buttonbox")) }
        XCTAssertTrue(names.contains("zshall"))
        XCTAssertNotNil(scan.pages.first { $0.name == "zshall" }?.problem)
        let reader = ManualReader()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader.webView
        let context = BrowseContext(query: "launchctl", section: nil, root: nil, fullText: false)
        await reader.open(page: launchctl, context: context)
        try await waitForReader(reader, expectedPage: launchctl)
        XCTAssertTrue(reader.headings.contains { $0.title == "SUBCOMMANDS" })
        reader.findQuery = "bootstrap"
        reader.findNext()
        for _ in 0..<200 where reader.findStatus.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(reader.findStatus, "Match found")
        reader.findPrevious()
        reader.webView.pageZoom = 1.2
        _ = try await reader.webView.evaluateJavaScript("window.scrollTo(0,600); window.testDocumentIdentity='retained'; const range=document.createRange(); range.selectNodeContents(document.getElementById('NAME')); window.getSelection().removeAllRanges(); window.getSelection().addRange(range);")
        let selection = try await reader.webView.evaluateJavaScript("window.getSelection().toString()") as? String
        XCTAssertEqual(selection, "NAME")
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
        try await waitForReader(reader, expectedPage: ping)
        XCTAssertEqual(reader.page?.name, "ping")
        let restored = await reader.back()
        try await waitForReader(reader, expectedPage: launchctl)
        XCTAssertEqual(restored, context)
        XCTAssertEqual(reader.page?.name, "launchctl")
        XCTAssertEqual(reader.webView.pageZoom, 1.2)
        let afterValue = try await reader.webView.evaluateJavaScript("window.scrollY") as? Double
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(before, after, accuracy: 1)
        XCTAssertEqual(reader.findQuery, "bootstrap")
        XCTAssertTrue(reader.canForward)
        reader.findNext()
        await reader.open(page: ping, context: BrowseContext(query: "ping", section: "8", root: nil, fullText: false))
        try await waitForReader(reader, expectedPage: ping)
        XCTAssertEqual(reader.page?.id, ping.id)
        XCTAssertEqual(reader.findQuery, "")
        for _ in 0..<200 where reader.pendingFindCallbacks > 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(reader.pendingFindCallbacks, 0, "WebKit Find callbacks did not drain within four seconds")
        XCTAssertEqual(reader.findStatus, "", "A Find completion from launchctl must not update the new document's empty Find state")
        window.close()
    }

    @MainActor
    func testPendingReaderOpenCannotReplaceReusedCurrentDocument() async throws {
        let launchctl = try await readerPage(name: "launchctl", section: "1")
        let ping = try await readerPage(name: "ping", section: "8")
        let context = BrowseContext(query: "launchctl", section: "1", root: nil, fullText: false)
        let reader = ManualReader()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader.webView
        defer {
            reader.onReaderPositionRead = nil
            reader.webView.stopLoading()
            window.close()
        }
        await reader.open(page: launchctl, context: context)
        try await waitForReader(reader, expectedPage: launchctl)
        reader.findQuery = "bootstrap"
        reader.webView.pageZoom = 1.2
        _ = try await reader.webView.evaluateJavaScript("window.scrollTo(0,600); window.navigationIdentity='retained'; const range=document.createRange(); range.selectNodeContents(document.getElementById('NAME')); window.getSelection().removeAllRanges(); window.getSelection().addRange(range);")
        let selection = try await reader.webView.evaluateJavaScript("window.getSelection().toString()") as? String
        let scroll = try await reader.webView.evaluateJavaScript("window.scrollY") as? Double
        var reusedAtPositionRead = false
        reader.onReaderPositionRead = {
            reader.onReaderPositionRead = nil
            reusedAtPositionRead = true
            await reader.open(page: launchctl, context: context)
        }
        await reader.open(page: ping, context: BrowseContext(query: "ping", section: "8", root: nil, fullText: false))
        XCTAssertTrue(reusedAtPositionRead, "The newer activation must occur after a real WebKit position read")
        guard reader.page?.id == launchctl.id, !reader.loading else {
            XCTFail("The older pending activation replaced the more recently reused manual")
            return
        }
        XCTAssertFalse(reader.canBack, "A superseded activation must not add a history entry")
        XCTAssertFalse(reader.canForward)
        XCTAssertEqual(reader.findQuery, "bootstrap")
        XCTAssertEqual(reader.webView.pageZoom, 1.2)
        let identity = try await reader.webView.evaluateJavaScript("window.navigationIdentity") as? String
        let retainedSelection = try await reader.webView.evaluateJavaScript("window.getSelection().toString()") as? String
        let retainedScroll = try await reader.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(identity, "retained")
        XCTAssertEqual(retainedSelection, selection)
        XCTAssertEqual(retainedScroll, scroll)
        reader.onReaderPositionRead = {
            reader.onReaderPositionRead = nil
            reader.retry()
        }
        await reader.open(page: ping, context: BrowseContext(query: "ping", section: "8", root: nil, fullText: false))
        guard reader.page?.id == launchctl.id else {
            XCTFail("A newer Retry must supersede an older pending activation")
            return
        }
        try await waitForReader(reader, expectedPage: launchctl)
        XCTAssertFalse(reader.canBack)
        XCTAssertFalse(reader.canForward)
        XCTAssertEqual(reader.findQuery, "bootstrap")
        XCTAssertEqual(reader.webView.pageZoom, 1.2)
    }

    @MainActor
    func testOverlappingReaderHistoryRetainsLatestNavigation() async throws {
        let launchctl = try await readerPage(name: "launchctl", section: "1")
        let ping = try await readerPage(name: "ping", section: "8")
        let ifconfig = try await readerPage(name: "ifconfig", section: "8")
        let first = BrowseContext(query: "launchctl", section: "1", root: nil, fullText: false)
        let second = BrowseContext(query: "ping", section: "8", root: nil, fullText: true)
        let third = BrowseContext(query: "ifconfig", section: nil, root: nil, fullText: false)
        let reader = ManualReader()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader.webView
        defer {
            reader.onReaderPositionRead = nil
            reader.webView.stopLoading()
            window.close()
        }
        await reader.open(page: launchctl, context: first)
        try await waitForReader(reader, expectedPage: launchctl)
        await reader.open(page: ping, context: second)
        try await waitForReader(reader, expectedPage: ping)
        reader.findQuery = "packet"
        reader.webView.pageZoom = 1.2
        _ = try await reader.webView.evaluateJavaScript("window.scrollTo(0,500)")
        let pingScrollValue = try await reader.webView.evaluateJavaScript("window.scrollY") as? Double
        let pingScroll = try XCTUnwrap(pingScrollValue)
        await reader.open(page: ifconfig, context: third)
        try await waitForReader(reader, expectedPage: ifconfig)
        var newerBack: BrowseContext?
        reader.onReaderPositionRead = {
            reader.onReaderPositionRead = nil
            newerBack = await reader.back()
        }
        let olderBack = await reader.back()
        guard olderBack == nil, newerBack == second else {
            XCTFail("Overlapping Back actions must consume only the latest navigation's history entry")
            return
        }
        try await waitForReader(reader, expectedPage: ping)
        XCTAssertTrue(reader.canBack, "The first manual must remain reachable after one accepted Back")
        XCTAssertTrue(reader.canForward)
        XCTAssertEqual(reader.findQuery, "packet")
        XCTAssertEqual(reader.webView.pageZoom, 1.2)
        let restoredScrollValue = try await reader.webView.evaluateJavaScript("window.scrollY") as? Double
        let restoredScroll = try XCTUnwrap(restoredScrollValue)
        XCTAssertEqual(restoredScroll, pingScroll, accuracy: 1)
        let restoredFirst = await reader.back()
        XCTAssertEqual(restoredFirst, first)
        try await waitForReader(reader, expectedPage: launchctl)
        XCTAssertFalse(reader.canBack)
        var newerForward: BrowseContext?
        reader.onReaderPositionRead = {
            reader.onReaderPositionRead = nil
            newerForward = await reader.forward()
        }
        let olderForward = await reader.forward()
        guard olderForward == nil, newerForward == second else {
            XCTFail("Overlapping Forward actions must consume only the latest navigation's history entry")
            return
        }
        try await waitForReader(reader, expectedPage: ping)
        XCTAssertTrue(reader.canForward, "The third manual must remain reachable after one accepted Forward")
        let restoredThird = await reader.forward()
        XCTAssertEqual(restoredThird, third)
        try await waitForReader(reader, expectedPage: ifconfig)
        XCTAssertFalse(reader.canForward)
    }

    @MainActor
    private func readerPage(name: String, section: String) async throws -> ManualPage {
        let root = URL(fileURLWithPath: "/usr/share/man")
        let source = root.appendingPathComponent("man\(section)/\(name).\(section)")
        let page = try await discoveredManual(file: source, root: root, state: materializedFileState(source), allowedNetworkRoots: [], exclusions: [])
        return try XCTUnwrap(page, "The installed manual must have a verified content identity")
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
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            try XCTUnwrap(UserDefaults(suiteName: suite)).removePersistentDomain(forName: suite)
            do { try await fixture.remove() }
            catch { XCTFail("Cannot clean library test: \(error)") }
        }
        let library = LibraryStore(directory: directory.appendingPathComponent("index"), defaults: defaults)
        fixture.track(library)
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
    private func waitForReader(_ reader: ManualReader, expectedPage: ManualPage) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let message = reader.errorMessage { throw ManualToolError(message: message) }
            if !reader.loading && !reader.webView.isLoading {
                let value = try await reader.webView.callAsyncJavaScript(
                    "return document.readyState === 'complete' && document.getElementById('NAME') !== null && document.querySelector('.head-ltitle')?.textContent.trim().toLowerCase() === expectedTitle.toLowerCase();",
                    arguments: ["expectedTitle": expectedPage.title], in: nil, contentWorld: .page) as? Bool
                let ready = try XCTUnwrap(value, "WebKit returned an invalid document-readiness result")
                if ready {
                    XCTAssertEqual(reader.page?.id, expectedPage.id)
                    XCTAssertEqual(reader.webView.url?.absoluteString, "about:blank")
                    XCTAssertFalse(reader.loading)
                    XCTAssertNil(reader.errorMessage)
                    return
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ManualToolError(message: "Reader did not load \(expectedPage.title) with its NAME heading within ten seconds.")
    }
}
