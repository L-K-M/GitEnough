import AppKit
import XCTest
@testable import GitEnough

/// The shared copy primitive behind every "Copy …" action. Runs against a
/// uniquely named pasteboard, so the user's actual clipboard is never touched.
final class NSPasteboardCopyStringTests: XCTestCase {

    func testCopyStringWritesAndReplacesContents() {
        let board = NSPasteboard(name: NSPasteboard.Name("GitEnoughTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        XCTAssertTrue(board.copyString("feature/login"))
        XCTAssertEqual(board.string(forType: .string), "feature/login")

        // The second copy fully replaces the first (clearContents ran):
        // exactly one item, holding only the new string.
        XCTAssertTrue(board.copyString("abc1234 Fix crash on launch"))
        XCTAssertEqual(board.string(forType: .string), "abc1234 Fix crash on launch")
        XCTAssertEqual(board.pasteboardItems?.count, 1)
    }
}
