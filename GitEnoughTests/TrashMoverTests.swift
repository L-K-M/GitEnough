import Foundation
import XCTest
@testable import GitEnough

final class TrashMoverTests: XCTestCase {
    func testMovePreservesSuccessesAndReportsEveryFailureAfterAllAttempts() {
        let root = URL(fileURLWithPath: "/repo")
        let paths = ["moved.txt", "denied.txt", "nested/also-moved.txt", "busy.txt"]
        var attempted: [String] = []
        var moved: [String] = []

        XCTAssertThrowsError(
            try TrashMover.move(paths: paths, from: root) { url in
                let path = String(url.path.dropFirst(root.path.count + 1))
                attempted.append(path)
                switch path {
                case "denied.txt":
                    throw StubError("Permission denied")
                case "busy.txt":
                    throw StubError("File is busy")
                default:
                    moved.append(path)
                }
            }
        ) { error in
            guard let moveError = error as? TrashMover.MoveError else {
                return XCTFail("Expected TrashMover.MoveError, got \(error)")
            }
            XCTAssertEqual(
                moveError.failures,
                [
                    .init(path: "denied.txt", reason: "Permission denied"),
                    .init(path: "busy.txt", reason: "File is busy")
                ]
            )
            XCTAssertEqual(
                moveError.localizedDescription,
                "Couldn’t move 2 items to the Trash:\n" +
                "• “denied.txt”: Permission denied\n" +
                "• “busy.txt”: File is busy"
            )
        }

        XCTAssertEqual(attempted, paths)
        XCTAssertEqual(moved, ["moved.txt", "nested/also-moved.txt"])
    }

    func testMoveReportsSingleFailedPathClearly() {
        let root = URL(fileURLWithPath: "/repo")

        XCTAssertThrowsError(
            try TrashMover.move(paths: ["draft.txt"], from: root) { _ in
                throw StubError("Operation not permitted")
            }
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Couldn’t move “draft.txt” to the Trash: Operation not permitted"
            )
        }
    }

    private struct StubError: Error, LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
