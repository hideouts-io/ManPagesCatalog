import AppKit
import UniformTypeIdentifiers

/// Presents an export sheet on its originating window without entering an application-modal loop.
@MainActor
func chooseExportDestination(window: NSWindow, filename: String, contentType: UTType, title: String, identifier: String) async throws -> URL? {
    guard window.attachedSheet == nil else {
        throw ManualToolError(message: "Cannot open \(title): this window already has an open dialog. Finish or cancel that dialog, then try exporting again.")
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [contentType]
    panel.nameFieldStringValue = filename
    panel.title = title
    panel.prompt = "Export"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.identifier = NSUserInterfaceItemIdentifier(identifier)
    panel.setAccessibilityIdentifier(identifier)
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
        panel.beginSheetModal(for: window) { response in
            switch response {
            case .cancel:
                continuation.resume(returning: nil)
            case .OK:
                guard let destination = panel.url, destination.isFileURL else {
                    continuation.resume(throwing: ManualToolError(message: "\(title) did not return a local file destination for \(filename). Choose a file in a writable folder and try again."))
                    return
                }
                continuation.resume(returning: destination)
            default:
                continuation.resume(throwing: ManualToolError(message: "\(title) returned unexpected dialog response \(response.rawValue) for \(filename). Close the dialog and try exporting again."))
            }
        }
    }
}
