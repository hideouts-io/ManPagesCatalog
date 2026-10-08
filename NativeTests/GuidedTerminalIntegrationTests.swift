import XCTest
import SwiftUI
import SwiftTerm
import ApplicationServices
import Darwin
@testable import Man_Page_Catalog

@MainActor
final class GuidedTerminalIntegrationTests: XCTestCase {
    func testGuidedPreviewClipboardAndPTYUseTheSameAbsolutePath() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let folder = directory.appendingPathComponent("actual folder")
        let alias = directory.appendingPathComponent("folder with spaces and ' quote ... <value>")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: folder.appendingPathComponent("visible-marker.txt"))
        try Data().write(to: folder.appendingPathComponent(".hidden-marker.txt"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(directory)
        session.buildCommand(page: manual(name: "ls", section: "1"))
        XCTAssertNil(session.process, "Building a command must not start a PTY")
        XCTAssertEqual(session.commandTarget, .executable(path: "/bin/ls"))
        XCTAssertEqual(session.guidedRecipe?.id, "ls.folder")
        session.setGuidedInput(id: "folder", value: alias.path)
        session.setGuidedOption(id: "hidden", selected: true)
        session.setGuidedOption(id: "detailed", selected: true)
        let preview = try XCTUnwrap(session.generatedText)
        XCTAssertEqual(preview, guidedCommandText(executablePath: "/bin/ls", arguments: ["-H", "-A", "-l", alias.path]))
        XCTAssertEqual(session.draftText, preview)
        XCTAssertNil(session.guidanceIssue)
        XCTAssertNil(session.runIssue, "Generated literal filenames must not be mistaken for copied manual placeholders")
        try session.copyDraft()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), preview)
        XCTAssertNil(session.process, "Copying the generated preview must not start a PTY")
        XCTAssertThrowsError(try session.runDraft(), "Preparation and copying do not grant review")
        session.reviewed = true
        try session.runDraft()
        try await waitForExit(session)
        try await waitForOutput(".hidden-marker.txt", session: session)
        XCTAssertTrue(output(session).contains("visible-marker.txt"))
        XCTAssertTrue(output(session).contains("total "), "The optional detailed flag must reach the real ls process")
        XCTAssertEqual(session.outcome, .completed)
        XCTAssertFalse(session.reviewed)
    }

    func testTypedWorkingFolderAndPickerRequireFreshReviewBeforePTY() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let typedFolder = directory.appendingPathComponent("working folder with ' quote")
        let pickedFolder = directory.appendingPathComponent("picker folder")
        try FileManager.default.createDirectory(at: typedFolder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: pickedFolder, withIntermediateDirectories: false)
        let session = TerminalSession()
        defer { session.shutdown() }
        session.prepare(text: "pwd", source: nil)

        session.reviewed = true
        session.setWorkingDirectoryPath("relative/folder")
        XCTAssertFalse(session.reviewed)
        XCTAssertNotNil(session.directoryIssue)
        XCTAssertThrowsError(try session.runDraft())
        XCTAssertNil(session.process)

        session.setWorkingDirectoryPath(typedFolder.path)
        XCTAssertNil(session.directoryIssue)
        XCTAssertEqual(session.directory.path, typedFolder.path)
        XCTAssertEqual(session.draftText, "pwd")
        session.reviewed = true
        session.chooseDirectory(pickedFolder)
        XCTAssertFalse(session.reviewed)
        XCTAssertEqual(session.workingDirectoryPath, pickedFolder.path)
        XCTAssertEqual(session.directory.path, pickedFolder.path)

        session.setWorkingDirectoryPath(typedFolder.path)
        session.reviewed = true
        try session.runDraft()
        try await waitForExit(session)
        try await waitForOutput(typedFolder.path, session: session)
        XCTAssertEqual(session.startedDirectory?.path, typedFolder.path)
        XCTAssertEqual(session.outcome, .completed)
    }

    func testExplicitExecutableWithQuotedPathRunsAndMissingExecutableFailsBeforePTY() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let executable = directory.appendingPathComponent("command with spaces and ' quote")
        let marker = directory.appendingPathComponent("execution-marker.txt")
        let script = "#!/bin/sh\n/usr/bin/printf '%s\\n' 'ABSOLUTE_PATH_EXECUTED' > \(quotedShellWord(marker.path))\n/usr/bin/printf '%s\\n' 'ABSOLUTE_PATH_EXECUTED'\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(directory)
        session.buildCommand(page: manual(name: "catalog-test-missing", section: "1"))
        try session.selectExecutable(url: executable)
        XCTAssertEqual(session.commandTarget, .executable(path: executable.path))
        XCTAssertEqual(session.generatedText, quotedShellWord(executable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(session.process)
        try session.copyDraft()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), session.generatedText)
        session.reviewed = true
        try session.runDraft()
        try await waitForExit(session)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "ABSOLUTE_PATH_EXECUTED\n")
        try await waitForOutput("ABSOLUTE_PATH_EXECUTED", session: session)

        let unavailable = TerminalSession()
        defer { unavailable.shutdown() }
        unavailable.chooseDirectory(directory)
        unavailable.buildCommand(page: manual(name: "catalog-test-missing", section: "1"))
        try unavailable.selectExecutable(url: executable)
        try FileManager.default.removeItem(at: executable)
        unavailable.reviewed = true
        XCTAssertThrowsError(try unavailable.runDraft()) { error in
            XCTAssertTrue(error.localizedDescription.contains(executable.path))
            XCTAssertTrue(error.localizedDescription.contains("Locate"))
        }
        XCTAssertNil(unavailable.process, "A vanished selected executable must fail before allocating a PTY")
        XCTAssertThrowsError(try unavailable.copyDraft())
    }

    func testDiskUsageFollowsTheSelectedFolderSymlink() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let folder = directory.appendingPathComponent("source folder")
        let alias = directory.appendingPathComponent("selected folder link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data(repeating: 0x61, count: 262_144).write(to: folder.appendingPathComponent("allocated-file"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let directOutput = try await runManualTool(executable: URL(fileURLWithPath: "/usr/bin/du"),
            arguments: ["-s", folder.path], directory: directory, input: nil)
        let directBlocks = try XCTUnwrap(Int(String(decoding: directOutput, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""))
        XCTAssertGreaterThan(directBlocks, 0, "The owned file must have allocated storage for this integration check")
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(directory)
        session.buildCommand(page: manual(name: "du", section: "1"))
        session.setGuidedInput(id: "folder", value: alias.path)
        XCTAssertNil(session.runIssue)
        XCTAssertEqual(session.generatedText, guidedCommandText(executablePath: "/usr/bin/du", arguments: ["-s", "-H", alias.path]))
        XCTAssertNil(session.process)
        session.reviewed = true
        try session.runDraft()
        let terminal = try XCTUnwrap(session.view)
        let columns = alias.path.utf8.count + 32
        terminal.resize(cols: columns, rows: 24)
        session.sizeChanged(source: terminal, newCols: columns, newRows: 24)
        try await waitForExit(session)
        try await waitForOutput(alias.path, session: session)
        let rendered = output(session)
        let attachment = XCTAttachment(string: rendered)
        attachment.name = "Real du folder-link PTY output"
        attachment.lifetime = .keepAlways
        add(attachment)
        let aliasBlocks = try XCTUnwrap(Int(rendered.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""))
        XCTAssertEqual(aliasBlocks, directBlocks, "The selected folder link must measure its folder rather than the link itself")
        try session.copyOutput()
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertEqual(copied, rendered, "Copy Output must preserve the independent library rendering, including tab field spacing")
        XCTAssertEqual(Int(copied.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""), directBlocks)
        XCTAssertEqual(terminal.accessibilityValue() as? String, rendered)
        XCTAssertEqual(session.outcome, .completed)
    }

    func testGuidedChangesInvalidateReviewAndInvalidInputsCannotRun() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(directory)
        session.buildCommand(page: manual(name: "ls", section: "1"))
        session.setGuidedInput(id: "folder", value: directory.path)
        session.reviewed = true
        session.setGuidedOption(id: "hidden", selected: true)
        XCTAssertFalse(session.reviewed)
        session.reviewed = true
        session.setGuidedInput(id: "folder", value: directory.path + "/different folder")
        XCTAssertFalse(session.reviewed)
        session.reviewed = true
        session.chooseDirectory(directory)
        XCTAssertFalse(session.reviewed)
        session.reviewed = true
        try session.selectExecutable(url: URL(fileURLWithPath: "/bin/ls"))
        XCTAssertFalse(session.reviewed)
        session.setGuidedInput(id: "folder", value: "relative/folder")
        XCTAssertNotNil(session.guidanceIssue)
        session.reviewed = true
        XCTAssertThrowsError(try session.runDraft())
        XCTAssertNil(session.process)
        session.setGuidedInput(id: "folder", value: directory.path)
        session.setGuidedOption(id: "modified", selected: true)
        session.setGuidedOption(id: "size", selected: true)
        XCTAssertNotNil(session.guidanceIssue, "Conflicting optional flags require an explicit choice")
        session.reviewed = true
        XCTAssertThrowsError(try session.runDraft())
        XCTAssertNil(session.process)

        session.buildCommand(page: manual(name: "diskutil", section: "8"))
        session.reviewed = true
        session.selectGuidedRecipe(id: "diskutil.info")
        XCTAssertFalse(session.reviewed)
        XCTAssertNotNil(session.guidanceIssue, "Disk info needs an explicit current identifier")
        session.setGuidedInput(id: "device", value: "disk0; /bin/echo injected")
        XCTAssertNotNil(session.guidanceIssue)
        session.reviewed = true
        XCTAssertThrowsError(try session.runDraft())
        XCTAssertNil(session.process)
        session.setGuidedInput(id: "device", value: "disk0s1")
        XCTAssertNil(session.guidanceIssue)
        XCTAssertEqual(session.generatedText, guidedCommandText(executablePath: "/usr/sbin/diskutil", arguments: ["info", "disk0s1"]))
    }

    func testExamplesAndEditedShellTextRemainExactAndBuiltinsHaveNoExecutablePath() throws {
        let session = TerminalSession()
        defer { session.shutdown() }
        let text = "printf '%s\\n' 'two words'\nprintf '%s\\n' \"$HOME\"\n"
        let source = DraftSource(title: "printf(1)", path: "/usr/share/man/man1/printf.1", executable: "/usr/bin/printf")
        session.prepare(text: text, source: source)
        XCTAssertEqual(session.draftText, text)
        XCTAssertNil(session.generatedText)
        XCTAssertNil(session.process)
        session.buildCommand(page: manual(name: "ls", section: "1"))
        session.reviewed = true
        session.editDraft(text: text)
        XCTAssertEqual(session.draftText, text)
        XCTAssertNil(session.generatedText, "Editing switches to the exact user-written draft")
        XCTAssertFalse(session.reviewed)
        XCTAssertThrowsError(try session.selectExecutable(url: URL(fileURLWithPath: "/bin/ls")))
        XCTAssertEqual(session.draftText, text, "Locating an executable cannot silently replace edited shell text")
        XCTAssertNil(session.generatedText)
        session.buildCommand(page: manual(name: "whence", section: "1"))
        XCTAssertEqual(session.commandTarget, .shellBuiltin(name: "whence"))
        XCTAssertNil(session.commandTarget?.path)
        XCTAssertEqual(session.generatedText, "builtin " + quotedShellWord("whence"))
        XCTAssertNil(session.process)
        session.buildCommand(page: manual(name: "printf", section: "3"))
        guard case .documentationOnly = session.commandTarget else {
            return XCTFail("API manuals must be identified as documentation rather than command executables")
        }
        XCTAssertTrue(session.draftText.isEmpty)
        XCTAssertNotNil(session.guidanceIssue)
        XCTAssertNil(session.process)
    }

    func testGuidedFolderKindAvailabilityAndRemovalAreCheckedBeforeRun() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let folder = directory.appendingPathComponent("selected folder")
        let file = directory.appendingPathComponent("ordinary file")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: file)
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(directory)
        session.buildCommand(page: manual(name: "ls", section: "1"))
        session.setGuidedInput(id: "folder", value: file.path)
        XCTAssertNotNil(session.guidanceIssue, "A folder input must reject an ordinary file")
        session.reviewed = true
        XCTAssertThrowsError(try session.runDraft())
        XCTAssertNil(session.process)
        session.setGuidedInput(id: "folder", value: directory.appendingPathComponent("missing folder").path)
        XCTAssertNotNil(session.guidanceIssue, "A folder input must reject a missing folder")
        XCTAssertThrowsError(try session.copyDraft())
        session.setGuidedInput(id: "folder", value: folder.path)
        XCTAssertNil(session.guidanceIssue)
        let preview = try XCTUnwrap(session.generatedText)
        session.reviewed = true
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try session.runDraft()) { error in
            XCTAssertTrue(error.localizedDescription.contains(folder.path))
        }
        XCTAssertEqual(session.draftText, preview, "Availability errors must preserve the reviewed command for correction")
        XCTAssertNil(session.process, "A removed folder must be rejected before a PTY is allocated")
        XCTAssertThrowsError(try session.copyDraft())
    }

    func testInterruptAndFailureKeepRawOutputAndReportTheirOutcome() async throws {
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(URL(fileURLWithPath: "/tmp"))
        session.prepare(text: "/usr/bin/printf 'INTERRUPT_READY\\n'; /bin/sleep 30", source: nil)
        XCTAssertNil(session.process)
        session.reviewed = true
        try session.runDraft()
        XCTAssertEqual(session.outcome, .running)
        try await waitForOutput("INTERRUPT_READY", session: session)
        try session.interrupt()
        try await waitForExit(session)
        XCTAssertEqual(session.outcome, .interrupted)
        XCTAssertTrue(output(session).contains("INTERRUPT_READY"))
        try session.copyOutput()
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("INTERRUPT_READY") == true)
        XCTAssertThrowsError(try session.interrupt())
        session.prepare(text: "/usr/bin/printf 'FAILURE_DETAILS\\n'; exit 7", source: nil)
        session.reviewed = true
        try session.runDraft()
        try await waitForExit(session)
        try await waitForOutput("FAILURE_DETAILS", session: session)
        XCTAssertEqual(session.outcome, .failed)
        XCTAssertEqual(session.status, "Session ended • exit 7")
        XCTAssertTrue(output(session).contains("FAILURE_DETAILS"))
    }

    func testCommandWorkspaceRendersGuidanceAndAccessibleControls() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporary(directory) }
        let session = TerminalSession()
        defer { session.shutdown() }
        session.chooseDirectory(directory)
        session.buildCommand(page: manual(name: "ls", section: "1"))
        session.setGuidedInput(id: "folder", value: directory.path)
        let host = NSHostingView(rootView: TerminalPane(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 840),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("guidedTerminalReviewWindow")
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        var identifiers: Set<String> = []
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            identifiers = try accessibilityIdentifiers(windowIdentifier: "guidedTerminalReviewWindow")
            if identifiers.contains("generatedCommandPreview") && identifiers.contains("guidedAction") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for identifier in ["guidedAction", "guided-option-hidden", "guided-input-folder", "generatedCommandPreview",
                           "commandExecutablePath", "commandEffects", "copyDraft", "reviewCommandDraft", "runCommandDraft",
                           "chooseCommandDirectory", "expandTerminalPane"] {
            XCTAssertTrue(identifiers.contains(identifier), "Missing stable accessibility identifier \(identifier)")
        }
        XCTAssertEqual(try accessibilityTextValue(windowIdentifier: "guidedTerminalReviewWindow",
            controlIdentifier: "generatedCommandPreview"), session.generatedText)
        try await pressAccessibilityControl(windowIdentifier: "guidedTerminalReviewWindow", controlIdentifier: "guided-option-hidden")
        try await pressAccessibilityControl(windowIdentifier: "guidedTerminalReviewWindow", controlIdentifier: "guided-option-detailed")
        let changedPreview = try XCTUnwrap(session.generatedText)
        XCTAssertEqual(changedPreview, guidedCommandText(executablePath: "/bin/ls", arguments: ["-H", "-A", "-l", directory.path]))
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if try accessibilityTextValue(windowIdentifier: "guidedTerminalReviewWindow",
                controlIdentifier: "generatedCommandPreview") == changedPreview { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try accessibilityTextValue(windowIdentifier: "guidedTerminalReviewWindow",
            controlIdentifier: "generatedCommandPreview"), changedPreview)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bitmap.pixelsWide, 1000)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 700)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Guided command workspace rendered native view"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNil(session.process, "Rendering guidance must not execute a command")
    }

    private func manual(name: String, section: String) -> ManualPage {
        let source = URL(fileURLWithPath: "/usr/share/man/man\(section)/\(name).\(section)")
        return ManualPage(name: name, section: section, source: source, root: URL(fileURLWithPath: "/usr/share/man"),
            fingerprint: "guided-test-\(name)", language: "", locations: [], description: "", indexed: false, problem: nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GuidedTerminalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func removeTemporary(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Cannot clean guided-terminal test directory: \(error)") }
    }

    private func output(_ session: TerminalSession) -> String {
        guard let view = session.view else { return "" }
        let terminal = view.getTerminal()
        return terminal.getText(start: Position(col: 0, row: 0),
            end: Position(col: terminal.cols, row: Int.max))
    }

    private func waitForExit(_ session: TerminalSession) async throws {
        for _ in 0..<500 where session.active { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(session.active, "The owned PTY did not exit within five seconds")
        XCTAssertNil(session.errorMessage)
    }

    private func waitForOutput(_ expected: String, session: TerminalSession) async throws {
        for _ in 0..<300 where !output(session).contains(expected) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(output(session).contains(expected), "The PTY did not render expected owned output: \(expected)")
    }

    /// SwiftUI's own-process AX provider executes synchronously on the caller's thread.
    /// Keep these public AX queries on MainActor and restrict them to the uniquely identified test window.
    private func accessibilityWindow(windowIdentifier: String) throws -> AXUIElement {
        let owned = NSApplication.shared.windows.filter { $0.accessibilityIdentifier() == windowIdentifier }
        guard owned.count == 1 else {
            throw TerminalSessionError(message: "Expected one owned test window \(windowIdentifier); found \(owned.count).")
        }
        let application = AXUIElementCreateApplication(getpid())
        let timeout = AXUIElementSetMessagingTimeout(application, 2)
        guard timeout == .success else {
            throw TerminalSessionError(message: "Cannot set own-process accessibility timeout: status \(timeout.rawValue).")
        }
        let windows = try accessibilityElements(element: application, attribute: kAXWindowsAttribute as CFString)
        let matches = try windows.filter { try accessibilityIdentifier(element: $0) == windowIdentifier }
        guard matches.count == 1, let window = matches.first else {
            throw TerminalSessionError(message: "Expected one accessible owned window \(windowIdentifier); found \(matches.count).")
        }
        return window
    }

    /// AXUIElement's public Core Foundation contract uses CFTypeRef; validate every consumed result before use.
    private func accessibilityElements(element: AXUIElement, attribute: CFString) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        if status == .attributeUnsupported || status == .noValue { return [] }
        guard status == .success, let children = value as? [AXUIElement],
              children.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
            throw TerminalSessionError(message: "Cannot read owned accessibility elements: status \(status.rawValue).")
        }
        guard children.count <= 10_000 else {
            throw TerminalSessionError(message: "The owned accessibility child collection exceeded 10000 elements.")
        }
        return children
    }

    private func accessibilityIdentifier(element: AXUIElement) throws -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, NSAccessibility.Attribute.identifier.rawValue as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let identifier = value as? String, identifier.utf8.count <= 4096 else {
            throw TerminalSessionError(message: "Cannot read owned accessibility identifier: status \(status.rawValue).")
        }
        return identifier
    }

    private func accessibilityDescendants(element: AXUIElement, depth: Int) throws -> [AXUIElement] {
        guard depth > 0 else {
            throw TerminalSessionError(message: "The owned accessibility tree exceeded 64 levels.")
        }
        var processIdentifier: pid_t = 0
        let processStatus = AXUIElementGetPid(element, &processIdentifier)
        guard processStatus == .success else {
            throw TerminalSessionError(message: "Cannot identify the accessibility element's process: status \(processStatus.rawValue).")
        }
        if processIdentifier != getpid() { return [] }
        let identifier = try accessibilityIdentifier(element: element)
        var role: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard roleStatus == .success, let roleName = role as? String else {
            throw TerminalSessionError(message: "Cannot read owned accessibility role for \(identifier ?? "unidentified chrome") at depth \(depth), process \(processIdentifier): status \(roleStatus.rawValue).")
        }
        // Command controls live in native chrome. The manual's remote WebKit content is outside this test's boundary.
        if roleName == "AXWebArea" { return [element] }
        let children = try accessibilityElements(element: element, attribute: kAXChildrenAttribute as CFString)
        var descendants: [AXUIElement] = [element]
        for child in children { descendants += try accessibilityDescendants(element: child, depth: depth - 1) }
        guard descendants.count <= 10_000 else {
            throw TerminalSessionError(message: "The owned accessibility tree exceeded 10000 elements.")
        }
        return descendants
    }

    private func accessibilityIdentifiers(windowIdentifier: String) throws -> Set<String> {
        let window = try accessibilityWindow(windowIdentifier: windowIdentifier)
        let elements = try accessibilityDescendants(element: window, depth: 64)
        return Set(try elements.compactMap { try accessibilityIdentifier(element: $0) })
    }

    private func accessibilityControl(windowIdentifier: String, controlIdentifier: String) throws -> AXUIElement {
        let window = try accessibilityWindow(windowIdentifier: windowIdentifier)
        let elements = try accessibilityDescendants(element: window, depth: 64)
        let matches = try elements.filter { try accessibilityIdentifier(element: $0) == controlIdentifier }
        guard matches.count == 1, let control = matches.first else {
            throw TerminalSessionError(message: "Expected one owned accessibility control \(controlIdentifier); found \(matches.count).")
        }
        return control
    }

    private func accessibilityTextValue(windowIdentifier: String, controlIdentifier: String) throws -> String {
        let control = try accessibilityControl(windowIdentifier: windowIdentifier, controlIdentifier: controlIdentifier)
        var names: CFArray?
        let namesStatus = AXUIElementCopyAttributeNames(control, &names)
        guard namesStatus == .success, let attributes = names as? [String], attributes.count <= 128,
              attributes.contains(kAXValueAttribute) else {
            throw TerminalSessionError(message: "The owned static-text control \(controlIdentifier) did not advertise its text value: status \(namesStatus.rawValue).")
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(control, kAXValueAttribute as CFString, &value)
        guard status == .success, let text = value as? String, text.utf8.count <= 65_536 else {
            throw TerminalSessionError(message: "Cannot read owned accessibility text value \(controlIdentifier): status \(status.rawValue).")
        }
        return text
    }

    private func pressAccessibilityControl(windowIdentifier: String, controlIdentifier: String) async throws {
        let before = XCTAttachment(string: "before AXPress\nwindow: \(windowIdentifier)\ncontrol: \(controlIdentifier)\nowned process: \(getpid())")
        before.name = "Owned command control before press"
        before.lifetime = .keepAlways
        add(before)
        let control = try accessibilityControl(windowIdentifier: windowIdentifier, controlIdentifier: controlIdentifier)
        let status = AXUIElementPerformAction(control, kAXPressAction as CFString)
        guard status == .success else {
            throw TerminalSessionError(message: "Cannot press owned accessibility control \(controlIdentifier): status \(status.rawValue).")
        }
        await Task.yield()
        let after = XCTAttachment(string: "after AXPress\nwindow: \(windowIdentifier)\ncontrol: \(controlIdentifier)\nstatus: \(status.rawValue)")
        after.name = "Owned command control after press"
        after.lifetime = .keepAlways
        add(after)
    }

}
