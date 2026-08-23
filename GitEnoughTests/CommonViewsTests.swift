import AppKit
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
        defer { pasteboard.releaseGlobally() }
        pasteboard.copyString("first")
        XCTAssertEqual(pasteboard.string(forType: .string), "first")

        // Pollute with an unrelated type: a clear-then-write must remove it,
        // not just overwrite the string type.
        XCTAssertTrue(pasteboard.setData(Data([0x00]), forType: .pdf))
        pasteboard.copyString("second")
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        XCTAssertNil(pasteboard.data(forType: .pdf), "clearContents must drop prior types")
    }
}
