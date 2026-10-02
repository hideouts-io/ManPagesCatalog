import SwiftUI

@main
struct ManPageCatalogApp: App {
    @NSApplicationDelegateAdaptor(CatalogApplicationDelegate.self) private var applicationDelegate
    @AppStorage("manualAppearance") private var appearance = "system"
    @StateObject private var library: LibraryStore
    @StateObject private var reader = ManualReader()
    @StateObject private var terminal = TerminalSession()

    init() {
        let defaults = UserDefaults.standard
        let directory: URL
        if let override = defaults.string(forKey: "libraryDirectory"), !override.isEmpty {
            directory = URL(fileURLWithPath: override)
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ManPagesCatalog")
        }
        _library = StateObject(wrappedValue: LibraryStore(directory: directory, defaults: defaults))
    }
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Man Page Catalog", id: "browser") {
            ContentView().preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .environmentObject(library)
                .environmentObject(reader)
                .environmentObject(terminal)
                .onAppear { applicationDelegate.terminal = terminal }
        }
        .commands {
            CommandMenu("Find") {
                Button("Search All Manuals") {
                    openWindow(id: "browser")
                    NotificationCenter.default.post(name: .searchCommands, object: nil)
                }.keyboardShortcut("k", modifiers: .command)
                Button("Find in Page") {
                    NotificationCenter.default.post(name: .findInPage, object: nil)
                }.keyboardShortcut("f", modifiers: .command)
                Button("Next Match") {
                    NotificationCenter.default.post(name: .nextMatch, object: nil)
                }.keyboardShortcut("g", modifiers: .command)
                Button("Previous Match") {
                    NotificationCenter.default.post(name: .previousMatch, object: nil)
                }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Sources") {
                    NotificationCenter.default.post(name: .reloadCatalog, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        Window("Scan & Sources", id: "sources") {
            SourcesView().environmentObject(library)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }.windowResizability(.contentSize)
    }
}

@MainActor
final class CatalogApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var terminal: TerminalSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminal, terminal.active else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "End the terminal session and quit?"
        alert.informativeText = "The shell and its attached jobs will stop. Unsaved work in those programs can be lost."
        alert.addButton(withTitle: "End Session & Quit").setAccessibilityIdentifier("confirmTerminalQuit")
        alert.addButton(withTitle: "Cancel").setAccessibilityIdentifier("cancelTerminalQuit")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        terminal.shutdown()
        return terminal.active ? .terminateCancel : .terminateNow
    }
}

extension Notification.Name {
    static let searchCommands = Notification.Name("searchCommands")
    static let findInPage = Notification.Name("findInPage")
    static let nextMatch = Notification.Name("nextMatch")
    static let previousMatch = Notification.Name("previousMatch")
    static let reloadCatalog = Notification.Name("reloadCatalog")
}
