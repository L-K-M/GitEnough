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
        NSPasteboard.copyString("first", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "first")

        // Pollute with an unrelated type: a clear-then-write must remove it,
        // not just overwrite the string type.
        XCTAssertTrue(pasteboard.setData(Data([0x00]), forType: .pdf))
        NSPasteboard.copyString("second", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        XCTAssertNil(pasteboard.data(forType: .pdf), "clearContents must drop prior types")
    }

    /// The cherry-pick command is paste-executed verbatim, so only clean
    /// ASCII hex ever makes it into the quoted string.
    func testCherryPickCommandValidation() {
        let hash = String(repeating: "ab", count: 20)   // 40 chars, like a SHA-1
        XCTAssertEqual(CommitCommands.cherryPickCommand(forHash: " \(hash) \n"),
                       "git cherry-pick '\(hash)'")
        XCTAssertNil(CommitCommands.cherryPickCommand(forHash: ""))
        XCTAssertNil(CommitCommands.cherryPickCommand(forHash: "   "))
        XCTAssertNil(CommitCommands.cherryPickCommand(forHash: "abc'; rm -rf ~ #"))
        // isHexDigit alone would accept fullwidth digits — must not.
        XCTAssertNil(CommitCommands.cherryPickCommand(forHash: "１２３４５６７"))
    }
}
