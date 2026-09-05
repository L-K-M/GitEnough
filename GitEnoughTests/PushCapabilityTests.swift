import XCTest
@testable import GitEnough

/// `PushCapability` decides what Push and Force Push actually send. A bare
/// `git push` delegates that to `push.default`, which can push branches the
/// user never selected, so these tests pin the resolution rather than the
/// button label.
final class PushCapabilityTests: XCTestCase {

    private func status(head: String?, upstream: String? = nil,
                        headHash: String? = "abc1234") -> RepoStatus {
        RepoStatus(head: head, headHash: headHash, upstream: upstream)
    }

    private let origin = Remote(name: "origin", url: "https://example.com/x/y.git")

    // MARK: - Unavailable shapes

    func testUnbornHeadHasNothingToPush() {
        let resolved = PushCapability.resolve(
            status: status(head: "main", headHash: "(initial)"), remotes: [origin])
        XCTAssertEqual(resolved, .unavailable(.unbornHead))
        XCTAssertTrue(resolved.help.contains("no commits"))
        XCTAssertFalse(resolved.allowsForcePush)
    }

    func testDetachedHeadHasNothingToPush() {
        let resolved = PushCapability.resolve(status: status(head: nil), remotes: [origin])
        XCTAssertEqual(resolved, .unavailable(.detachedHead))
        XCTAssertTrue(resolved.help.contains("detached"))
    }

    func testNoRemotesIsReportedBeforeAnyRefIsChosen() {
        let resolved = PushCapability.resolve(
            status: status(head: "main", upstream: "origin/main"), remotes: [])
        XCTAssertEqual(resolved, .unavailable(.noRemotes))
        XCTAssertTrue(resolved.help.contains("no remotes"))
    }

    /// A repository shape that cannot push is reported before any ref is
    /// chosen: `head` is nil on a freshly-created view model, before the first
    /// snapshot lands.
    func testMissingCurrentBranchIsItsOwnReason() {
        var status = RepoStatus()
        status.headHash = nil
        XCTAssertEqual(PushCapability.resolve(status: status, remotes: [origin]),
                       .unavailable(.noCurrentBranch))
    }

    // MARK: - Push

    func testUpstreamResolvesToItsRemoteAndBranch() {
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: "main", upstream: "origin/main"),
                                   remotes: [origin]),
            .push(remote: "origin", localBranch: "main", remoteBranch: "main"))
    }

    /// The upstream branch need not share the local branch's name. The app's
    /// ahead/behind counters are measured against the upstream, so the upstream
    /// is the ref Push has to move — pushing to a same-named branch instead
    /// (what `push.default = current` would do) would move something the UI
    /// never counted.
    func testUpstreamBranchNameWinsOverTheLocalName() {
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: "feature", upstream: "origin/main"),
                                   remotes: [origin]),
            .push(remote: "origin", localBranch: "feature", remoteBranch: "main"))
    }

    /// Remote names may contain slashes, so the split is longest-prefix, not
    /// first-slash — the same rule `Remote.preferred` uses.
    func testSlashNamedRemoteSplitsOnTheLongestConfiguredName() {
        let up = Remote(name: "up", url: "https://example.com/a.git")
        let upStream = Remote(name: "up/stream", url: "https://example.com/b.git")
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: "port", upstream: "up/stream/port"),
                                   remotes: [up, upStream]),
            .push(remote: "up/stream", localBranch: "port", remoteBranch: "port"))
    }

    func testOnlyAnUpstreamBranchCanBeForcePushed() {
        XCTAssertTrue(
            PushCapability.resolve(status: status(head: "main", upstream: "origin/main"),
                                   remotes: [origin]).allowsForcePush)
        XCTAssertFalse(
            PushCapability.resolve(status: status(head: "main"), remotes: [origin])
                .allowsForcePush)
    }

    // MARK: - Publish

    func testNoUpstreamPublishesToTheFallbackRemote() {
        let fork = Remote(name: "fork", url: "https://example.com/f.git")
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: "topic"), remotes: [fork, origin]),
            .publish(remote: "origin", branch: "topic"),
            "origin wins over first-configured when both exist")
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: "topic"), remotes: [fork]),
            .publish(remote: "fork", branch: "topic"))
    }

    /// A branch whose `branch.<name>.remote` names a remote that has since been
    /// renamed or removed. Publishing repairs it and pushes somewhere the label
    /// names; a plain push would have to guess a remote, and guessing is the
    /// whole class of bug this type exists to remove.
    func testUpstreamNamingAMissingRemoteFallsBackToPublish() {
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: "main", upstream: "gone/main"),
                                   remotes: [origin]),
            .publish(remote: "origin", branch: "main"))
    }

    // MARK: - The command itself

    func testPushArgumentsAreFullyQualifiedOnBothSides() {
        XCTAssertEqual(
            GitClient.pushArguments(remote: "origin", localBranch: "feature",
                                    remoteBranch: "main", setUpstream: false),
            ["push", "origin", "refs/heads/feature:refs/heads/main"])
    }

    func testPublishArgumentsSetUpstream() {
        XCTAssertEqual(
            GitClient.pushArguments(remote: "work", localBranch: "topic",
                                    remoteBranch: "topic", setUpstream: true),
            ["push", "-u", "work", "refs/heads/topic:refs/heads/topic"])
    }

    func testForceWithLeasePrecedesTheRefspec() {
        XCTAssertEqual(
            GitClient.pushArguments(remote: "origin", localBranch: "main",
                                    remoteBranch: "main", setUpstream: false,
                                    forceWithLease: true),
            ["push", "--force-with-lease", "origin", "refs/heads/main:refs/heads/main"])
    }

    /// A branch called `-x` is a legal ref. Fully qualifying the refspec is what
    /// keeps it out of option position.
    func testALeadingDashBranchCannotReachOptionPosition() {
        XCTAssertEqual(
            GitClient.pushArguments(remote: "origin", localBranch: "-x",
                                    remoteBranch: "-x", setUpstream: false),
            ["push", "origin", "refs/heads/-x:refs/heads/-x"],
            "the dash-leading branch stays inside the qualified refspec")
    }

    // MARK: - Remote.split

    func testSplitRejectsAnEmptyBranchHalf() {
        XCTAssertNil(Remote.split(upstream: "origin/", among: [origin]))
        XCTAssertNil(Remote.split(upstream: nil, among: [origin]))
        XCTAssertNil(Remote.split(upstream: "origin", among: [origin]))
    }
}
