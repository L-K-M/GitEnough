import XCTest
@testable import GitEnough

/// Tests for the paste-executed shell commands built by CommitCommands.
final class CommitCommandsTests: XCTestCase {

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
        // Uppercase hex is unusual but valid — accepted.
        XCTAssertEqual(CommitCommands.cherryPickCommand(forHash: hash.uppercased()),
                       "git cherry-pick '\(hash.uppercased())'")
    }
}
