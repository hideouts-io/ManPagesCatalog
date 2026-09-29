import SwiftUI

@main
struct ManPageCatalogApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var reader = ManualReader()

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
            ContentView()
                .environmentObject(library)
                .environmentObject(reader)
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
        Window("Sources & Index", id: "sources") {
            SourcesView().environmentObject(library)
        }.windowResizability(.contentSize)
    }
}

extension Notification.Name {
    static let searchCommands = Notification.Name("searchCommands")
    static let findInPage = Notification.Name("findInPage")
    static let nextMatch = Notification.Name("nextMatch")
    static let previousMatch = Notification.Name("previousMatch")
    static let reloadCatalog = Notification.Name("reloadCatalog")
}
