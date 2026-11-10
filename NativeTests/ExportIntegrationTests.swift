import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Man_Page_Catalog

@MainActor
final class ExportIntegrationTests: XCTestCase {
    func testExportSheetOwnershipCancellationAndIndependentWindow() async throws {
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let independent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        independent.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 250, height: 24))
        field.setAccessibilityIdentifier("independentExportTestField")
        independent.contentView = field
        owner.orderFront(nil)
        independent.orderFront(nil)
        let completed = expectation(description: "Native export cancellation completed")
        var didComplete: Bool = false
        let selection = Task { @MainActor in
            defer { didComplete = true; completed.fulfill() }
            return try await chooseExportDestination(window: owner, filename: "cancelled-manual.pdf", contentType: .pdf, title: "Export Manual as PDF", identifier: "testExportPanel")
        }
        defer {
            if let sheet = owner.attachedSheet { owner.endSheet(sheet, returnCode: .cancel) }
            selection.cancel()
            independent.close()
            owner.close()
        }
        for _ in 0..<250 where owner.attachedSheet == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let panel = try XCTUnwrap(owner.attachedSheet as? NSSavePanel, "Export did not attach to the supplied window within five seconds")
        XCTAssertTrue(panel.sheetParent === owner)
        XCTAssertEqual(panel.identifier?.rawValue, "testExportPanel")
        XCTAssertNil(independent.attachedSheet)
        XCTAssertNil(NSApplication.shared.modalWindow, "An export sheet must not create application-modal state")
        independent.makeKeyAndOrderFront(nil)
        XCTAssertTrue(independent.makeFirstResponder(field), "An unrelated window must remain interactive")
        XCTAssertTrue(independent.firstResponder === field.currentEditor())
        do {
            _ = try await chooseExportDestination(window: owner, filename: "second.json", contentType: .json, title: "Export Coverage", identifier: "secondExportPanel")
            XCTFail("An existing sheet must prevent a competing export")
        } catch let error as ManualToolError {
            XCTAssertTrue(error.message.contains("already has an open dialog"))
        }
        panel.cancel(nil)
        await fulfillment(of: [completed], timeout: 5)
        guard didComplete else { throw ManualToolError(message: "The native export sheet did not complete cancellation within five seconds.") }
        let destination = try await selection.value
        XCTAssertNil(destination)
        for _ in 0..<250 where owner.attachedSheet != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(owner.attachedSheet)
        let jsonCompleted = expectation(description: "Repeated native JSON export cancelled")
        var didCancelJSON: Bool = false
        let jsonSelection = Task { @MainActor in
            defer { didCancelJSON = true; jsonCompleted.fulfill() }
            return try await chooseExportDestination(window: owner, filename: "coverage.json", contentType: .json,
                title: "Export Scan Coverage", identifier: "testCoveragePanel")
        }
        defer { jsonSelection.cancel() }
        for _ in 0..<250 where owner.attachedSheet == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let jsonPanel = try XCTUnwrap(owner.attachedSheet as? NSSavePanel)
        XCTAssertTrue(jsonPanel.sheetParent === owner)
        XCTAssertEqual(jsonPanel.allowedContentTypes, [.json])
        XCTAssertFalse(jsonPanel.allowsOtherFileTypes)
        jsonPanel.cancel(nil)
        await fulfillment(of: [jsonCompleted], timeout: 5)
        guard didCancelJSON else { throw ManualToolError(message: "Native JSON export did not cancel within five seconds.") }
        let jsonDestination = try await jsonSelection.value
        XCTAssertNil(jsonDestination)
        for _ in 0..<250 where owner.attachedSheet != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(owner.attachedSheet)
    }
}
