import XCTest
@testable import GitEnough

/// The Settings editor's asynchronous lifecycle, as state transitions.
///
/// Every case here is a sequence that produced a wrong answer in review: a
/// save deleting a key it never read, a stale snapshot reported as saved, a
/// verdict applied to settings it was not fetched for, and buttons left dead
/// after a close and reopen.
final class SettingsEditStateTests: XCTestCase {

    private let zai = LLMConfiguration.default
    private let openai = LLMConfiguration(provider: .openai,
                                          baseURL: "https://api.openai.com/v1",
                                          model: "gpt-4o-mini")

    // MARK: - What a save may write

    /// The original report: an untouched key field must never reach the secret
    /// store, because a failed read leaves it empty and writing empty deletes.
    func testAnUntouchedKeyFieldIsNotWritten() {
        var state = SettingsEditState()
        state.present()

        XCTAssertNil(state.keyPayload(displayed: ""),
                     "a save aimed at the model name must not carry the key")
    }

    func testAnEditedKeyFieldIsWritten() {
        var state = SettingsEditState()
        state.present()
        state.editKey()

        XCTAssertEqual(state.keyPayload(displayed: "sk-new"), "sk-new")
    }

    /// Clearing the field is an edit, so removing a key on purpose still works
    /// and is not confused with "we could not read it".
    func testClearingTheFieldIsAnExplicitDeletion() {
        var state = SettingsEditState()
        state.present()
        state.editKey()

        XCTAssertEqual(state.keyPayload(displayed: ""), "",
                       "an empty field the user cleared is a deletion, not an unknown")
    }

    /// Reopening forgets that the previous showing's field was touched —
    /// otherwise the second showing would write a key it never read.
    func testReopeningForgetsTheEarlierEdit() {
        var state = SettingsEditState()
        state.present()
        state.editKey()
        state.present()

        XCTAssertNil(state.keyPayload(displayed: ""))
    }

    // MARK: - Whether a result still applies

    func testAResultForTheCurrentFieldsIsAccepted() {
        var state = SettingsEditState()
        state.present()
        let request = state.request(for: zai)

        XCTAssertTrue(state.accepts(request, configuration: zai))
    }

    func testAResultIsRejectedAfterTheProviderChanges() {
        var state = SettingsEditState()
        state.present()
        let request = state.request(for: zai)

        XCTAssertFalse(state.accepts(request, configuration: openai),
                       "a verdict for one endpoint must not label another")
    }

    /// The key is part of the request's identity. Testing a connection, then
    /// changing only the key, must not leave "Connection works" sitting next
    /// to a credential nothing tried.
    func testAResultIsRejectedAfterOnlyTheKeyChanges() {
        var state = SettingsEditState()
        state.present()
        let request = state.request(for: zai)

        state.editKey()

        XCTAssertFalse(state.accepts(request, configuration: zai),
                       "the configuration is unchanged, but the credential is not")
    }

    func testAResultFromAPreviousShowingIsRejected() {
        var state = SettingsEditState()
        state.present()
        let request = state.request(for: zai)

        state.present()

        XCTAssertFalse(state.accepts(request, configuration: zai))
    }

    // MARK: - Whether the fields moved during a write

    func testAQuietSaveHasNotMoved() {
        var state = SettingsEditState()
        state.present()
        let request = state.request(for: zai)

        XCTAssertFalse(state.moved(since: request, configuration: zai))
    }

    func testEditingTheConfigurationDuringAWriteCountsAsMoved() {
        var state = SettingsEditState()
        state.present()
        let request = state.request(for: zai)

        XCTAssertTrue(state.moved(since: request, configuration: openai))
    }

    /// The case that survived the first fix: the save carried no key because
    /// the field was untouched, then the user typed one while the write was
    /// out. Reporting a plain "Saved" there claims a key was stored that never
    /// was.
    func testTypingAKeyDuringAKeylessSaveCountsAsMoved() {
        var state = SettingsEditState()
        state.present()
        let request = state.request(for: zai)
        XCTAssertNil(state.keyPayload(displayed: ""), "precondition: no key in this save")

        state.editKey()

        XCTAssertTrue(state.moved(since: request, configuration: zai),
                      "the visible key was never written and must not read as saved")
    }

    /// `moved` compares configuration and key revision, and neither is unique
    /// across showings: `present()` resets the revision, so showing B's first
    /// key edit lands on the same number as showing A's. A completion that
    /// consults `moved` without first checking it owns the dialog can
    /// therefore conclude "nothing changed" about a showing it has never seen,
    /// and report A's write as having saved B's fields.
    ///
    /// This is why the save completion checks `isFromCurrentPresentation`
    /// first. Pinned here so the ordering is not mistaken for redundancy.
    func testMovedCannotDistinguishShowingsOnItsOwn() {
        var state = SettingsEditState()
        state.present()
        state.editKey()
        let fromA = state.request(for: zai)

        state.present()
        state.editKey()

        XCTAssertFalse(state.moved(since: fromA, configuration: zai),
                       "same configuration, same revision — moved sees no difference")
        XCTAssertFalse(state.isFromCurrentPresentation(fromA),
                       "so ownership is the check that has to come first")
    }

    // MARK: - Busy state across a reopen

    /// Start an operation, close, reopen. The old completion is discarded by
    /// the presentation check, so it never clears the flag; the new showing
    /// has to start from a clean one or its buttons stay dead for good.
    func testReopeningClearsBusyLeftBehindByADiscardedOperation() {
        var state = SettingsEditState()
        state.present()
        state.beginOperation()
        let request = state.request(for: zai)

        state.present()

        XCTAssertFalse(state.accepts(request, configuration: zai),
                       "precondition: the old completion is discarded")
        XCTAssertFalse(state.isBusy,
                       "so the new showing must not inherit its busy flag")
    }

    func testAnOperationThatFinishesInItsOwnShowingClearsBusy() {
        var state = SettingsEditState()
        state.present()
        state.beginOperation()
        XCTAssertTrue(state.isBusy)

        state.endOperation()

        XCTAssertFalse(state.isBusy)
    }
}
