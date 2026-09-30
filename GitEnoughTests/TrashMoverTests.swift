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

    func testMoveRejectsPathsThatCouldEscapeRootWithoutAttemptingThem() {
        let root = URL(fileURLWithPath: "/repo")
        let paths = ["../escape.txt", "/absolute.txt", "nested/../../escape.txt"]
        var attempted: [URL] = []

        XCTAssertThrowsError(
            try TrashMover.move(paths: paths, from: root) { url in
                attempted.append(url)
            }
        ) { error in
            guard let moveError = error as? TrashMover.MoveError else {
                return XCTFail("Expected TrashMover.MoveError, got \(error)")
            }
            XCTAssertEqual(moveError.failures.map(\.path), paths)
            XCTAssertTrue(moveError.failures.allSatisfy {
                $0.reason == "Path escapes the repository root"
            })
        }

        XCTAssertTrue(attempted.isEmpty)
    }

    func testMoveCapsLongFailureDescription() {
        let root = URL(fileURLWithPath: "/repo")
        let paths = (1...7).map { "failure-\($0).txt" }

        XCTAssertThrowsError(
            try TrashMover.move(paths: paths, from: root) { _ in
                throw StubError("Permission denied")
            }
        ) { error in
            let description = error.localizedDescription
            XCTAssertTrue(description.hasPrefix("Couldn’t move 7 items to the Trash:"))
            XCTAssertTrue(description.contains("“failure-5.txt”"))
            XCTAssertFalse(description.contains("“failure-6.txt”"))
            XCTAssertTrue(description.hasSuffix("…and 2 more"))
        }
    }

    func testMoveDoesNotThrowWhenEveryPathMoves() throws {
        let root = URL(fileURLWithPath: "/repo")
        var attempted: [URL] = []

        try TrashMover.move(paths: ["a.txt", "nested/b.txt"], from: root) { url in
            attempted.append(url)
        }

        XCTAssertEqual(attempted, [
            root.appendingPathComponent("a.txt"),
            root.appendingPathComponent("nested/b.txt")
        ])
    }

    func testMoveWithEmptyPathsAttemptsNothing() throws {
        try TrashMover.move(paths: [], from: URL(fileURLWithPath: "/repo")) { _ in
            XCTFail("No items should be attempted for an empty path list")
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
