import XCTest
@testable import GitEnough

/// Tests for the user-facing derived state on a parsed repository status.
final class RepoStatusTests: XCTestCase {

    func testConflictOnlyStatusIsDirty() {
        let conflict = FileChange(path: "conflict.txt", originalPath: nil,
                                  stagedStatus: .unmerged, unstagedStatus: .unmerged)
        let status = RepoStatus(conflicted: [conflict])

        XCTAssertTrue(status.isDirty)
        XCTAssertEqual(status.changeCount, 1)
    }

    func testChangeCountCountsUniquePathsAcrossStatusBuckets() {
        let partial = FileChange(path: "partial.txt", originalPath: nil,
                                 stagedStatus: .modified, unstagedStatus: .modified)
        let conflict = FileChange(path: "conflict.txt", originalPath: nil,
                                  stagedStatus: .unmerged, unstagedStatus: .unmerged)
        let unstaged = FileChange(path: "unstaged.txt", originalPath: nil,
                                  stagedStatus: nil, unstagedStatus: .modified)
        let status = RepoStatus(staged: [partial, conflict],
                                unstaged: [partial, unstaged, conflict],
                                conflicted: [conflict])

        XCTAssertTrue(status.isDirty)
        XCTAssertEqual(status.changeCount, 3)
    }
}
