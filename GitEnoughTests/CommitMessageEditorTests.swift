#if canImport(AppKit) && !SWIFT_PACKAGE
import AppKit
import SwiftUI
import XCTest
@testable import GitEnough

@MainActor
final class CommitMessageEditorTests: XCTestCase {
    func testGeneratedReplacementHasNamedNativeUndoAndRedo() throws {
        let fixture = try EditorFixture("Original draft 🐾\n\nKeep this explanation.")
        let original = fixture.draft.value
        fixture.generate("fix: Use the generated draft")

        XCTAssertEqual(fixture.view.string, "fix: Use the generated draft")
        XCTAssertEqual(fixture.undo.undoActionName, "Generate Commit Message")
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft.value, original)
        XCTAssertEqual(fixture.view.string, original)
        XCTAssertEqual(fixture.undo.redoActionName, "Generate Commit Message")
        fixture.undo.redo()
        XCTAssertEqual(fixture.draft.value, "fix: Use the generated draft")
    }

    func testNamedUndoSurvivesTheDefaultEventLoopGrouping() throws {
        let fixture = try EditorFixture("Original", groupsByEvent: true)
        fixture.generate("Generated")
        let eventEnded = expectation(description: "Native event undo group closed")
        _ = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: false) { _ in eventEnded.fulfill() }
        wait(for: [eventEnded], timeout: 3)

        XCTAssertEqual(fixture.undo.undoMenuItemTitle, "Undo Generate Commit Message")
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft.value, "Original")
        XCTAssertEqual(fixture.undo.redoMenuItemTitle, "Redo Generate Commit Message")
        fixture.undo.redo()
        XCTAssertEqual(fixture.draft.value, "Generated")
    }

    func testNativeMenuValidationNamesGeneratedUndoAndRedo() throws {
        let fixture = try EditorFixture("Original")
        fixture.generate("Generated")
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(fixture.view.validateUserInterfaceItem(undoItem))
        XCTAssertEqual(undoItem.title, fixture.undo.undoMenuItemTitle)
        fixture.undo.undo()

        let redoItem = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        XCTAssertTrue(fixture.view.validateMenuItem(redoItem))
        XCTAssertEqual(redoItem.title, fixture.undo.redoMenuItemTitle)
    }

    func testOtherNativeEditingMenuValidationIsPreserved() throws {
        let fixture = try EditorFixture("Copy this")
        fixture.view.setSelectedRange(NSRange(location: 0, length: 4))
        let copyItem = NSMenuItem(title: "Copy Selection", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        XCTAssertTrue(fixture.view.validateMenuItem(copyItem))
        XCTAssertEqual(copyItem.title, "Copy Selection")
    }

    func testNamedMenuTitlesAreClearedWhenAnotherControlTakesFocus() throws {
        _ = NSApplication.shared
        let fixture = try EditorFixture("Original")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = fixture.scrollView
        XCTAssertTrue(window.makeFirstResponder(fixture.view))
        fixture.generate("Generated")
        let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(fixture.view.validateMenuItem(item))
        XCTAssertEqual(item.title, "Undo Generate Commit Message")

        XCTAssertTrue(window.makeFirstResponder(window))
        XCTAssertEqual(item.title, fixture.undo.undoMenuTitle(forUndoActionName: ""))
    }

    func testCommandBridgeTracksNativeFocusAndNamedUndoState() async throws {
        _ = NSApplication.shared
        let fixture = try EditorFixture("Original")
        let window = KeyStateWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                    styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = fixture.scrollView
        window.setKeyState(true)
        XCTAssertTrue(window.makeFirstResponder(fixture.view))
        fixture.generate("Generated")
        await drainMain()
        XCTAssertTrue(fixture.controller.state.isFocused)
        XCTAssertEqual(fixture.controller.state.undoTitle, "Undo Generate Commit Message")
        XCTAssertTrue(fixture.controller.state.canUndo)

        fixture.controller.undo()
        await drainMain()
        XCTAssertEqual(fixture.draft.value, "Original")
        XCTAssertEqual(fixture.controller.state.redoTitle, "Redo Generate Commit Message")

        XCTAssertTrue(window.makeFirstResponder(window))
        await drainMain()
        XCTAssertFalse(fixture.controller.state.isFocused)
        fixture.controller.redo()
        XCTAssertEqual(fixture.draft.value, "Original",
                       "A stale command callback must not edit a field that no longer owns focus")
    }

    func testResigningKeyWindowDropsTheComposerCommandBridgeWithoutChangingItsDraft() async throws {
        _ = NSApplication.shared
        let fixture = try EditorFixture("Original")
        let parent = KeyStateWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                    styleMask: .titled, backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        parent.contentView = fixture.scrollView
        parent.setKeyState(true)
        XCTAssertTrue(parent.makeFirstResponder(fixture.view))
        fixture.generate("Generated")
        await drainMain()
        XCTAssertTrue(fixture.controller.state.isFocused)

        parent.setKeyState(false)
        await drainMain()
        XCTAssertTrue(parent.firstResponder === fixture.view,
                      "A parent keeps its first responder when a sheet or another window takes the keyboard")
        XCTAssertFalse(fixture.controller.state.isFocused)
        fixture.controller.undo()
        XCTAssertEqual(fixture.draft.value, "Generated",
                       "Undo in a sheet must not change the composer behind it")

        parent.setKeyState(true)
        await drainMain()
        XCTAssertTrue(fixture.controller.state.isFocused)
    }

    func testSheetLifecycleDropsComposerCommandsBeforeTheSheetIsAttached() async throws {
        _ = NSApplication.shared
        let fixture = try EditorFixture("Original")
        let window = KeyStateWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                    styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = fixture.scrollView
        window.setKeyState(true)
        XCTAssertTrue(window.makeFirstResponder(fixture.view))
        fixture.generate("Generated")
        await drainMain()
        XCTAssertTrue(fixture.controller.state.isFocused)

        // AppKit announces a sheet before attachedSheet necessarily changes,
        // and a SwiftUI sheet may leave the parent key and first responder intact.
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: window)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.firstResponder === fixture.view)
        fixture.controller.undo()
        XCTAssertEqual(fixture.draft.value, "Generated")
        await drainMain()
        XCTAssertFalse(fixture.controller.state.isFocused,
                       "The custom command group must disappear so the sheet uses native Undo")

        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        await drainMain()
        XCTAssertTrue(fixture.controller.state.isFocused)
        fixture.controller.undo()
        XCTAssertEqual(fixture.draft.value, "Original")
    }

    private func drainMain() async {
        let refreshed = expectation(description: "Native focus and undo state published")
        DispatchQueue.main.async { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 3)
    }

    func testTypingAfterGenerationUndoesBeforeTheGeneratedReplacement() throws {
        let fixture = try EditorFixture("Original draft")
        fixture.generate("Generated")
        fixture.undo.beginUndoGrouping()
        fixture.view.insertText(" and manual typing",
                                replacementRange: NSRange(location: 9, length: 0))
        fixture.undo.endUndoGrouping()
        fixture.view.breakUndoCoalescing()

        fixture.undo.undo()
        XCTAssertEqual(fixture.draft.value, "Generated")
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft.value, "Original draft")
    }

    func testAStaleEditorCannotUndoOverANewerSharedDraft() throws {
        let fixture = try EditorFixture("Original draft")
        fixture.generate("Generated")
        fixture.draft.value = "A newer shared draft"

        XCTAssertFalse(fixture.undo.canUndo)
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft.value, "A newer shared draft")
        fixture.coordinator.synchronizeText()
        XCTAssertEqual(fixture.view.string, "A newer shared draft")
        XCTAssertFalse(fixture.undo.canUndo)
    }

    func testOnlyTheInitiatingEditorRegistersTheGeneratedEdit() throws {
        let draft = Draft("Original")
        let first = try EditorFixture(draft)
        let second = try EditorFixture(draft)
        first.generate("Generated")
        second.coordinator.synchronizeText()

        XCTAssertTrue(first.undo.canUndo)
        XCTAssertFalse(second.undo.canUndo)
        XCTAssertFalse(first.undo === second.undo)
        first.undo.undo()
        second.coordinator.synchronizeText()
        XCTAssertEqual(second.view.string, "Original")
    }

    func testFinishingEditingCommitsMarkedInputBeforeARepositoryAction() throws {
        let fixture = try EditorFixture("Original")
        fixture.undo.beginUndoGrouping()
        fixture.view.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: NSRange(location: 0, length: 8))
        fixture.controller.finishEditing()
        fixture.undo.endUndoGrouping()

        XCTAssertFalse(fixture.view.hasMarkedText())
        XCTAssertEqual(fixture.draft.value, "入力")
    }

    func testMarkedTextSurvivesAnExternalDraftUntilCompositionFinishes() async throws {
        let fixture = try EditorFixture("Original")
        fixture.undo.beginUndoGrouping()
        fixture.view.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: NSRange(location: 0, length: 8))
        XCTAssertTrue(fixture.view.hasMarkedText())
        fixture.draft.value = "New shared message"
        fixture.coordinator.synchronizeText()
        XCTAssertEqual(fixture.view.string, "入力")

        fixture.view.insertText("入力確定", replacementRange: fixture.view.markedRange())
        fixture.undo.endUndoGrouping()
        let reconciled = expectation(description: "Completed composition reconciled")
        DispatchQueue.main.async { reconciled.fulfill() }
        await fulfillment(of: [reconciled], timeout: 3)
        XCTAssertFalse(fixture.view.hasMarkedText())
        XCTAssertEqual(fixture.draft.value, "入力確定")
        XCTAssertEqual(fixture.undo.undoActionName, "Edit Commit Message")
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft.value, "New shared message")
    }

    /// Exercise native responder retention and key notifications without
    /// bringing an offscreen test window in front of the user's application.
    @MainActor
    private final class KeyStateWindow: NSWindow {
        private var keyState = false
        override var isKeyWindow: Bool { keyState }

        func setKeyState(_ active: Bool) {
            keyState = active
            NotificationCenter.default.post(name: active ? NSWindow.didBecomeKeyNotification
                                            : NSWindow.didResignKeyNotification, object: self)
        }
    }

    private final class Draft: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
    }

    @MainActor
    private final class EditorFixture {
        let draft: Draft
        let controller = CommitMessageUndoController()
        let coordinator: CommitMessageEditor.Coordinator
        let scrollView: NSScrollView
        let view: NSTextView
        let undo: UndoManager

        convenience init(_ text: String, groupsByEvent: Bool = false) throws {
            try self.init(Draft(text), groupsByEvent: groupsByEvent)
        }

        init(_ draft: Draft, groupsByEvent: Bool = false) throws {
            self.draft = draft
            let editor = CommitMessageEditor(
                text: Binding(get: { draft.value }, set: { draft.value = $0 }),
                focusRequest: UUID(), controller: controller, onEditingBegan: {})
            coordinator = CommitMessageEditor.Coordinator(editor)
            scrollView = coordinator.makeScrollView()
            view = try XCTUnwrap(scrollView.documentView as? NSTextView)
            undo = try XCTUnwrap(view.undoManager)
            undo.groupsByEvent = groupsByEvent
        }

        func generate(_ message: String) {
            controller.applyGenerated(CommitMessageReplacement(previousMessage: draft.value, message: message))
        }
    }
}
#endif
