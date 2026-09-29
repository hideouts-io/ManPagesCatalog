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

    func generate(output: URL, store: CatalogStore) {
        guard !isRunning else { return }
        begin(status: "Discovering and rendering manuals…")
        task = Task {
            do {
                let environment = ProcessInfo.processInfo.environment
                let roots = try await manualRoots(environment: environment)
                try await generateCatalog(directory: output, roots: roots, environment: environment) { progress in
                    await self.update(progress: progress)
                }
                finish(output: output, store: store)
            } catch is CancellationError {
                cancelled()
            } catch {
                failed(error: error)
            }
        }
    }

    func refresh(output: URL, store: CatalogStore) {
        guard !isRunning else { return }
        begin(status: "Refreshing descriptions; PDFs stay unchanged…")
        task = Task {
            do {
                try await refreshCatalogMetadata(directory: output, environment: ProcessInfo.processInfo.environment) { progress in
                    await self.update(progress: progress)
                }
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

    private func update(progress: CatalogProgress) { self.progress = progress }

    private func finish(output: URL, store: CatalogStore) {
        isRunning = false
        status = "Catalog ready."
        store.outputDir = output
    }

    private func cancelled() {
        isRunning = false
        status = "Stopped. Existing catalog metadata is unchanged; completed PDFs can be reused."
    }

    private func failed(error: Error) {
        isRunning = false
        status = "Catalog operation failed."
        errorMessage = "\(error.localizedDescription)\nThe existing catalog metadata is unchanged."
    }
}
