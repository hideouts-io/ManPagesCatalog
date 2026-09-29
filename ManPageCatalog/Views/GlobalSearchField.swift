import SwiftUI
import AppKit

/// AppKit owns toolbar keyboard focus, including transfers from the WebKit Find field.
struct GlobalSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search commands and descriptions…"
        field.setAccessibilityIdentifier("globalCommandSearch")
        field.setAccessibilityLabel("Search commands and descriptions")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: GlobalSearchField
        var lastFocus: UUID?
        init(parent: GlobalSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
