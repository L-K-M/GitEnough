import SwiftUI
import AppKit

/// NSSearchField supplies the system search role, cancel button, focus ring,
/// text editing, and accessibility behavior instead of imitating a search field.
struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Subject, author, email, hash, or ref"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setAccessibilityLabel("Search commit history")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest,
           let window = field.window {
            context.coordinator.lastFocusRequest = focusRequest
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: HistorySearchField
        var lastFocusRequest: Int

        init(_ parent: HistorySearchField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        @objc func searchChanged(_ field: NSSearchField) {
            parent.text = field.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
