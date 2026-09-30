import XCTest
@testable import GitEnough

final class GitModelsTests: XCTestCase {

    func testRenameActionsIncludeSourceAndDestination() {
        let rename = FileChange(
            path: "new.txt", originalPath: "old.txt",
            stagedStatus: .renamed, unstagedStatus: nil)

        XCTAssertTrue(rename.isRename)
        XCTAssertFalse(rename.isCopy)
        XCTAssertEqual(rename.affectedPaths, ["new.txt", "old.txt"])
    }

    func testCopyActionsDoNotIncludeIndependentSource() {
        let copy = FileChange(
            path: "copy.txt", originalPath: "source.txt",
            stagedStatus: .copied, unstagedStatus: nil)

        XCTAssertFalse(copy.isRename)
        XCTAssertTrue(copy.isCopy)
        XCTAssertEqual(copy.affectedPaths, ["copy.txt"])
    }

    func testOrdinaryActionsIncludeOnlyTheirPath() {
        let modification = FileChange(
            path: "file.txt", originalPath: nil,
            stagedStatus: .modified, unstagedStatus: .modified)

        XCTAssertEqual(modification.affectedPaths, ["file.txt"])
    }
}
