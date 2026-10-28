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

    // MARK: - Per-side status letter

    /// A partially staged path is in both lists, and the two rows describe
    /// different changes. The badge is a row's only status signal, so reading
    /// the wrong column is how a deletion renders as a green "A".
    func testPartiallyStagedPathShowsItsOwnColumnOnEachSide() {
        // AM — staged a new file, then kept editing it.
        let addedThenModified = FileChange(
            path: "new.txt", originalPath: nil,
            stagedStatus: .added, unstagedStatus: .modified)
        XCTAssertEqual(addedThenModified.displayStatus(staged: true), .added)
        XCTAssertEqual(addedThenModified.displayStatus(staged: false), .modified)

        // MD — staged an edit, then deleted the file from disk.
        let modifiedThenDeleted = FileChange(
            path: "gone.txt", originalPath: nil,
            stagedStatus: .modified, unstagedStatus: .deleted)
        XCTAssertEqual(modifiedThenDeleted.displayStatus(staged: true), .modified)
        XCTAssertEqual(modifiedThenDeleted.displayStatus(staged: false), .deleted)

        // AD — staged a new file, then deleted it. The unstaged row used to say
        // "Added" (and render green) for a file that no longer exists.
        let addedThenDeleted = FileChange(
            path: "ghost.txt", originalPath: nil,
            stagedStatus: .added, unstagedStatus: .deleted)
        XCTAssertEqual(addedThenDeleted.displayStatus(staged: true), .added)
        XCTAssertEqual(addedThenDeleted.displayStatus(staged: false), .deleted)
    }

    /// The `.modified` fallback is a documented contract, so it is pinned
    /// rather than left to the doc comment. The lists never ask for a side a
    /// change is not on — a path reaches a list precisely because that column
    /// is set — but the method is public, and a caller that does ask gets a
    /// plausible letter rather than a crash.
    func testAskingForASideTheChangeIsNotOnFallsBackToModified() {
        let untrackedOnly = FileChange(
            path: "c.txt", originalPath: nil,
            stagedStatus: nil, unstagedStatus: .untracked)
        XCTAssertEqual(untrackedOnly.displayStatus(staged: true), .modified)

        let stagedOnly = FileChange(
            path: "d.txt", originalPath: nil,
            stagedStatus: .added, unstagedStatus: nil)
        XCTAssertEqual(stagedOnly.displayStatus(staged: false), .modified)
    }

    func testSingleSidedChangesShowThatSidesLetter() {
        let stagedOnly = FileChange(
            path: "a.txt", originalPath: nil,
            stagedStatus: .renamed, unstagedStatus: nil)
        XCTAssertEqual(stagedOnly.displayStatus(staged: true), .renamed)

        let untracked = FileChange(
            path: "b.txt", originalPath: nil,
            stagedStatus: nil, unstagedStatus: .untracked)
        XCTAssertEqual(untracked.displayStatus(staged: false), .untracked)
    }

    func testOrdinaryActionsIncludeOnlyTheirPath() {
        let modification = FileChange(
            path: "file.txt", originalPath: nil,
            stagedStatus: .modified, unstagedStatus: .modified)

        XCTAssertEqual(modification.affectedPaths, ["file.txt"])
    }
}
