import XCTest
@testable import GitEnough

final class GitModelsTests: XCTestCase {

    func testRenameActionsIncludeSourceAndDestination() {
        let rename = FileChange(
            path: "new.txt", originalPath: "old.txt",
            stagedStatus: .renamed, unstagedStatus: nil)

        XCTAssertEqual(rename.affectedPaths, ["new.txt", "old.txt"])
    }

    func testCopyActionsDoNotIncludeIndependentSource() {
        let copy = FileChange(
            path: "copy.txt", originalPath: "source.txt",
            stagedStatus: .copied, unstagedStatus: nil)

        XCTAssertEqual(copy.affectedPaths, ["copy.txt"])
    }

    func testOrdinaryActionsIncludeOnlyTheirPath() {
        let modification = FileChange(
            path: "file.txt", originalPath: nil,
            stagedStatus: .modified, unstagedStatus: .modified)

        XCTAssertEqual(modification.affectedPaths, ["file.txt"])
    }
}
