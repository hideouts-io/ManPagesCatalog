import SwiftUI

@main
struct ManPageCatalogApp: App {
    @StateObject private var store = CatalogStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Catalog") {
                    store.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
