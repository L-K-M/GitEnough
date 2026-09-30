// ChangesView is SwiftUI, so it lives outside the SwiftPM library and there is
// nothing here for a Linux build to exercise. Compiled by the Xcode project,
// where the view it tests actually exists.
#if canImport(AppKit)
import XCTest
@testable import GitEnough

/// The disabled Stage All tooltip: on macOS the button is disabled whenever
/// anything is unmerged, so `GitClient.stageAll`'s refusal almost never reaches
/// a user and this is the copy they actually read. It was the one string in
/// this change with nothing behind it, which is how its pronoun came to
/// disagree with its own count and its warning came to cover only one of the
/// two conflict shapes.
final class StageAllBlockedHelpTests: XCTestCase {

    private func conflict(_ path: String) -> FileChange {
        FileChange(path: path, originalPath: nil,
                   stagedStatus: .unmerged, unstagedStatus: .unmerged)
    }

    /// Noun and pronoun must agree with the count, together. Pluralising one and
    /// not the other is the exact bug this test exists for: "1 conflicted file …
    /// staging them".
    func testTheNounAndThePronounBothAgreeWithTheCount() {
        let one = ChangesView.stageAllBlockedHelp([conflict("a.txt")])
        XCTAssertTrue(one.contains("1 conflicted file first"), one)
        XCTAssertTrue(one.contains("Staging it "), one)
        XCTAssertFalse(one.contains("files"), "singular count with a plural noun: \(one)")
        XCTAssertFalse(one.contains("them"), "singular count with a plural pronoun: \(one)")

        let many = ChangesView.stageAllBlockedHelp(
            [conflict("a.txt"), conflict("b.txt")])
        XCTAssertTrue(many.contains("2 conflicted files first"), many)
        XCTAssertTrue(many.contains("Staging them "), many)
    }

    /// The tooltip and the refusal must make the *same* claim about what staging
    /// a conflict does. They were two sentences, and had already diverged: the
    /// tooltip said only "accepts whatever is in the worktree", which tells a
    /// user to go find conflict markers — and a modify/delete conflict has none.
    func testTheConsequenceClauseIsTheSharedOne() {
        let help = ChangesView.stageAllBlockedHelp([conflict("a.txt")])
        XCTAssertTrue(help.contains(GitClient.conflictStagingConsequence),
                      "the tooltip must state the shared consequence verbatim: \(help)")
        XCTAssertTrue(GitClient.conflictStagingConsequence.contains("silently winning"),
                      "and that clause must still cover the no-marker shape")
    }

    /// The file list comes from `namingFiles`, so the tooltip and the refusal
    /// cannot name the files differently — including the "and N more" cut.
    func testTheFileListIsTheSharedFragment() {
        let paths = ["a.txt", "b.txt", "c.txt", "d.txt"]
        let help = ChangesView.stageAllBlockedHelp(paths.map(conflict))
        XCTAssertTrue(help.contains(GitClient.namingFiles(paths)), help)
        XCTAssertTrue(help.contains("and 1 more"), "the cut must survive into the tooltip: \(help)")
    }
}
#endif
