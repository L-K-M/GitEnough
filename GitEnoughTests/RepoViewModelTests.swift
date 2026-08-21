import XCTest
@testable import GitEnough

/// Tests for RepoViewModel decision logic that needs no git access.
final class RepoViewModelTests: XCTestCase {

    private func makeViewModel() -> RepoViewModel {
        RepoViewModel(repo: Repository(path: "/nonexistent/gitenough-test", name: "test"))
    }

    // MARK: - Push capability

    private let origin = Remote(name: "origin", url: "https://example.com/owner/repo.git")

    func testPushCapabilityWithUpstreamUsesPlainPush() {
        let status = RepoStatus(head: "main", headHash: "abc123",
                                upstream: "origin/main")
        XCTAssertEqual(PushCapability.resolve(status: status, remotes: [origin]), .push)
    }

    func testPushCapabilityForNewLocalBranchPublishesToOrigin() {
        let status = RepoStatus(head: "feature", headHash: "abc123")
        let backup = Remote(name: "backup", url: "https://example.com/backup/repo.git")
        XCTAssertEqual(
            PushCapability.resolve(status: status, remotes: [backup, origin]),
            .publish(remote: "origin"))
    }

    func testPushCapabilityRejectsDetachedHead() {
        let status = RepoStatus(head: nil, headHash: "abc123")
        let capability = PushCapability.resolve(status: status, remotes: [origin])
        XCTAssertEqual(capability, .unavailable(.detachedHead))
        XCTAssertTrue(capability.help.contains("detached"))
    }

    func testPushCapabilityRejectsUnbornHead() {
        let status = RepoStatus(head: "main", headHash: "(initial)")
        let capability = PushCapability.resolve(status: status, remotes: [origin])
        XCTAssertEqual(capability, .unavailable(.unbornHead))
        XCTAssertTrue(capability.help.contains("no commits"))
    }

    func testPushCapabilityRejectsRepositoryWithoutRemotes() {
        let status = RepoStatus(head: "feature", headHash: "abc123")
        let capability = PushCapability.resolve(status: status, remotes: [])
        XCTAssertEqual(capability, .unavailable(.noRemotes))
        XCTAssertTrue(capability.help.contains("no remotes"))
    }

    // MARK: - Pull guard

    func testPullWithoutUpstreamFailsGracefully() {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.status.upstream,
                     "Precondition: a fresh view model starts without an upstream")
        viewModel.pull(rebase: false)
        // The guard fires synchronously (no perform, no git): a plain-language
        // error instead of git's raw "no tracking information" from the menu.
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("no upstream") ?? false)
        XCTAssertFalse(viewModel.isBusy)
    }
}
