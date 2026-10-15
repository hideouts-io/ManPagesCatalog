import XCTest
import AppKit
import Foundation
import CryptoKit
import Darwin

/// Uses the launched application and XCTest's native UI driver for alert focus and dismissal.
final class GuidedCommandWorkflowUITests: XCTestCase {
    func testCancellingAndApprovingDraftReplacementUseStableControls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GuidedCommandUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let application = XCUIApplication()
        var ownsLaunch = false
        defer {
            if ownsLaunch { application.terminate() }
            if !ownsLaunch || application.state == .notRunning {
                do { try FileManager.default.removeItem(at: directory) }
                catch { XCTFail("Cannot clean the owned command UI test library: \(error)") }
            } else {
                XCTFail("The owned application did not terminate; its UUID test library remains at \(directory.path).")
            }
        }
        try seedInstalledManual(directory: directory)
        let marker = directory.appendingPathComponent("must remain absent")
        let originalText = "/usr/bin/printf '%s\\n' 'keep this exact draft' > \(quotedShellWord(marker.path))\n"
        application.launchArguments = ["-libraryDirectory", directory.path]
        application.launchEnvironment = ["MANPATH": "/var/empty", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        guard application.state == .notRunning else {
            throw WorkflowTestError(message: "The target application is already running. Preserve that instance and close it before this isolated UI test.")
        }
        ownsLaunch = true
        application.launch()
        let launchState = application.state
        guard launchState == .runningForeground || launchState == .runningBackground else {
            throw WorkflowTestError(message: "The owned application did not start for its native command UI workflow; state \(launchState.rawValue).")
        }

        try click(identifier: "result-/usr/share/man/man1/ls.1", application: application)
        let build = try element(identifier: "buildCommand", application: application)
        try waitUntilEnabled(element: build)
        try click(identifier: "toggleTerminalPane", application: application)
        try click(identifier: "expandTerminalPane", application: application)
        try click(identifier: "editShellDraft", application: application)
        let editor = try element(identifier: "commandDraft", application: application)
        try waitUntilReady(control: editor, application: application)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(originalText)
        try waitForText(originalText, identifier: "commandDraft", application: application)
        try waitForText(originalText, identifier: "generatedCommandPreview", application: application)
        try assertNoExecution(application: application, marker: marker)
        XCTAssertFalse(try element(identifier: "runCommandDraft", application: application).isEnabled)
        XCTAssertEqual(application.descendants(matching: .any).matching(identifier: "guidedAction").count, 0)

        try click(identifier: "expandTerminalPane", application: application)
        try click(identifier: "hideTerminalPane", application: application)
        try click(identifier: "buildCommand", application: application)
        try click(identifier: "cancelGuidedCommand", application: application)
        try waitForAbsence(identifier: "cancelGuidedCommand", application: application)
        try click(identifier: "toggleTerminalPane", application: application)
        try click(identifier: "expandTerminalPane", application: application)
        try click(identifier: "editShellDraft", application: application)
        try waitForText(originalText, identifier: "generatedCommandPreview", application: application)
        try waitForText(originalText, identifier: "commandDraft", application: application)
        try assertNoExecution(application: application, marker: marker)
        XCTAssertEqual(application.descendants(matching: .any).matching(identifier: "guidedAction").count, 0)
        XCTAssertFalse(try element(identifier: "runCommandDraft", application: application).isEnabled)

        try click(identifier: "expandTerminalPane", application: application)
        try click(identifier: "hideTerminalPane", application: application)
        try click(identifier: "buildCommand", application: application)
        try click(identifier: "replaceWithGuidedCommand", application: application)
        try waitForAbsence(identifier: "replaceWithGuidedCommand", application: application)
        let action = try element(identifier: "guidedAction", application: application)
        XCTAssertEqual(try textValue(element: action), "List files in a folder")
        let folder = try element(identifier: "guided-input-folder", application: application)
        XCTAssertEqual(try textValue(element: folder), "")
        let issue = try element(identifier: "draftIssue", application: application)
        XCTAssertTrue(try textValue(element: issue).contains("Folder"), "The new guided action must require its folder before review")
        XCTAssertFalse(try element(identifier: "runCommandDraft", application: application).isEnabled)
        XCTAssertEqual(application.descendants(matching: .any).matching(identifier: "generatedCommandPreview").count, 0)
        try assertNoExecution(application: application, marker: marker)

        try click(identifier: "expandTerminalPane", application: application)
        let windows = application.windows.containing(.any, identifier: "expandTerminalPane")
        let window = windows.firstMatch
        guard window.waitForExistence(timeout: 5), windows.count == 1 else {
            throw WorkflowTestError(message: "Expected one native command workspace window for its screenshot; found \(windows.count).")
        }
        let screenshot = window.screenshot()
        XCTAssertGreaterThan(screenshot.image.size.width, 700)
        XCTAssertGreaterThan(screenshot.image.size.height, 500)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Native guided command after reviewed draft replacement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGuidedPreviewCopyRunAndPickerCancellationUseTheSamePath() throws {
        try withOwnedApplication { application, directory in
            let folder = directory.appendingPathComponent("folder with spaces and ' quote ... <value>")
            let otherFolder = directory.appendingPathComponent("other folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: false)
            try Data("visible\n".utf8).write(to: folder.appendingPathComponent("visible-entry"))
            try Data("hidden\n".utf8).write(to: folder.appendingPathComponent(".hidden-entry"))
            let marker = directory.appendingPathComponent("preparation must remain absent")

            try click(identifier: "result-/usr/share/man/man1/ls.1", application: application)
            try waitUntilEnabled(element: element(identifier: "buildCommand", application: application))
            try click(identifier: "buildCommand", application: application)
            try click(identifier: "expandTerminalPane", application: application)
            try replaceText(folder.path, identifier: "guided-input-folder", application: application)
            try click(identifier: "guided-option-hidden", application: application)
            try click(identifier: "guided-option-detailed", application: application)
            let expected = ["/bin/ls", "-H", "-A", "-l", folder.path].map(quotedShellWord).joined(separator: " ")
            try waitForText(expected, identifier: "generatedCommandPreview", application: application)
            try waitForText("/bin/ls", identifier: "commandExecutablePath", application: application)
            try assertNoExecution(application: application, marker: marker)
            XCTAssertFalse(try element(identifier: "runCommandDraft", application: application).isEnabled)

            try click(identifier: "reviewCommandDraft", application: application)
            try assertReviewed(application: application, expected: true)
            let initialWorkingFolder = try textValue(element: element(identifier: "draftDirectory", application: application))
            for opener in ["guided-choose-folder", "chooseCommandDirectory", "locateCommandExecutable"] {
                try cancelPicker(identifier: opener, application: application)
                try waitForText(expected, identifier: "generatedCommandPreview", application: application)
                try waitForText(folder.path, identifier: "guided-input-folder", application: application)
                try waitForText("/bin/ls", identifier: "commandExecutablePath", application: application)
                try waitForText(initialWorkingFolder, identifier: "draftDirectory", application: application)
                try assertReviewed(application: application, expected: true)
                try assertNoExecution(application: application, marker: marker)
            }

            try replaceText("relative/folder", identifier: "workingDirectoryPath", application: application)
            XCTAssertTrue(try textValue(element: element(identifier: "draftIssue", application: application)).contains("absolute"))
            XCTAssertEqual(application.descendants(matching: .any).matching(identifier: "reviewCommandDraft").count, 0,
                "An invalid working folder must be corrected before review is available")
            XCTAssertFalse(try element(identifier: "runCommandDraft", application: application).isEnabled)
            try assertNoExecution(application: application, marker: marker)
            try replaceText("/private/tmp", identifier: "workingDirectoryPath", application: application)
            try waitForText("/tmp", identifier: "draftDirectory", application: application)
            try waitForText(expected, identifier: "generatedCommandPreview", application: application)
            try assertReviewed(application: application, expected: false)
            try click(identifier: "reviewCommandDraft", application: application)
            let chosenWorkingFolder = FileManager.default.homeDirectoryForCurrentUser
            try chooseWorkingFolder(directory: chosenWorkingFolder, application: application)
            let workingFolder = chosenWorkingFolder.resolvingSymlinksInPath().standardizedFileURL.path
            try waitForText(workingFolder, identifier: "draftDirectory", application: application)
            try waitForText(expected, identifier: "generatedCommandPreview", application: application)
            try waitForText("/bin/ls", identifier: "commandExecutablePath", application: application)
            try assertReviewed(application: application, expected: false)
            XCTAssertFalse(try element(identifier: "runCommandDraft", application: application).isEnabled)
            try assertNoExecution(application: application, marker: marker)
            try click(identifier: "reviewCommandDraft", application: application)

            try click(identifier: "guided-option-hidden", application: application)
            try assertReviewed(application: application, expected: false)
            XCTAssertFalse(try element(identifier: "runCommandDraft", application: application).isEnabled)
            try click(identifier: "guided-option-hidden", application: application)
            try click(identifier: "reviewCommandDraft", application: application)
            try replaceText(otherFolder.path, identifier: "guided-input-folder", application: application)
            try assertReviewed(application: application, expected: false)
            XCTAssertFalse(try element(identifier: "runCommandDraft", application: application).isEnabled)
            try replaceText(folder.path, identifier: "guided-input-folder", application: application)
            try waitForText(expected, identifier: "generatedCommandPreview", application: application)
            try click(identifier: "copyDraft", application: application)
            try waitForClipboard(expected)
            try assertNoExecution(application: application, marker: marker)

            try click(identifier: "reviewCommandDraft", application: application)
            try waitUntilEnabled(element: element(identifier: "runCommandDraft", application: application))
            try click(identifier: "runCommandDraft", application: application)
            try waitForText("Completed", identifier: "terminalOutcome", application: application)
            try waitForText(expected, identifier: "executedCommand", application: application)
            try waitForText(workingFolder, identifier: "terminalStartDirectory", application: application)
            let output = try waitForOutput(containing: ["visible-entry", ".hidden-entry", "total"], application: application)
            XCTAssertGreaterThan(try textValue(element: element(identifier: "terminalResultHelp", application: application)).utf8.count, 0)
            try click(identifier: "copyTerminalOutput", application: application)
            try waitForClipboard(output)
            XCTAssertEqual(application.descendants(matching: .any).matching(identifier: "interruptTerminal").count, 0)
            XCTAssertEqual(application.descendants(matching: .any).matching(identifier: "endTerminalSession").count, 0)
            try attachOwnedWindow(application: application, name: "Native guided command completed with readable output")
        }
    }

    func testRunningCollapsedIndicatorInterruptAndEndControls() throws {
        try withOwnedApplication { application, directory in
            let marker = directory.appendingPathComponent("interrupted continuation must remain absent")
            let text = "/usr/bin/printf '%s\\n' 'owned-ui-started'\n/bin/sleep 120\n/usr/bin/printf '%s\\n' 'finished' > \(quotedShellWord(marker.path))\n"
            try click(identifier: "toggleTerminalPane", application: application)
            try click(identifier: "expandTerminalPane", application: application)
            try click(identifier: "editShellDraft", application: application)
            try replaceText(text, identifier: "commandDraft", application: application)
            try waitForText(text, identifier: "generatedCommandPreview", application: application)
            try assertNoExecution(application: application, marker: marker)
            try click(identifier: "reviewCommandDraft", application: application)
            try click(identifier: "runCommandDraft", application: application)
            try waitForText("Running", identifier: "terminalOutcome", application: application)
            _ = try waitForOutput(containing: ["owned-ui-started"], application: application)
            try waitForText(text, identifier: "executedCommand", application: application)

            try click(identifier: "hideTerminalPane", application: application)
            try waitForAbsence(identifier: "embeddedTerminal", application: application)
            let indicator = try element(identifier: "showRunningTerminal", application: application)
            XCTAssertTrue(indicator.isHittable)
            XCTAssertTrue(try element(identifier: "toggleTerminalPane", application: application).label.contains("Running"))
            try click(identifier: "showRunningTerminal", application: application)
            try waitForText("Running", identifier: "terminalOutcome", application: application)
            try click(identifier: "interruptTerminal", application: application)
            try waitForText("Interrupted", identifier: "terminalOutcome", application: application)
            _ = try waitForOutput(containing: ["owned-ui-started"], application: application)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            try waitForAbsence(identifier: "showRunningTerminal", application: application)
            try waitForAbsence(identifier: "interruptTerminal", application: application)
            try waitForAbsence(identifier: "endTerminalSession", application: application)

            try click(identifier: "reviewCommandDraft", application: application)
            try waitUntilEnabled(element: element(identifier: "runCommandDraft", application: application))
            try click(identifier: "runCommandDraft", application: application)
            try waitForText("Running", identifier: "terminalOutcome", application: application)
            _ = try waitForOutput(containing: ["owned-ui-started"], application: application)
            try click(identifier: "endTerminalSession", application: application)
            try click(identifier: "cancelEndTerminal", application: application)
            try waitForAbsence(identifier: "cancelEndTerminal", application: application)
            try waitForText("Running", identifier: "terminalOutcome", application: application)
            XCTAssertTrue(try element(identifier: "interruptTerminal", application: application).isEnabled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            try click(identifier: "endTerminalSession", application: application)
            try click(identifier: "confirmEndTerminal", application: application)
            try waitForAbsence(identifier: "confirmEndTerminal", application: application)
            try waitForText("Session ended", identifier: "terminalOutcome", application: application)
            _ = try waitForOutput(containing: ["owned-ui-started"], application: application)
            try waitForAbsence(identifier: "showRunningTerminal", application: application)
            try waitForAbsence(identifier: "interruptTerminal", application: application)
            try waitForAbsence(identifier: "endTerminalSession", application: application)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            try attachOwnedWindow(application: application, name: "Native terminal after explicit session end")
        }
    }

    /// Each launch owns only its UUID library and refuses to terminate a preexisting application.
    private func withOwnedApplication(_ workflow: (XCUIApplication, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GuidedCommandUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let application = XCUIApplication()
        var ownsLaunch = false
        defer {
            if ownsLaunch { application.terminate() }
            if !ownsLaunch || application.state == .notRunning {
                do { try FileManager.default.removeItem(at: directory) }
                catch { XCTFail("Cannot clean the owned command UI test library: \(error)") }
            } else {
                XCTFail("The owned application did not terminate; its UUID test library remains at \(directory.path).")
            }
        }
        try seedInstalledManual(directory: directory)
        application.launchArguments = ["-libraryDirectory", directory.path]
        application.launchEnvironment = ["MANPATH": "/var/empty", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        guard application.state == .notRunning else {
            throw WorkflowTestError(message: "The target application is already running. Preserve that instance and close it before this isolated UI test.")
        }
        ownsLaunch = true
        application.launch()
        let launchState = application.state
        guard launchState == .runningForeground || launchState == .runningBackground else {
            throw WorkflowTestError(message: "The owned application did not start for its native command UI workflow; state \(launchState.rawValue).")
        }
        try workflow(application, directory)
    }

    private func replaceText(_ text: String, identifier: String, application: XCUIApplication) throws {
        let editor = try element(identifier: identifier, application: application)
        try waitUntilReady(control: editor, application: application)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(text)
        try waitForText(text, identifier: identifier, application: application)
    }

    private func cancelPicker(identifier: String, application: XCUIApplication) throws {
        try click(identifier: identifier, application: application)
        let panels = application.dialogs.matching(identifier: "open-panel")
        guard panels.firstMatch.waitForExistence(timeout: 5), panels.count == 1 else {
            throw WorkflowTestError(message: "The native picker \(identifier) did not expose its unique open-panel dialog.")
        }
        let buttons = panels.firstMatch.buttons.matching(identifier: "CancelButton")
        guard buttons.firstMatch.waitForExistence(timeout: 5), buttons.count == 1 else {
            throw WorkflowTestError(message: "The native picker \(identifier) did not expose its unique CancelButton.")
        }
        try waitUntilReady(control: buttons.firstMatch, application: application)
        buttons.firstMatch.click()
        try waitForAbsence(identifier: "open-panel", application: application)
    }

    /// Uses the observed native Go To Folder sheet, preserving the generated command while changing its working folder.
    private func chooseWorkingFolder(directory: URL, application: XCUIApplication) throws {
        try click(identifier: "chooseCommandDirectory", application: application)
        let panels = application.dialogs.matching(identifier: "open-panel")
        guard panels.firstMatch.waitForExistence(timeout: 5), panels.count == 1 else {
            throw WorkflowTestError(message: "The working folder picker did not expose its unique open-panel dialog.")
        }
        // The native panel's container can report disabled while its controls accept input.
        application.typeKey("g", modifierFlags: [.command, .shift])
        _ = try element(identifier: "GoToWindow", application: application)
        try replaceText(directory.path, identifier: "PathTextField", application: application)
        let path = try element(identifier: "PathTextField", application: application)
        path.typeKey(.return, modifierFlags: [])
        try waitForAbsence(identifier: "GoToWindow", application: application)
        let buttons = panels.firstMatch.buttons.matching(identifier: "OKButton")
        guard buttons.firstMatch.waitForExistence(timeout: 5), buttons.count == 1 else {
            throw WorkflowTestError(message: "The working folder picker did not expose its unique OKButton.")
        }
        try waitUntilReady(control: buttons.firstMatch, application: application)
        buttons.firstMatch.click()
        try waitForAbsence(identifier: "open-panel", application: application)
    }

    private func assertReviewed(application: XCUIApplication, expected: Bool) throws {
        let control = try element(identifier: "reviewCommandDraft", application: application)
        let reviewed: Bool
        if let value = control.value as? String, value == "0" || value == "1" {
            reviewed = value == "1"
        } else if let value = control.value as? NSNumber, value == NSNumber(value: 0) || value == NSNumber(value: 1) {
            reviewed = value == NSNumber(value: 1)
        } else {
            throw WorkflowTestError(message: "The native review checkbox did not expose a 0 or 1 String or NSNumber value.")
        }
        XCTAssertEqual(reviewed, expected)
    }

    private func waitForClipboard(_ expected: String) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSPasteboard.general.string(forType: .string) == expected
        }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            throw WorkflowTestError(message: "The command UI clipboard action did not copy its exact displayed text.")
        }
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
    }

    private func waitForOutput(containing terms: [String], application: XCUIApplication) throws -> String {
        let terminal = try element(identifier: "embeddedTerminal", application: application)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = terminal.value as? String, text.utf8.count <= 65_536 else { return false }
            return terms.allSatisfy(text.contains)
        }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            try attachOwnedWindow(application: application, name: "Native command output at missing controlled results")
            throw WorkflowTestError(message: "The native terminal did not display all expected results from its controlled command.")
        }
        return try textValue(element: terminal)
    }

    private func element(identifier: String, application: XCUIApplication) throws -> XCUIElement {
        let query = application.descendants(matching: .any).matching(identifier: identifier)
        guard query.firstMatch.waitForExistence(timeout: 5), query.count == 1 else {
            throw WorkflowTestError(message: "Expected one native command control \(identifier); found \(query.count).")
        }
        return query.firstMatch
    }

    private func click(identifier: String, application: XCUIApplication) throws {
        let control = try element(identifier: identifier, application: application)
        try waitUntilReady(control: control, application: application)
        control.click()
    }

    private func waitUntilReady(control: XCUIElement, application: XCUIApplication) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            control.exists && control.isEnabled && control.isHittable
        }, object: nil)
        if XCTWaiter.wait(for: [expectation], timeout: 5) == .completed { return }
        // The final native accessibility query can complete after XCTest's predicate deadline.
        let exists = control.exists
        let enabled = exists && control.isEnabled
        let hittable = exists && control.isHittable
        if exists && enabled && hittable { return }
        let details = exists
            ? "type=\(control.elementType.rawValue), enabled=\(enabled), hittable=\(hittable), frame=\(NSStringFromRect(control.frame))"
            : "type/enabled/hittable/frame unavailable because the exact control no longer exists"
        let diagnostic = "Control=\(control.identifier), exists=\(exists), \(details), applicationState=\(application.state.rawValue)"
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = "Native command control not ready"
        attachment.lifetime = .keepAlways
        add(attachment)
        do { try attachOwnedWindow(application: application, name: "Native command control at interaction deadline") }
        catch { XCTFail("Cannot attach the owned window for an interaction readiness failure: \(error)") }
        throw WorkflowTestError(message: "The exact native command control was not enabled and hittable within five seconds. \(diagnostic)")
    }

    private func textValue(element: XCUIElement) throws -> String {
        guard let text = element.value as? String, text.utf8.count <= 65_536 else {
            throw WorkflowTestError(message: "The native control \(element.identifier) did not expose its bounded text value.")
        }
        return text
    }

    private func waitForText(_ expected: String, identifier: String, application: XCUIApplication) throws {
        let control = try element(identifier: identifier, application: application)
        let predicate = NSPredicate { _, _ in (control.value as? String) == expected }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            let actual = control.value as? String
            let diagnostic = "Control: \(identifier), type: \(control.elementType.rawValue), enabled: \(control.isEnabled), hittable: \(control.isHittable)\nExpected \(expected.utf8.count) UTF-8 bytes: \(String(reflecting: String(expected.prefix(1_024))))\nActual \(actual.map { String($0.utf8.count) } ?? "no String value") UTF-8 bytes: \(actual.map { String(reflecting: String($0.prefix(1_024))) } ?? "no String value")"
            let attachment = XCTAttachment(string: diagnostic)
            attachment.name = "Exact native command text mismatch"
            attachment.lifetime = .keepAlways
            add(attachment)
            do { try attachOwnedWindow(application: application, name: "Native command workspace at exact text mismatch") }
            catch { XCTFail("Cannot attach the command text mismatch window: \(error)") }
            throw WorkflowTestError(message: "The native control \(identifier) did not expose the exact prepared text before the deadline. \(diagnostic)")
        }
        XCTAssertEqual(try textValue(element: control), expected)
    }

    private func attachOwnedWindow(application: XCUIApplication, name: String) throws {
        let windows = application.windows.containing(.any, identifier: "toggleTerminalPane")
        guard windows.count == 1, windows.firstMatch.exists else {
            throw WorkflowTestError(message: "Cannot attach the uniquely identified owned command window for \(name); found \(windows.count).")
        }
        let attachment = XCTAttachment(screenshot: windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntilEnabled(element: XCUIElement) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.isEnabled }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            throw WorkflowTestError(message: "The installed manual did not enable its Build Command action before the deadline.")
        }
    }

    private func waitForAbsence(identifier: String, application: XCUIApplication) throws {
        let query = application.descendants(matching: .any).matching(identifier: identifier)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in query.count == 0 }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            throw WorkflowTestError(message: "The native alert control \(identifier) did not dismiss before the deadline.")
        }
    }

    private func assertNoExecution(application: XCUIApplication, marker: URL) throws {
        for identifier in ["embeddedTerminal", "interruptTerminal", "endTerminalSession", "showRunningTerminal"] {
            XCTAssertEqual(application.descendants(matching: .any).matching(identifier: identifier).count, 0,
                "Command preparation must not create a PTY or running session")
        }
        XCTAssertEqual(try textValue(element: element(identifier: "terminalOutcome", application: application)), "Ready to prepare")
        XCTAssertEqual(try textValue(element: element(identifier: "terminalStatus", application: application)), "No session started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "The exact raw draft must never execute during preparation or replacement")
    }

    /// Seed the actual installed manual using the existing discovery-v1 schema, with its real content identity and file stamp.
    private func seedInstalledManual(directory: URL) throws {
        let source = URL(fileURLWithPath: "/usr/share/man/man1/ls.1")
        let root = URL(fileURLWithPath: "/usr/share/man")
        var state = stat()
        guard lstat(source.path, &state) == 0 else {
            throw WorkflowTestError(message: "Cannot inspect the installed ls manual at \(source.path): errno \(errno).")
        }
        guard state.st_mode & S_IFMT == S_IFREG, state.st_size > 0, state.st_size <= 1_048_576 else {
            throw WorkflowTestError(message: "The installed ls manual must be a nonempty regular file no larger than 1 MB.")
        }
        let content = try Data(contentsOf: source)
        let fingerprint = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let stamp = "direct:\(source.path):\(state.st_dev):\(state.st_ino):\(state.st_size):\(state.st_mtimespec.tv_sec):\(state.st_mtimespec.tv_nsec):\(state.st_ctimespec.tv_sec):\(state.st_ctimespec.tv_nsec)"
        let location = FixtureManualLocation(source: source, root: root, name: "ls", section: "1", language: "unspecified", stamp: stamp)
        let page = FixtureManualPage(name: "ls", section: "1", source: source, root: root, fingerprint: fingerprint,
            language: "unspecified", locations: [location], description: "List directory contents", indexed: false, problem: nil)
        let inventory = FixtureLibraryScan(pages: [page], coverage: [], cancelled: false)
        let data = try JSONEncoder().encode(inventory)
        let verified = try JSONDecoder().decode(FixtureLibraryScan.self, from: data)
        guard verified.pages.count == 1, verified.pages[0].source == source,
              verified.pages[0].locations.count == 1, verified.pages[0].fingerprint == fingerprint else {
            throw WorkflowTestError(message: "The owned UI test inventory did not preserve its installed manual identity.")
        }
        try data.write(to: directory.appendingPathComponent("discovery-v1.json"), options: .atomic)
    }

    private func quotedShellWord(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct WorkflowTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct FixtureManualLocation: Codable {
    let source: URL
    let root: URL
    let name: String
    let section: String
    let language: String
    let stamp: String
}

private struct FixtureManualPage: Codable {
    let name: String
    let section: String
    let source: URL
    let root: URL
    let fingerprint: String
    let language: String
    let locations: [FixtureManualLocation]
    let description: String
    let indexed: Bool
    let problem: String?
}

private struct FixtureLibraryScan: Codable {
    let pages: [FixtureManualPage]
    let coverage: [FixtureSourceCoverage]
    let cancelled: Bool
}

private struct FixtureSourceCoverage: Codable {
    let root: URL
    let count: Int
    let directories: Int
    let files: Int
    let completed: Bool
    let issues: [FixtureDiscoveryIssue]
}

private struct FixtureDiscoveryIssue: Codable {
    let path: String
    let kind: String
    let reason: String
}
