import SwiftUI
import AppKit

/// Shell text needs literal typing and pasting; SwiftUI's TextEditor inherits smart substitutions.
struct CommandDraftEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 90))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let editor = context.coordinator.editor
        editor.frame = NSRect(origin: .zero, size: scroll.contentSize)
        editor.minSize = NSSize(width: 0, height: 76)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.size = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.isEditable = true
        editor.isSelectable = true
        editor.setAccessibilityEnabled(true)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.usesFontPanel = false
        editor.allowsUndo = true
        editor.smartInsertDeleteEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.setAccessibilityIdentifier("commandDraft")
        editor.setAccessibilityLabel("Editable command draft")
        editor.string = text
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let editor = context.coordinator.editor
        if editor.string != text {
            editor.string = text
            // A replaced draft must not reuse undo operations from the prior draft.
            context.coordinator.editorUndoManager.removeAllActions()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.editor.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandDraftEditor
        let editor = NSTextView(frame: .zero)
        let editorUndoManager = UndoManager()

        init(parent: CommandDraftEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            if parent.text != editor.string { parent.text = editor.string }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }
    }
}
