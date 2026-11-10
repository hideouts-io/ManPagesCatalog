import Foundation
import Combine

/// Owns the background catalog operation independently of the management window.
@MainActor
final class CatalogGenerator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var progress: CatalogProgress?
    private var task: Task<Void, Never>?

    func generate(output: URL, store: CatalogStore, authority: ManualSourceAuthority) {
        guard !isRunning else { return }
        let access = authority.snapshot()
        begin(status: "Discovering and rendering manuals…")
        task = Task {
            do {
                let environment = ProcessInfo.processInfo.environment
                let roots = try await manualRoots(environment: environment)
                try authority.requireCurrent(access)
                try await generateCatalog(directory: output, roots: roots, environment: environment, authority: authority) { progress in
                    await self.update(progress: progress, access: access, authority: authority)
                }
                try authority.requireCurrent(access)
                finish(output: output, store: store)
            } catch is CancellationError {
                cancelled()
            } catch {
                failed(error: error)
            }
        }
    }

    func refresh(output: URL, store: CatalogStore, authority: ManualSourceAuthority) {
        guard !isRunning else { return }
        let access = authority.snapshot()
        begin(status: "Refreshing descriptions; PDFs stay unchanged…")
        task = Task {
            do {
                try await refreshCatalogMetadata(directory: output, environment: ProcessInfo.processInfo.environment, authority: authority) { progress in
                    await self.update(progress: progress, access: access, authority: authority)
                }
                try authority.requireCurrent(access)
                finish(output: output, store: store)
            } catch is CancellationError {
                cancelled()
            } catch {
                failed(error: error)
            }
        }
    }

    func stop() {
        status = "Stopping formatter…"
        task?.cancel()
    }

    private func begin(status: String) {
        errorMessage = nil
        progress = nil
        self.status = status
        isRunning = true
    }

    private func update(progress: CatalogProgress, access: ManualSourceAccess, authority: ManualSourceAuthority) {
        guard authority.snapshot().generation == access.generation else { return }
        self.progress = progress
    }

    private func finish(output: URL, store: CatalogStore) {
        isRunning = false
        status = "Catalog ready."
        store.outputDir = output
    }

    private func cancelled() {
        isRunning = false
        status = "Stopped. Existing catalog metadata is unchanged; completed PDFs remain in the output folder."
    }

    private func failed(error: Error) {
        isRunning = false
        status = "Catalog operation failed."
        errorMessage = "\(error.localizedDescription)\nThe existing catalog metadata is unchanged."
    }
}
