/// Identity captured when commit-message generation starts. A response is safe
/// to apply only while it is still the active request and neither of the inputs
/// the user can change beneath it has moved on.
struct CommitMessageGenerationContext: Equatable, Sendable {
    let token: UInt64
    let draftRevision: UInt64
    let stagedRevision: UInt64

    func isCurrent(activeToken: UInt64?,
                   currentDraftRevision: UInt64,
                   currentStagedRevision: UInt64) -> Bool {
        activeToken == token
            && currentDraftRevision == draftRevision
            && currentStagedRevision == stagedRevision
    }

    /// The staged revision catches changes observed by the repo snapshot. The
    /// exact diff comparison also catches index edits whose paths/status letters
    /// stayed the same (for example, staging a newer version of the same file).
    func accepts(activeToken: UInt64?,
                 currentDraftRevision: UInt64,
                 currentStagedRevision: UInt64,
                 generatedFrom stagedDiff: String,
                 currentStagedDiff: String) -> Bool {
        isCurrent(activeToken: activeToken,
                  currentDraftRevision: currentDraftRevision,
                  currentStagedRevision: currentStagedRevision)
            && currentStagedDiff == stagedDiff
    }
}
