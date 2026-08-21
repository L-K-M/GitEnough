import XCTest
@testable import GitEnough

/// Unit tests for the pure pieces of RepoViewModel. (The async/queue
/// choreography has no test seam yet — see ANALYSIS.md G9.)
final class RepoViewModelTests: XCTestCase {

    /// The mapping the staged-rename discard fix lives in: a staged rename
    /// must reset both its paths, a plain tracked change only its own, and
    /// an untracked file none (the caller moves those to the Trash).
    func testTrackedPathsToDiscardExpandsRenames() {
        let rename = FileChange(path: "renamed.txt", originalPath: "a.txt",
                                stagedStatus: .renamed, unstagedStatus: nil)
        let modified = FileChange(path: "b.txt", originalPath: nil,
                                  stagedStatus: nil, unstagedStatus: .modified)
        let untracked = FileChange(path: "c.txt", originalPath: nil,
                                   stagedStatus: nil, unstagedStatus: .untracked)

        XCTAssertEqual(RepoViewModel.trackedPathsToDiscard(in: [rename]),
                       ["renamed.txt", "a.txt"])
        XCTAssertEqual(RepoViewModel.trackedPathsToDiscard(in: [modified]),
                       ["b.txt"])
        XCTAssertTrue(RepoViewModel.trackedPathsToDiscard(in: [untracked]).isEmpty)
        XCTAssertEqual(RepoViewModel.trackedPathsToDiscard(in: [rename, modified, untracked]),
                       ["renamed.txt", "a.txt", "b.txt"])
    }

    /// Overlapping changes (a rename whose new path another change also
    /// carries) must not double-reset a path: output is deduplicated with
    /// first-occurrence order preserved.
    func testTrackedPathsToDiscardDeduplicates() {
        let rename = FileChange(path: "b.txt", originalPath: "a.txt",
                                stagedStatus: .renamed, unstagedStatus: nil)
        let alsoB = FileChange(path: "b.txt", originalPath: nil,
                               stagedStatus: nil, unstagedStatus: .modified)
        XCTAssertEqual(RepoViewModel.trackedPathsToDiscard(in: [rename, alsoB]),
                       ["b.txt", "a.txt"])
    }

    /// A staged copy also carries originalPath, but its source is untouched
    /// by the change — expanding it would clobber the source's unrelated
    /// worktree edits. Only renames expand.
    func testTrackedPathsToDiscardDoesNotExpandCopies() {
        let copy = FileChange(path: "copy.txt", originalPath: "source.txt",
                              stagedStatus: .copied, unstagedStatus: nil)
        XCTAssertEqual(RepoViewModel.trackedPathsToDiscard(in: [copy]), ["copy.txt"])
    }
}
