import XCTest
import WebKit
import PDFKit
import SwiftUI
import Combine
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
        let aggregate = try XCTUnwrap(scan.pages.first { $0.name == "zshall" })
        XCTAssertNil(aggregate.problem)
        let aggregateLocation = try XCTUnwrap(aggregate.locations.first { $0.source == aggregate.source })
        let provenance = try XCTUnwrap(aggregateLocation.provenance)
        XCTAssertEqual(provenance.dependencies.count, 15, "Installed zshall must retain the root and all fourteen literal includes")
        let aggregateInput = try await manualInput(page: aggregate, access: ManualSourceAccess(generation: UUID(), allowedNetworkRoots: []))
        let aggregateHTML = try await manualHTML(input: aggregateInput)
        XCTAssertTrue(aggregateHTML.contains("INVOCATION"))
        XCTAssertTrue(aggregateHTML.contains("ARITHMETIC EVALUATION"))
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
    func testReaderReuseRequiresTheSameSourceAndCurrentAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderSourcePolicy-\(UUID().uuidString)")
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        for root in [first, second] {
            let section = root.appendingPathComponent("man1")
            try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"),
                                            to: section.appendingPathComponent("launchctl.1"))
        }
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in try await fixture.remove() }
        let scan = try await scanLibrary(roots: [first, second])
        let grouped = try XCTUnwrap(scan.pages.first)
        XCTAssertEqual(grouped.locations.count, 2)
        let firstPage = grouped.at(try XCTUnwrap(grouped.locations.first { $0.root == first }))
        let secondPage = grouped.at(try XCTUnwrap(grouped.locations.first { $0.root == second }))
        XCTAssertEqual(firstPage.id, secondPage.id)
        let authority = ManualSourceAuthority(selectedRoots: [])
        let reader = ManualReader(authority: authority)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader.webView
        defer { reader.webView.stopLoading(); window.close() }
        let context = BrowseContext(query: "launchctl", section: "1", root: nil, fullText: false)
        await reader.open(page: firstPage, context: context)
        try await waitForReader(reader, expectedPage: firstPage)
        _ = try await reader.webView.evaluateJavaScript("window.sourcePolicyIdentity='first'")
        await reader.open(page: secondPage, context: context)
        try await waitForReader(reader, expectedPage: secondPage)
        XCTAssertEqual(reader.page?.source, secondPage.source)
        let sourceReplaced = try await reader.webView.evaluateJavaScript("window.sourcePolicyIdentity === undefined") as? Bool
        XCTAssertEqual(sourceReplaced, true, "Equal content at a different source must be acquired under that location's policy")
        _ = try await reader.webView.evaluateJavaScript("window.sourcePolicyIdentity='second'")
        authority.replaceSelectedRoots([first])
        await reader.open(page: secondPage, context: context)
        try await waitForReader(reader, expectedPage: secondPage)
        let authorityReplaced = try await reader.webView.evaluateJavaScript("window.sourcePolicyIdentity === undefined") as? Bool
        XCTAssertEqual(authorityReplaced, true, "A changed source selection must invalidate document reuse")
        _ = try await reader.webView.evaluateJavaScript("window.sourcePolicyIdentity='current'")
        await reader.open(page: secondPage, context: context)
        let retained = try await reader.webView.evaluateJavaScript("window.sourcePolicyIdentity") as? String
        XCTAssertEqual(retained, "current", "An unchanged source and authority should retain the document")
        let narrowRoot = second.appendingPathComponent("man1")
        let wideResult = try await discoveredManual(file: secondPage.source, root: second,
            state: materializedFileState(secondPage.source), allowedNetworkRoots: [], exclusions: [],
            traversalRoots: [DiscoveryTraversalRoot(path: second.path, resolvedPath: second.resolvingSymlinksInPath().path)])
        let narrowResult = try await discoveredManual(file: secondPage.source, root: narrowRoot,
            state: materializedFileState(secondPage.source), allowedNetworkRoots: [], exclusions: [],
            traversalRoots: [DiscoveryTraversalRoot(path: narrowRoot.path, resolvedPath: narrowRoot.resolvingSymlinksInPath().path)])
        let wide = try XCTUnwrap(wideResult)
        let narrow = try XCTUnwrap(narrowResult)
        let scoped = try XCTUnwrap(groupedManuals([wide, narrow]).first)
        let wideLocation = try XCTUnwrap(scoped.locations.first { $0.root == second })
        let narrowLocation = try XCTUnwrap(scoped.locations.first { $0.root == narrowRoot })
        XCTAssertNotEqual(wideLocation.provenance?.scope, narrowLocation.provenance?.scope)
        let widePage = scoped.at(wideLocation)
        let narrowPage = scoped.at(narrowLocation)
        XCTAssertEqual(widePage.source, narrowPage.source)
        XCTAssertEqual(widePage.locations, narrowPage.locations)
        await reader.open(page: widePage, context: context)
        try await waitForReader(reader, expectedPage: widePage)
        _ = try await reader.webView.evaluateJavaScript("window.sourcePolicyIdentity='wider-scope'")
        await reader.open(page: narrowPage, context: context)
        try await waitForReader(reader, expectedPage: narrowPage)
        XCTAssertEqual(reader.page?.root, narrowRoot)
        let narrowerReplaced = try await reader.webView.evaluateJavaScript("window.sourcePolicyIdentity === undefined") as? Bool
        XCTAssertEqual(narrowerReplaced, true, "Choosing a narrower policy for the same source must reacquire that location")
    }

    @MainActor
    func testUnchangedSelectionsKeepTheirPinnedTargetsWhenOtherRootsChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PinnedSourceConsent-\(UUID().uuidString)").resolvingSymlinksInPath()
        let firstTarget = directory.appendingPathComponent("first-target")
        let secondTarget = directory.appendingPathComponent("second-target")
        let other = directory.appendingPathComponent("other")
        for root in [firstTarget, secondTarget, other] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in try await fixture.remove() }
        let selection = directory.appendingPathComponent("selected-alias")
        try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: firstTarget)
        let authority = ManualSourceAuthority(selectedRoots: [selection])
        let original = authority.snapshot()
        XCTAssertEqual(original.allowedNetworkRoots.map(\.path), [firstTarget.path])
        try FileManager.default.removeItem(at: selection)
        try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: secondTarget)
        authority.replaceSelectedRoots([selection.appendingPathComponent(".")])
        XCTAssertEqual(authority.snapshot().generation, original.generation)
        authority.replaceSelectedRoots([selection, other])
        XCTAssertEqual(authority.snapshot().allowedNetworkRoots.map(\.path), [firstTarget.path, other.path])
        XCTAssertThrowsError(try original.check())
        let expanded = authority.snapshot()
        authority.replaceSelectedRoots([selection])
        XCTAssertEqual(authority.snapshot().allowedNetworkRoots.map(\.path), [firstTarget.path])
        XCTAssertThrowsError(try expanded.check())
        authority.replaceSelectedRoots([])
        authority.replaceSelectedRoots([selection])
        XCTAssertEqual(authority.snapshot().allowedNetworkRoots.map(\.path), [secondTarget.path], "Only removing and explicitly adding the selection again may authorize its retargeted destination")
    }

    @MainActor
    func testReaderHistoryEnforcesPersistedScopeAfterASymlinkIsRetargeted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderHistoryScope-\(UUID().uuidString)")
        let selected = directory.appendingPathComponent("selected")
        let section = selected.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in try await fixture.remove() }
        let source = section.appendingPathComponent("launchctl.1")
        let outside = directory.appendingPathComponent("outside.1")
        for destination in [source, outside] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"), to: destination)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/ls.1"), to: section.appendingPathComponent("ls.1"))
        let alias = section.appendingPathComponent("alias.1")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let plan = DiscoveryPlan(roots: [selected], allowedNetworkRoots: [], exclusions: [],
                                 traversalExclusions: [], traversalRoots: [selected])
        let scan = try await discoverLibrary(plan: plan, previous: [], progress: { _ in })
        let inventory = directory.appendingPathComponent("inventory.json")
        try JSONEncoder().encode(scan).write(to: inventory)
        let reopened = try loadDiscovery(inventory)
        let grouped = try XCTUnwrap(reopened.pages.first { $0.locations.contains { $0.source == alias } })
        let aliased = grouped.at(try XCTUnwrap(grouped.locations.first { $0.source == alias }))
        let original = grouped.at(try XCTUnwrap(grouped.locations.first { $0.source == source }))
        let other = try XCTUnwrap(reopened.pages.first { $0.name == "ls" })
        let reader = ManualReader(authority: ManualSourceAuthority(selectedRoots: [selected]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader.webView
        defer { reader.webView.stopLoading(); window.close() }
        let context = BrowseContext(query: "alias", section: "1", root: nil, fullText: false)
        await reader.open(page: aliased, context: context)
        try await waitForReader(reader, expectedPage: original)
        await reader.open(page: other, context: context)
        try await waitForReader(reader, expectedPage: other)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let restored = await reader.back()
        XCTAssertEqual(restored, context)
        let deadline = Date().addingTimeInterval(10)
        while reader.loading && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(reader.loading)
        XCTAssertTrue(try XCTUnwrap(reader.errorMessage).contains("selected scan roots"))
        XCTAssertEqual(reader.page?.source, alias)
    }

    @MainActor
    func testCheckpointResumeUsesCurrentConsentAndRevokesAnEarlierSourceLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderConsentResume-\(UUID().uuidString)").resolvingSymlinksInPath()
        let selected = directory.appendingPathComponent("selected")
        let child = selected.appendingPathComponent("child")
        let section = child.appendingPathComponent("man1")
        try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in try await fixture.remove() }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"),
                                        to: section.appendingPathComponent("launchctl.1"))
        let plan = DiscoveryPlan(roots: [selected], allowedNetworkRoots: [selected], exclusions: [],
                                 traversalExclusions: [], traversalRoots: [selected])
        let checkpointFile = DiscoveryCheckpointFile(url: directory.appendingPathComponent("checkpoint.json"))
        let request = UUID()
        await checkpointFile.activate(request)
        let scan = try await continueDiscovery(checkpoint: newDiscoveryCheckpoint(plan: plan, title: "Source consent integration"),
            previous: [], progress: { _ in }, save: { try await checkpointFile.save($0, request: request) })
        let loaded = try await checkpointFile.load()
        let checkpoint = try XCTUnwrap(loaded)
        let page = try XCTUnwrap(scan.pages.first)
        let authority = ManualSourceAuthority(selectedRoots: [child])
        let earlier = authority.snapshot()
        let narrowed = try reauthorizedDiscoveryCheckpoint(checkpoint, access: earlier)
        XCTAssertEqual(narrowed.plan.allowedNetworkRoots.map(\.path), [child.path])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(narrowed.roots), try encoder.encode(checkpoint.roots))
        XCTAssertEqual(try encoder.encode(narrowed.pages), try encoder.encode(checkpoint.pages))
        XCTAssertEqual(narrowed.visited, checkpoint.visited)
        XCTAssertEqual(narrowed.visitedRootIndices, checkpoint.visitedRootIndices)
        XCTAssertEqual(narrowed.updated, checkpoint.updated)
        XCTAssertEqual(narrowed.bootReference, checkpoint.bootReference)
        XCTAssertEqual(narrowed.plan.traversalRoots, checkpoint.plan.traversalRoots)
        authority.replaceSelectedRoots([selected])
        let stillNarrowed = try reauthorizedDiscoveryCheckpoint(narrowed, access: authority.snapshot())
        XCTAssertEqual(stillNarrowed.plan.allowedNetworkRoots.map(\.path), [child.path], "A broader current selection must preserve the saved narrower restriction")
        do {
            _ = try await manualInput(page: page, access: earlier)
            XCTFail("Revoked consent must stop a fresh read even for a retained local inventory entry")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Source selections changed")) }
        let input = try await manualInput(page: page, access: authority.snapshot())
        XCTAssertEqual(manualContentDigest(input.bytes), page.fingerprint)
        authority.replaceSelectedRoots([])
        XCTAssertTrue(try reauthorizedDiscoveryCheckpoint(checkpoint, access: authority.snapshot()).plan.allowedNetworkRoots.isEmpty)
        authority.replaceSelectedRoots([directory.appendingPathComponent("unrelated")])
        XCTAssertTrue(try reauthorizedDiscoveryCheckpoint(checkpoint, access: authority.snapshot()).plan.allowedNetworkRoots.isEmpty)
    }

    @MainActor
    private func readerPage(name: String, section: String) async throws -> ManualPage {
        let root = URL(fileURLWithPath: "/usr/share/man")
        let source = root.appendingPathComponent("man\(section)/\(name).\(section)")
        let page = try await discoveredManual(file: source, root: root, state: materializedFileState(source), allowedNetworkRoots: [], exclusions: [])
        return try XCTUnwrap(page, "The installed manual must have a verified content identity")
    }

    @MainActor
    func testRecordedCatalogIssueReflectsLateIndexingAndPreservesSelectedSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogIssue-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let suite = "CatalogIssue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = LibraryFixtureCleanup(directory: directory)
        addTeardownBlock { () async throws -> Void in
            try XCTUnwrap(UserDefaults(suiteName: suite)).removePersistentDomain(forName: suite)
            do { try await fixture.remove() }
            catch { XCTFail("Cannot clean owned catalog-issue integration files: \(error)") }
        }
        let first = directory.appendingPathComponent("a/man5")
        let second = directory.appendingPathComponent("b/man5")
        let clean = directory.appendingPathComponent("clean/man1")
        for section in [first, second, clean] {
            try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        }
        let sourceA = first.appendingPathComponent("sudoers.5")
        let sourceB = second.appendingPathComponent("sudoers.5")
        for source in [sourceA, sourceB] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man5/sudoers.5"), to: source)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/share/man/man1/launchctl.1"),
                                        to: clean.appendingPathComponent("launchctl.1"))
        let scan = try await scanLibrary(roots: [first, second, clean])
        XCTAssertEqual(scan.pages.count, 2)
        let grouped = try XCTUnwrap(scan.pages.first { $0.name == "sudoers" })
        XCTAssertEqual(grouped.source, sourceA)
        XCTAssertEqual(Set(grouped.locations.map(\.source)), Set([sourceA, sourceB]))
        XCTAssertTrue(scan.pages.allSatisfy { !$0.indexed && $0.problem == nil })
        let output = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try JSONEncoder().encode(scan).write(to: output.appendingPathComponent("discovery-v1.json"), options: .atomic)
        let selected = grouped.at(try XCTUnwrap(grouped.locations.first { $0.source == sourceB }))
        try await verifyRecordedCatalogIssue(directory: output, defaults: defaults, fixture: fixture,
                                             scan: scan, selected: selected)
    }

    @MainActor
    private func verifyRecordedCatalogIssue(directory: URL, defaults: UserDefaults, fixture: LibraryFixtureCleanup,
                                            scan: LibraryScan, selected: ManualPage) async throws {
        let sourceA = try XCTUnwrap(scan.pages.first { $0.id == selected.id }).source
        let sourceB = selected.source
        let cleanPage = try XCTUnwrap(scan.pages.first { $0.name == "launchctl" })
        let library = LibraryStore(directory: directory, defaults: defaults)
        fixture.track(library)
        library.openLibrary()
        let openDeadline = ProcessInfo.processInfo.systemUptime + 10
        while library.pages.count != scan.pages.count && ProcessInfo.processInfo.systemUptime < openDeadline {
            if let error = library.errorMessage { throw ManualToolError(message: error) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Set(library.pages.map(\.id)), Set(scan.pages.map(\.id)))
        XCTAssertFalse(library.isIndexing)
        let reader = ManualReader(authority: library.sourceAuthority)
        await reader.open(page: selected, context: BrowseContext(query: "sudoers", section: "5", root: nil, fullText: false))
        let readerDeadline = ProcessInfo.processInfo.systemUptime + 10
        while reader.loading && ProcessInfo.processInfo.systemUptime < readerDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(reader.loading)
        let readerError = try XCTUnwrap(reader.errorMessage)
        XCTAssertTrue(readerError.contains("exit 4"), readerError)
        XCTAssertEqual(reader.page?.source, sourceB)
        XCTAssertNil(reader.page?.problem)
        var loadingTransitions: [Bool] = []
        let loadingObservation = reader.$loading.dropFirst().sink { loadingTransitions.append($0) }
        defer { loadingObservation.cancel() }
        let host = NSHostingView(rootView: ManualCatalogIssueView(manualID: selected.id).environmentObject(library))
        let windowIdentifier = "manualCatalogIssueTestWindow"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier(windowIdentifier)
        window.contentView = host
        window.orderBack(nil)
        defer {
            reader.webView.stopLoading()
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await waitForAccessibilityWindow(windowIdentifier: windowIdentifier,
                                             deadline: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertFalse(try accessibilityIdentifiers(windowIdentifier: windowIdentifier).contains("manualCatalogIssue"))
        library.continueIndexing()
        let indexingDeadline = ProcessInfo.processInfo.systemUptime + 15
        while library.isIndexing && ProcessInfo.processInfo.systemUptime < indexingDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(library.isIndexing)
        XCTAssertNil(library.errorMessage)
        let indexedGroup = try XCTUnwrap(library.problemPages.first { $0.id == selected.id })
        let problem = try XCTUnwrap(indexedGroup.problem)
        XCTAssertFalse(indexedGroup.indexed, "Unsupported formatter output must not become verified full text")
        XCTAssertTrue(problem.contains(sourceA.path), problem)
        XCTAssertTrue(problem.contains("exit 4"), problem)
        let renderDeadline = ProcessInfo.processInfo.systemUptime + 5
        var displayedProblem: String?
        while ProcessInfo.processInfo.systemUptime < renderDeadline {
            host.layoutSubtreeIfNeeded()
            if try accessibilityIdentifiers(windowIdentifier: windowIdentifier).contains("manualCatalogIssueText") {
                displayedProblem = try accessibilityTextValue(windowIdentifier: windowIdentifier, controlIdentifier: "manualCatalogIssueText")
                if displayedProblem == problem { break }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(displayedProblem, problem)
        XCTAssertEqual(reader.page?.source, sourceB)
        XCTAssertNil(reader.page?.problem, "The mounted view must read current catalog metadata rather than this historical reader snapshot")
        XCTAssertEqual(reader.errorMessage, readerError)
        XCTAssertTrue(loadingTransitions.isEmpty, "Publishing catalog diagnostics must not reload the selected reader")
        XCTAssertNil(library.pages.first { $0.id == cleanPage.id }?.problem)
        host.rootView = ManualCatalogIssueView(manualID: cleanPage.id).environmentObject(library)
        let cleanDeadline = ProcessInfo.processInfo.systemUptime + 5
        while try accessibilityIdentifiers(windowIdentifier: windowIdentifier).contains("manualCatalogIssue") &&
            ProcessInfo.processInfo.systemUptime < cleanDeadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cleanIdentifiers = try accessibilityIdentifiers(windowIdentifier: windowIdentifier)
        XCTAssertFalse(cleanIdentifiers.contains("manualCatalogIssue"))
        XCTAssertFalse(cleanIdentifiers.contains("manualCatalogIssueText"))
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
