import XCTest
@testable import GitEnough

final class CommitMessageGenerationContextTests: XCTestCase {

    func testAcceptsOnlyTheUnchangedActiveRequest() {
        let request = CommitMessageGenerationContext(
            token: 7, draftRevision: 3, stagedRevision: 5)

        XCTAssertTrue(request.accepts(
            activeToken: 7,
            currentDraftRevision: 3,
            currentStagedRevision: 5,
            generatedFrom: "diff --git a/a b/a\n+one",
            currentStagedDiff: "diff --git a/a b/a\n+one"))
    }

    func testReverseCompletionCannotReplaceANewerGeneration() {
        let older = CommitMessageGenerationContext(
            token: 10, draftRevision: 2, stagedRevision: 4)
        let newer = CommitMessageGenerationContext(
            token: 11, draftRevision: 2, stagedRevision: 4)

        XCTAssertFalse(older.accepts(
            activeToken: newer.token,
            currentDraftRevision: 2,
            currentStagedRevision: 4,
            generatedFrom: "same diff",
            currentStagedDiff: "same diff"))
        XCTAssertTrue(newer.accepts(
            activeToken: newer.token,
            currentDraftRevision: 2,
            currentStagedRevision: 4,
            generatedFrom: "same diff",
            currentStagedDiff: "same diff"))
    }

    func testRejectsANewerDraftEvenIfStagedContentIsUnchanged() {
        let request = CommitMessageGenerationContext(
            token: 1, draftRevision: 8, stagedRevision: 13)

        XCTAssertFalse(request.accepts(
            activeToken: 1,
            currentDraftRevision: 9,
            currentStagedRevision: 13,
            generatedFrom: "same diff",
            currentStagedDiff: "same diff"))
    }

    func testRejectsAnObservedStagedStateChange() {
        let request = CommitMessageGenerationContext(
            token: 1, draftRevision: 8, stagedRevision: 13)

        XCTAssertFalse(request.accepts(
            activeToken: 1,
            currentDraftRevision: 8,
            currentStagedRevision: 14,
            generatedFrom: "same diff",
            currentStagedDiff: "same diff"))
    }

    func testRejectsChangedStagedContentWithTheSameStatusRevision() {
        let request = CommitMessageGenerationContext(
            token: 1, draftRevision: 8, stagedRevision: 13)

        XCTAssertFalse(request.accepts(
            activeToken: 1,
            currentDraftRevision: 8,
            currentStagedRevision: 13,
            generatedFrom: "diff with old contents",
            currentStagedDiff: "diff with new contents"))
    }
}
