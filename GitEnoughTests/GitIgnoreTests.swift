import XCTest
@testable import GitEnough

/// Tests for the pure .gitignore append/escape rules behind "Ignore in .gitignore".
final class GitIgnoreTests: XCTestCase {

    func testEscapeLeavesPlainPathsAlone() {
        XCTAssertEqual(GitIgnore.escape("Sources/App.swift"), "Sources/App.swift")
        XCTAssertEqual(GitIgnore.escape("with space.txt"), "with space.txt")
    }

    func testEscapeEscapesGlobMetacharacters() {
        XCTAssertEqual(GitIgnore.escape("report[1].txt"), "report\\[1\\].txt")
        XCTAssertEqual(GitIgnore.escape("a*b?c.txt"), "a\\*b\\?c.txt")
        XCTAssertEqual(GitIgnore.escape("back\\slash.txt"), "back\\\\slash.txt")
    }

    func testAppendingToEmptyFileAnchorsAtRoot() {
        XCTAssertEqual(GitIgnore.appending("build/output", to: ""),
                       "/build/output\n")
    }

    func testAppendingAddsNewlineSeparatorWhenMissing() {
        XCTAssertEqual(GitIgnore.appending("b.txt", to: "/a.txt"),
                       "/a.txt\n/b.txt\n")
        XCTAssertEqual(GitIgnore.appending("b.txt", to: "/a.txt\n"),
                       "/a.txt\n/b.txt\n")
    }

    func testAppendingIsIdempotent() {
        let once = GitIgnore.appending("report[1].txt", to: "")
        XCTAssertEqual(GitIgnore.appending("report[1].txt", to: once), once)
        // The unescaped literal form counts as a duplicate too.
        XCTAssertEqual(GitIgnore.appending("report[1].txt", to: "report[1].txt\n"),
                       "report[1].txt\n")
    }

    func testAppendingDetectsDuplicatesInCRLFFiles() {
        let crlf = "/a.txt\r\n/report[1].txt\r\n"
        XCTAssertEqual(GitIgnore.appending("report[1].txt", to: crlf), crlf)
    }
}
