import AppKit
import SwiftUI

/// The composer remains an ordinary plain-text NSTextView. Its own undo manager
/// keeps native typing and generated replacements in the same responder chain.
struct CommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let controller: CommitMessageUndoController
    let onEditingBegan: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronizeText()
        context.coordinator.focusIfRequested()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitMessageEditor
        weak var textView: CommitTextView?
        private var lastFocusRequest: UUID
        private var isApplyingReplacement = false
        private var compositionBase: String?
        private var compositionFinishScheduled = false
        private weak var observedWindow: NSWindow?
        private var windowObservers: [NSObjectProtocol] = []
        private var isPresentingSheet = false
        private lazy var textUndoManager = CurrentDraftUndoManager(isCurrent: { [weak self] in
            guard let self, let textView = self.textView else { return false }
            return !textView.hasMarkedText() && self.parent.text == textView.string
        }, didApply: { [weak self] in
            guard let self, let textView = self.textView else { return }
            self.parent.text = textView.string
            self.parent.controller.refresh()
        })

        init(_ parent: CommitMessageEditor) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        deinit {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            let view = CommitTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 76))
            view.isRichText = false
            view.allowsUndo = true
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
            view.textContainerInset = NSSize(width: 4, height: 6)
            view.font = .preferredFont(forTextStyle: .body)
            view.textColor = .textColor
            view.backgroundColor = .textBackgroundColor
            view.isContinuousSpellCheckingEnabled = true
            view.isAutomaticSpellingCorrectionEnabled = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.setAccessibilityLabel("Commit message")
            view.string = parent.text
            view.delegate = self
            view.onCompositionBegan = { [weak self] in self?.beginComposition() }
            view.onCompositionEnded = { [weak self] in self?.scheduleCompositionFinish() }
            view.onMovedToWindow = { [weak self] in
                self?.observeWindow()
                self?.focusIfRequested()
                self?.parent.controller.refresh()
            }
            view.onResponderChanged = { [weak self] in self?.parent.controller.refresh() }
            textView = view
            parent.controller.coordinator = self
            scrollView.documentView = view
            parent.controller.refresh()
            return scrollView
        }

        func undoManager(for view: NSTextView) -> UndoManager? { textUndoManager }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            if !isApplyingReplacement { parent.onEditingBegan() }
            return true
        }

        func textDidChange(_ notification: Notification) {
            defer { parent.controller.refresh() }
            guard let view = textView, !view.hasMarkedText() else { return }
            if compositionBase != nil && !isApplyingReplacement {
                scheduleCompositionFinish()
            } else {
                parent.text = view.string
            }
        }

        func synchronizeText() {
            defer { parent.controller.refresh() }
            guard let view = textView, view.string != parent.text, !view.hasMarkedText(),
                  compositionBase == nil else { return }
            // Another window or a successful commit changed the shared draft.
            // A native undo operation from the old text must not replay into it.
            textUndoManager.removeAllActions()
            let selection = view.selectedRange()
            view.string = parent.text
            let location = min(selection.location, (parent.text as NSString).length)
            view.setSelectedRange(NSRange(location: location, length: 0))
        }

        func focusIfRequested() {
            guard lastFocusRequest != parent.focusRequest, let view = textView,
                  let window = view.window else { return }
            lastFocusRequest = parent.focusRequest
            window.makeFirstResponder(view)
        }

        var undoState: CommitMessageUndoState {
            CommitMessageUndoState(isFocused: textView.map {
                guard let window = $0.window else { return false }
                return window.isKeyWindow && !isPresentingSheet && window.attachedSheet == nil
                    && window.firstResponder === $0
            } ?? false,
                                   canUndo: textUndoManager.canUndo, canRedo: textUndoManager.canRedo,
                                   undoTitle: textUndoManager.undoMenuItemTitle,
                                   redoTitle: textUndoManager.redoMenuItemTitle)
        }

        private func observeWindow() {
            guard observedWindow !== textView?.window else { return }
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
            observedWindow = textView?.window
            isPresentingSheet = observedWindow?.attachedSheet != nil
            guard let window = observedWindow else { return }
            // A sheet keeps the parent's first responder. Remove our menu
            // replacement while another window owns the keyboard so the sheet's
            // native text field receives Undo, then restore it on return.
            let notifications: [Notification.Name] = [NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification,
                NSWindow.didEndSheetNotification]
            windowObservers = notifications.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self, weak window] notification in
                    guard let self, let window, notification.object as? NSWindow === window else { return }
                    if name == NSWindow.willBeginSheetNotification { self.isPresentingSheet = true }
                    if name == NSWindow.didEndSheetNotification { self.isPresentingSheet = false }
                    self.parent.controller.refresh()
                }
            }
        }

        func undo() { textUndoManager.undo() }
        func redo() { textUndoManager.redo() }

        func finishEditing() {
            guard let view = textView else { return }
            if view.hasMarkedText() { view.unmarkText() }
            finishComposition()
            synchronizeText()
        }

        func applyGenerated(_ replacement: CommitMessageReplacement) {
            guard let view = textView, !view.hasMarkedText(),
                  parent.text == replacement.previousMessage,
                  let message = replacement.replacing(view.string) else { return }
            replaceText(message, actionName: "Generate Commit Message")
        }

        private func beginComposition() {
            guard compositionBase == nil else { return }
            compositionBase = parent.text
            parent.onEditingBegan()
        }

        private func scheduleCompositionFinish() {
            guard !compositionFinishScheduled else { return }
            compositionFinishScheduled = true
            // The input method's native undo group must finish before an
            // external draft is reconciled into a new undoable edit.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.compositionFinishScheduled = false
                self.finishComposition()
            }
        }

        private func finishComposition() {
            guard let base = compositionBase, let view = textView, !view.hasMarkedText() else { return }
            compositionBase = nil
            let composed = view.string
            if parent.text != base && parent.text != composed {
                // Keep marked input intact until it finishes. If another window
                // edited meanwhile, the completed composition is the last edit;
                // Undo restores that newer shared message instead of stale text.
                textUndoManager.removeAllActions()
                view.string = parent.text
                replaceText(composed, actionName: "Edit Commit Message")
            } else {
                parent.text = composed
            }
        }

        private func replaceText(_ message: String, actionName: String) {
            guard let view = textView else { return }
            view.breakUndoCoalescing()
            textUndoManager.beginUndoGrouping()
            isApplyingReplacement = true
            view.insertText(message, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
            isApplyingReplacement = false
            textUndoManager.setActionName(actionName)
            textUndoManager.endUndoGrouping()
            view.breakUndoCoalescing()
            parent.controller.refresh()
        }
    }
}

/// Only the initiating editor receives an accepted generation's undo record.
/// Keeping the editor weak lets a closed window finish generation safely.
struct CommitMessageUndoState: Equatable {
    var isFocused = false
    var canUndo = false
    var canRedo = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"
}

final class CommitMessageUndoController: ObservableObject {
    weak var coordinator: CommitMessageEditor.Coordinator?
    @Published private(set) var state = CommitMessageUndoState()
    private var refreshScheduled = false

    func applyGenerated(_ replacement: CommitMessageReplacement) {
        coordinator?.applyGenerated(replacement)
    }

    func finishEditing() { coordinator?.finishEditing() }
    func undo() {
        guard coordinator?.undoState.isFocused == true else { return }
        coordinator?.undo()
    }
    func redo() {
        guard coordinator?.undoState.isFocused == true else { return }
        coordinator?.redo()
    }

    func refresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Focus can change inside NSViewRepresentable.updateNSView. Publish
        // after that update instead of mutating SwiftUI state during layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let current = self.coordinator?.undoState ?? CommitMessageUndoState()
            if self.state != current { self.state = current }
        }
    }
}

private final class CurrentDraftUndoManager: UndoManager {
    private let isCurrent: () -> Bool
    private let didApply: () -> Void

    init(isCurrent: @escaping () -> Bool, didApply: @escaping () -> Void) {
        self.isCurrent = isCurrent
        self.didApply = didApply
        super.init()
    }

    override var canUndo: Bool { isCurrent() && super.canUndo }
    override var canRedo: Bool { isCurrent() && super.canRedo }
    override func undo() {
        guard isCurrent() else { return }
        super.undo()
        didApply()
    }
    override func redo() {
        guard isCurrent() else { return }
        super.redo()
        didApply()
    }
}

final class CommitTextView: NSTextView {
    var onCompositionBegan: (() -> Void)?
    var onCompositionEnded: (() -> Void)?
    var onMovedToWindow: (() -> Void)?
    var onResponderChanged: (() -> Void)?
    private weak var validatedUndoItem: NSMenuItem?
    private weak var validatedRedoItem: NSMenuItem?

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let menuItem = item as? NSMenuItem, let enabled = validateUndoItem(menuItem) {
            return enabled
        }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return validateUndoItem(menuItem) ?? super.validateMenuItem(menuItem)
    }

    private func validateUndoItem(_ item: NSMenuItem) -> Bool? {
        guard let manager = undoManager else { return nil }
        if item.action == NSSelectorFromString("undo:") {
            validatedUndoItem = item
            item.title = manager.undoMenuItemTitle
            return manager.canUndo
        }
        if item.action == NSSelectorFromString("redo:") {
            validatedRedoItem = item
            item.title = manager.redoMenuItemTitle
            return manager.canRedo
        }
        return nil
    }

    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused { onResponderChanged?() }
        return focused
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let manager = undoManager {
            // These menu items are shared by every focused control. Leave the
            // generic titles ready for the next responder's own validation.
            validatedUndoItem?.title = manager.undoMenuTitle(forUndoActionName: "")
            validatedRedoItem?.title = manager.redoMenuTitle(forUndoActionName: "")
        }
        if resigned { onResponderChanged?() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMovedToWindow?()
    }

    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() { onCompositionBegan?() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionEnded?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasMarked = hasMarkedText()
        super.insertText(insertString, replacementRange: replacementRange)
        if wasMarked && !hasMarkedText() { onCompositionEnded?() }
    }
}
