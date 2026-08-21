import XCTest
@testable import GitEnough

/// Tests for RepoViewModel decision logic that needs no git access.
final class RepoViewModelTests: XCTestCase {

    private func makeViewModel() -> RepoViewModel {
        RepoViewModel(repo: Repository(path: "/nonexistent/gitenough-test", name: "test"))
    }

    // MARK: - Push vs publish

    func testShouldPublish() {
        let origin = Remote(name: "origin", url: "https://example.com/owner/repo.git")
        // No upstream + a remote exists → a Push action must publish.
        XCTAssertTrue(RepoViewModel.shouldPublish(upstream: nil, remotes: [origin]))
        // Upstream set → plain push.
        XCTAssertFalse(RepoViewModel.shouldPublish(upstream: "origin/main", remotes: [origin]))
        // No remotes at all → nothing to publish to; the Publish button hides.
        XCTAssertFalse(RepoViewModel.shouldPublish(upstream: nil, remotes: []))
    }

    // MARK: - Pull guard

    func testPullWithoutUpstreamFailsGracefully() {
        let viewModel = makeViewModel()
        viewModel.pull(rebase: false)
        // The guard fires synchronously (no perform, no git): a plain-language
        // error instead of git's raw "no tracking information" from the menu.
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("no upstream") ?? false)
        XCTAssertFalse(viewModel.isBusy)
    }

    // MARK: - Push guard

    func testPushOrPublishWithoutRemotesFailsGracefully() {
        let viewModel = makeViewModel()
        viewModel.pushOrPublish()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("no remotes") ?? false)
        XCTAssertFalse(viewModel.isBusy)
    }
}
