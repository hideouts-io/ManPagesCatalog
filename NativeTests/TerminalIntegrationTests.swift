import XCTest
import SwiftTerm
import SwiftUI
import Darwin
@testable import Man_Page_Catalog

@MainActor
final class TerminalIntegrationTests: XCTestCase {
    func testWorkspaceDisplaysTheNewSessionAfterAnEarlierRun() async throws {
        let session = TerminalSession()
        let host = NSHostingView(rootView: TerminalPane(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { session.shutdown(); window.close() }
        session.prepare(text: "printf 'FIRST_SESSION\\n'", source: nil)
        session.reviewed = true
        try session.runDraft()
        try await waitForExit(session)
        let first = try XCTUnwrap(session.view)
        for _ in 0..<100 where !first.isDescendant(of: host) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(first.isDescendant(of: host))
        try session.startShell()
        let second = try XCTUnwrap(session.view)
        for _ in 0..<100 where !second.isDescendant(of: host) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(second.isDescendant(of: host), "The visible terminal must connect to the new PTY")
        XCTAssertFalse(first.isDescendant(of: host))
        send("printf 'SECOND_SESSION\\n'; exit\r", session: session)
        try await waitForExit(session)
        try await waitForOutput("SECOND_SESSION", session: session)
        XCTAssertFalse(output(session).contains("FIRST_SESSION"))
    }

    func testPrepareReviewMultilineQuotingAndExplicitRun() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let marker = directory.appendingPathComponent("prepared but not run.txt")
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(directory)
        let command = "printf '%s\\n' 'two words' > \(quotedShellWord(marker.path))\nprintf '%s\\n' 'café ✓'\npwd"
        session.prepare(text: command, source: DraftSource(title: "printf(1)", path: "/usr/share/man/man1/printf.1", executable: "/usr/bin/printf"))
        XCTAssertNil(session.process)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try session.runDraft())
        session.reviewed = true
        try session.runDraft()
        try await waitForExit(session)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "two words\n")
        try await waitForOutput("café ✓", session: session)
        let terminal = try XCTUnwrap(session.view)
        terminal.selectAll()
        XCTAssertTrue(terminal.getSelection()?.contains("café ✓") == true)
        XCTAssertTrue((terminal.accessibilityValue() as? String)?.contains("café ✓") == true)
        XCTAssertTrue(output(session).contains(directory.path))
        XCTAssertEqual(session.status, "Session ended • exit 0")
        session.prepare(text: "printf '%s' {{value}}", source: nil)
        session.reviewed = true
        XCTAssertThrowsError(try session.runDraft())
        session.draftText = "printf '%s' <value>"
        XCTAssertFalse(session.reviewed)
        XCTAssertNotNil(session.draft.issue)
        session.draftText = "printf '\u{1b}'"
        XCTAssertNotNil(session.draft.issue)
        session.draftText = "printf '%s\\n' 'ordinary quoted text'"
        session.reviewed = true
        session.chooseDirectory(directory.appendingPathComponent("missing"))
        session.reviewed = true
        XCTAssertThrowsError(try session.runDraft())
    }

    func testInteractivePTYResizeInterruptAndExit() async throws {
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(URL(fileURLWithPath: "/tmp"))
        try session.startShell()
        let process = try XCTUnwrap(session.process)
        let view = try XCTUnwrap(session.view)
        XCTAssertEqual(isatty(process.childfd), 1)
        view.resize(cols: 93, rows: 27)
        session.sizeChanged(source: view, newCols: 93, newRows: 27)
        send("stty size; printf 'READY\\n'\r", session: session)
        try await waitForOutput("27 93", session: session)
        send("/bin/sleep 30\r", session: session)
        for _ in 0..<100 where tcgetpgrp(process.childfd) == process.shellPid { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotEqual(tcgetpgrp(process.childfd), process.shellPid)
        send("\u{3}", session: session)
        for _ in 0..<100 where tcgetpgrp(process.childfd) != process.shellPid { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(tcgetpgrp(process.childfd), process.shellPid)
        send("printf 'AFTER_INTERRUPT\\n'\r", session: session)
        try await waitForOutput("AFTER_INTERRUPT", session: session)
        send("exit 7\r", session: session)
        try await waitForExit(session)
        XCTAssertEqual(session.status, "Session ended • exit 7")
        XCTAssertEqual(kill(process.shellPid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testEndingPTYCleansForegroundAndBackgroundJobs() async throws {
        let session = TerminalSession()
        defer { session.shutdown() }
        try session.startShell()
        let process = try XCTUnwrap(session.process)
        send("/bin/sleep 30 & /bin/sleep 30\r", session: session)
        var members: [pid_t] = []
        for _ in 0..<100 {
            members = try terminalSessionMembers(sessionID: process.shellPid)
            if members.count >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(members.count, 3)
        session.expanded = false
        XCTAssertTrue(session.active, "Collapsing must retain the session")
        session.stop()
        try await waitForExit(session)
        for _ in 0..<150 where session.stopping { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(session.stopping)
        XCTAssertNil(session.errorMessage)
        for _ in 0..<100 where members.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        for pid in members { XCTAssertEqual(kill(pid, 0), -1, "Owned process \(pid) survived cleanup") }
    }

    private func send(_ text: String, session: TerminalSession) { session.process?.send(data: Array(text.utf8)[...]) }

    private func output(_ session: TerminalSession) -> String {
        guard let view = session.view else { return "" }
        return String(decoding: view.getTerminal().getBufferAsData(kind: .active, encoding: .utf8), as: UTF8.self)
    }

    private func waitForOutput(_ expected: String, session: TerminalSession) async throws {
        for _ in 0..<300 where !output(session).contains(expected) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(output(session).contains(expected), "Terminal did not render expected test output: \(expected)")
    }

    private func waitForExit(_ session: TerminalSession) async throws {
        for _ in 0..<500 where session.active { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(session.active, "PTY did not exit within five seconds")
        XCTAssertNil(session.errorMessage)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTemporary(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Cannot clean terminal test directory: \(error)") }
    }
}
