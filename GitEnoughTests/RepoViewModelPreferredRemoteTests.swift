import XCTest
@testable import GitEnough

/// Tests for the pure remote-selection logic behind the status bar label and
/// pull-request resolution. (Named distinctly from RepoViewModelTests so
/// parallel branches adding that file don't conflict on merge.)
final class RepoViewModelPreferredRemoteTests: XCTestCase {

    private let fork = Remote(name: "fork", url: "git@github.com:me/repo.git")
    private let origin = Remote(name: "origin", url: "git@github.com:owner/repo.git")
    private let upstream = Remote(name: "upstream", url: "git@github.com:canonical/repo.git")

    func testUpstreamRemoteWins() {
        // Fork-style setup: origin lists first, but the branch tracks upstream —
        // the label must describe the remote actually being pulled from.
        let remotes = [fork, origin, upstream]
        XCTAssertEqual(RepoViewModel.preferredRemote(upstream: "upstream/main",
                                                     remotes: remotes)?.name, "upstream")
    }

    func testFallsBackToOriginThenFirst() {
        XCTAssertEqual(RepoViewModel.preferredRemote(upstream: nil, remotes: [fork, origin])?.name,
                       "origin")
        XCTAssertEqual(RepoViewModel.preferredRemote(upstream: nil, remotes: [fork])?.name, "fork")
        XCTAssertNil(RepoViewModel.preferredRemote(upstream: nil, remotes: []))
    }

    func testDanglingUpstreamFallsBackGracefully() {
        // Upstream names a remote that is no longer configured (deleted remote).
        XCTAssertEqual(RepoViewModel.preferredRemote(upstream: "ghost/main",
                                                     remotes: [fork, origin])?.name, "origin")
    }
}
