import XCTest
@testable import GitEnough

/// Tests for RepoViewModel decision logic that needs no git access.
final class RepoViewModelTests: XCTestCase {

    private func makeViewModel() -> RepoViewModel {
        RepoViewModel(repo: Repository(path: "/nonexistent/gitenough-test", name: "test"))
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
