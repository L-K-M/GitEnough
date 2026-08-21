import XCTest
@testable import GitEnough

/// Tests for the shared view helpers in CommonViews.
final class CommonViewsTests: XCTestCase {

    /// The copy helper must replace the pasteboard's contents, not append —
    /// the clear-then-write contract every Copy action relies on. Driven
    /// against a private pasteboard so the user's real clipboard is untouched.
    @MainActor
    func testCopyStringReplacesPasteboardContents() {
        let pasteboard = NSPasteboard.withUniqueName()
        NSPasteboard.copyString("first", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "first")
        NSPasteboard.copyString("second", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
    }
}
