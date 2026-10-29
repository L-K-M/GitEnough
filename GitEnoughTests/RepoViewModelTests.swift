import XCTest
@testable import GitEnough

/// Tests for RepoViewModel decision logic that needs no git access.
final class RepoViewModelTests: XCTestCase {

    private func makeViewModel() -> RepoViewModel {
        // An isolated suite: the commit-box draft persists through
        // `UserDefaults`, and a test must not write into the developer's own.
        let name = "RepoViewModelTests-\(UUID().uuidString)"
        // Force-unwrapped on purpose: falling back to `.standard` would read
        // and write the developer's real defaults, which is the one thing this
        // helper exists to prevent. Failing loudly is the safer direction.
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return RepoViewModel(repo: Repository(path: "/nonexistent/gitenough-test",
                                              name: "test"),
                             defaults: defaults)
    }

    // MARK: - Pull guard

    func testPullWithoutUpstreamFailsGracefully() {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.status.upstream,
                     "Precondition: a fresh view model starts without an upstream")
        viewModel.pull(rebase: false)
        // The guard fires synchronously (no perform, no git) with a
        // plain-language error naming the fix. A fresh view model has no
        // remotes, so the no-remotes wording is the branch exercised here; the
        // no-upstream variant needs a remote to exist, which only the snapshot
        // loader can provide (no injection seam yet — see glm.md GLM-G1).
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("Can't pull") ?? false)
        XCTAssertTrue(viewModel.errorMessage?.contains("no remotes") ?? false)
        XCTAssertFalse(viewModel.isBusy)
    }

    // MARK: - Commit box enablement

    /// `canCommit` and `canGenerateCommitMessage` exist so the two front ends
    /// describe one button the same way. The axes reachable without a
    /// repository are the message and the amend flag; the staged-list axis and
    /// the busy axis are covered end to end in `GitIntegrationTests`.
    func testCommitNeedsAMessage() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.canCommit, "a fresh box has no message")

        viewModel.draftCommitMessage = "   \n\t "
        XCTAssertFalse(viewModel.canCommit, "whitespace is not a message")
    }

    /// An amend that only rewords the last commit stages nothing by
    /// definition. Gating Commit on the staged list alone made it unreachable.
    func testAmendCommitsWithNothingStaged() {
        let viewModel = makeViewModel()
        viewModel.draftCommitMessage = "Reword the last commit"
        XCTAssertTrue(viewModel.status.staged.isEmpty, "precondition")
        XCTAssertFalse(viewModel.canCommit)

        viewModel.amendLastCommit = true
        XCTAssertTrue(viewModel.canCommit)
    }

    func testGenerateNeedsSomethingStaged() {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.status.staged.isEmpty, "precondition")
        XCTAssertFalse(viewModel.canGenerateCommitMessage,
                       "an empty staged diff costs a request and describes nothing")
    }

    // MARK: - Push guard

    func testPushOrPublishOnUnusableRepositoryFailsGracefully() {
        let viewModel = makeViewModel()
        // A fresh view model has no loaded status, so `head` is nil and
        // `PushCapability.resolve` stops at `.noCurrentBranch` — its
        // repository-shape checks deliberately precede the remotes check,
        // because a repo with no branch can't publish however many remotes it
        // has. This test therefore pins the *view model's* contract — the
        // reason is surfaced and no work is queued — rather than one specific
        // reason's wording. Each reason's message, and the refs every usable
        // case resolves to, are covered exhaustively in PushCapabilityTests,
        // where the status can be built to select the branch under test.
        viewModel.pushOrPublish()
        XCTAssertEqual(viewModel.errorMessage,
                       PushCapability.UnavailableReason.noCurrentBranch.message)
        XCTAssertFalse(viewModel.isBusy)
    }
}
