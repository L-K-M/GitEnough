import AppKit
import SwiftUI

extension View {
    /// Give a clicked row's native list the keyboard. On macOS, SwiftUI's
    /// logical focus alone can leave the window as the actual first responder.
    /// Change the request from a selection Binding setter, keeping restored or
    /// automatically chosen selections from taking focus from another control.
    func nativeListRowFocus(isSelected: Bool = false, focusRequest: UUID? = nil) -> some View {
        modifier(NativeListRowFocus(isSelected: isSelected, focusRequest: focusRequest))
    }
}

private struct NativeListRowFocus: ViewModifier {
    let isSelected: Bool
    let focusRequest: UUID?
    @State private var target = ListFocusTarget()

    func body(content: Content) -> some View {
        content
            .background(ListFocusAnchor(target: target).accessibilityHidden(true))
            .simultaneousGesture(TapGesture().onEnded {
                // Apply after the native selection event has finished, so it
                // cannot replace the responder we just installed.
                DispatchQueue.main.async { target.focusList() }
            })
            .onChange(of: focusRequest) { _, request in
                guard request != nil && isSelected else { return }
                DispatchQueue.main.async { target.focusList() }
            }
    }
}

private final class ListFocusTarget {
    weak var anchor: NSView?

    func focusList() {
        var ancestor = anchor?.superview
        while let view = ancestor {
            // NSOutlineView is an NSTableView subclass. NSCollectionView covers
            // lists hosted by a collection rather than an outline/table.
            if view is NSTableView || view is NSCollectionView {
                view.window?.makeFirstResponder(view)
                return
            }
            ancestor = view.superview
        }
    }

}

private struct ListFocusAnchor: NSViewRepresentable {
    let target: ListFocusTarget

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        target.anchor = view
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        target.anchor = nsView
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
