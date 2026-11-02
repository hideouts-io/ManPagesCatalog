import AppKit
import Darwin
import UniformTypeIdentifiers

private struct ReproductionOptions {
    let log: URL
    let identifier: String

    static func parse(_ arguments: [String]) throws -> ReproductionOptions {
        guard arguments.count == 4, arguments[0] == "--log-path", arguments[2] == "--identifier",
              arguments[1].hasPrefix("/"), !arguments[3].isEmpty else {
            throw ManualToolError(message: "Usage: ExportPanelReproduction --log-path /absolute/new-log.ndjson --identifier coverageExportPanel")
        }
        return ReproductionOptions(log: URL(fileURLWithPath: arguments[1]), identifier: arguments[3])
    }
}

private struct WindowSnapshot: Encodable {
    let number: Int
    let title: String
    let key: Bool
    let main: Bool
    let visible: Bool
}

private struct PanelSnapshot: Encodable {
    let window: WindowSnapshot
    let identifier: String?
    let name: String
    let directory: URL?
    let destination: URL?
    let allowedContentTypes: [String]
    let currentContentType: String?
    let showsContentTypes: Bool?
    let allowsOtherFileTypes: Bool
    let canCreateDirectories: Bool
    let extensionHidden: Bool
    let prompt: String?
}

private struct ReproductionEvent: Encodable {
    let schemaVersion: Int
    let event: String
    let time: Date
    let uptimeSeconds: Double
    let processIdentifier: Int32
    let bundle: URL
    let executable: URL?
    let arguments: [String]
    let applicationActive: Bool
    let keyWindow: WindowSnapshot?
    let mainWindow: WindowSnapshot?
    let owner: WindowSnapshot
    let attachedSheet: WindowSnapshot?
    let panel: PanelSnapshot?
    let selectedDestination: URL?
    let error: String?
}

@MainActor
private func windowSnapshot(_ window: NSWindow) -> WindowSnapshot {
    WindowSnapshot(number: window.windowNumber, title: window.title, key: window.isKeyWindow,
                   main: window.isMainWindow, visible: window.isVisible)
}

@MainActor
private func panelSnapshot(_ panel: NSSavePanel) -> PanelSnapshot {
    let currentContentType: String?
    let showsContentTypes: Bool?
    if #available(macOS 15, *) {
        currentContentType = panel.currentContentType?.identifier
        showsContentTypes = panel.showsContentTypes
    } else {
        currentContentType = nil
        showsContentTypes = nil
    }
    return PanelSnapshot(window: windowSnapshot(panel), identifier: panel.identifier?.rawValue,
                         name: panel.nameFieldStringValue, directory: panel.directoryURL, destination: panel.url,
                         allowedContentTypes: panel.allowedContentTypes.map(\.identifier),
                         currentContentType: currentContentType, showsContentTypes: showsContentTypes,
                         allowsOtherFileTypes: panel.allowsOtherFileTypes,
                         canCreateDirectories: panel.canCreateDirectories,
                         extensionHidden: panel.isExtensionHidden, prompt: panel.prompt)
}

/// Filesystem diagnostic interface: exclusively creates one owned, bounded log and synchronizes each event.
private final class ReproductionLog {
    private let handle: FileHandle
    private let path: String
    private var bytes: Int = 0

    init(url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var metadata = stat()
        guard lstat(parent.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(), access(parent.path, W_OK) == 0 else {
            throw ManualToolError(message: "Cannot create reproduction log \(url.path): its parent must be an existing writable directory owned by UID \(geteuid()) (errno \(errno)).")
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            throw ManualToolError(message: "Cannot exclusively create new reproduction log \(url.path): \(String(cString: strerror(code))) (errno \(code)). Existing logs are never replaced.")
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        path = url.path
    }

    func append(_ event: ReproductionEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var record = try encoder.encode(event)
        record.append(0x0A)
        guard bytes + record.count <= 2 * 1024 * 1024 else {
            throw ManualToolError(message: "Cannot append diagnostics to \(path): the owned log reached its 2 MiB limit. Relaunch with a new log path.")
        }
        try handle.write(contentsOf: record)
        try handle.synchronize()
        bytes += record.count
    }
}

/// AppKit interface only. The production helper owns all Save-panel behavior and validation.
@MainActor
private final class ReproductionApplication: NSObject, NSApplicationDelegate {
    private let options: ReproductionOptions
    private let log: ReproductionLog
    private let owner: NSWindow
    private let status: NSTextField

    init(options: ReproductionOptions, log: ReproductionLog) {
        self.options = options
        self.log = log
        owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 240),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        status = NSTextField(wrappingLabelWithString: "Choose JSON or PDF. Use the native Save sheet normally. No selected file is written.")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        owner.title = "ManPagesCatalog Native Save Reproduction"
        owner.setAccessibilityIdentifier("reproOwner")
        status.setAccessibilityIdentifier("reproStatus")
        let controls = NSStackView(views: [
            button(title: "Choose JSON Destination", identifier: "reproJSON", action: #selector(exportJSON(_:))),
            button(title: "Choose PDF Destination", identifier: "reproPDF", action: #selector(exportPDF(_:))),
            button(title: "Capture Window Snapshot", identifier: "reproSnapshot", action: #selector(captureSnapshot(_:)))
        ])
        controls.orientation = .horizontal
        controls.spacing = 12
        let help = NSTextField(wrappingLabelWithString: "Capture Window Snapshot records state outside a Save sheet. Launch, sheet attachment and completion are recorded automatically. Cancel and reopen to compare restored state. No Save-panel settings are changed.")
        let content = NSStackView(views: [controls, help, status])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        owner.contentView = content
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Native Save Reproduction", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApplication.shared.mainMenu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(sheetWillBegin(_:)), name: NSWindow.willBeginSheetNotification, object: owner)
        owner.center()
        owner.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        record(event: "launched", destination: nil, error: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func button(title: String, identifier: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.setAccessibilityIdentifier(identifier)
        return control
    }

    @objc private func exportJSON(_ sender: NSButton) {
        present(filename: "ManPages-scan-coverage.json", contentType: .json,
                title: "Export Scan Coverage", identifier: options.identifier)
    }

    @objc private func exportPDF(_ sender: NSButton) {
        present(filename: "ManPages-manual.pdf", contentType: .pdf,
                title: "Export Manual PDF", identifier: options.identifier + ".pdf")
    }

    private func present(filename: String, contentType: UTType, title: String, identifier: String) {
        Task { @MainActor in
            record(event: "before-\(contentType.identifier)", destination: nil, error: nil)
            do {
                let destination = try await chooseExportDestination(window: owner, filename: filename,
                    contentType: contentType, title: title, identifier: identifier)
                status.stringValue = destination.map { "Selected \($0.path). The reproduction did not write this file." } ?? "Cancelled. No file was written."
                record(event: destination == nil ? "cancelled" : "selected", destination: destination, error: nil)
            } catch {
                status.stringValue = error.localizedDescription
                record(event: "export-error", destination: nil, error: error.localizedDescription)
            }
        }
    }

    @objc private func sheetWillBegin(_ notification: Notification) {
        record(event: "sheet-will-begin", destination: nil, error: nil)
        // A single queued read observes attachment after the initiating AppKit call returns.
        DispatchQueue.main.async {
            self.record(event: "sheet-attached", destination: nil, error: nil)
        }
    }

    @objc private func captureSnapshot(_ sender: NSObject) {
        record(event: "manual-snapshot", destination: nil, error: nil)
    }

    private func record(event: String, destination: URL?, error: String?) {
        let application = NSApplication.shared
        let entry = ReproductionEvent(schemaVersion: 1, event: event, time: Date(),
            uptimeSeconds: ProcessInfo.processInfo.systemUptime, processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundle: Bundle.main.bundleURL, executable: Bundle.main.executableURL, arguments: ProcessInfo.processInfo.arguments,
            applicationActive: application.isActive, keyWindow: application.keyWindow.map(windowSnapshot),
            mainWindow: application.mainWindow.map(windowSnapshot), owner: windowSnapshot(owner),
            attachedSheet: owner.attachedSheet.map(windowSnapshot),
            panel: (owner.attachedSheet as? NSSavePanel).map(panelSnapshot), selectedDestination: destination, error: error)
        do { try log.append(entry) }
        catch {
            status.stringValue = "Diagnostic recording failed: \(error.localizedDescription)"
            fputs("Diagnostic recording failed: \(error.localizedDescription)\n", stderr)
        }
    }
}

@main
private struct ExportPanelReproduction {
    @MainActor
    static func main() {
        do {
            let options = try ReproductionOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let log = try ReproductionLog(url: options.log)
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = ReproductionApplication(options: options, log: log)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            fputs("Native Save reproduction could not start: \(error.localizedDescription)\n", stderr)
            exit(64)
        }
    }
}
