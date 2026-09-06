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
    /// Nested remote names, single-sourced: the whole point of these fixtures is
    /// that one name is a prefix of another, and four hand-built copies of a
    /// subtle name is how one of them quietly stops being subtle.
    private let nestedFeatures = Remote(name: "origin/features",
                                        url: "https://example.com/f.git")
    private let up = Remote(name: "up", url: "https://example.com/a.git")
    private let upStream = Remote(name: "up/stream", url: "https://example.com/b.git")

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
        // Neither unborn (headHash would be "(initial)") nor detached (headHash
        // would be an OID) — the shape a half-read status snapshot produces, and
        // its own reason rather than a fallback into one of the other two.
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: nil, headHash: nil),
                                   remotes: [origin]),
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
    /// renamed or removed. A configured upstream that no configured remote
    /// accounts for is its own state, not the same as having none.
    ///
    /// This used to resolve to `.publish(remote: "origin")`, which reads as
    /// helpful and isn't: one unconfirmed click would rewrite
    /// `branch.main.remote` and pick the destination by a name heuristic —
    /// `origin` if it exists, otherwise whichever remote git lists first. And
    /// because `.publish` disallows force push, a fallback remote already
    /// carrying a diverged `main` would reject it as non-fast-forward with no
    /// way forward.
    func testAnUpstreamNamingAMissingRemoteIsItsOwnReason() {
        let resolved = PushCapability.resolve(
            status: status(head: "main", upstream: "gone/main"), remotes: [origin])
        XCTAssertEqual(resolved,
                       .unavailable(.upstreamRemoteMissing(upstream: "gone/main", branch: "main")))
        XCTAssertFalse(resolved.allowsForcePush,
                       "nothing is resolved, so there is certainly nothing to force onto")
        XCTAssertTrue(resolved.help.contains("gone"),
                      "the tooltip must name the remote that went missing")
    }

    /// The fourth half-read status shape: the branch name parsed but the hash
    /// has not landed. Pinned so a refactor reordering the unborn/detached
    /// checks — both of which key off `headHash` — cannot change it silently.
    func testABranchWithoutAHashStillResolves() {
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: "main", headHash: nil),
                                   remotes: [origin]),
            .publish(remote: "origin", branch: "main"),
            "the push refspec never uses the hash, so this resolves normally")
    }

    // MARK: - The command itself

    func testPushArgumentsAreFullyQualifiedOnBothSides() {
        XCTAssertEqual(
            GitClient.pushArguments(remote: "origin", localBranch: "feature",
                                    remoteBranch: "main", setUpstream: false).arguments,
            ["push", "--", "origin", "refs/heads/feature:refs/heads/main"])
    }

    func testPublishArgumentsSetUpstream() {
        XCTAssertEqual(
            GitClient.pushArguments(remote: "work", localBranch: "topic",
                                    remoteBranch: "topic", setUpstream: true).arguments,
            ["push", "-u", "--", "work", "refs/heads/topic:refs/heads/topic"])
    }

    func testForceWithLeasePrecedesTheRefspec() {
        XCTAssertEqual(
            GitClient.pushArguments(remote: "origin", localBranch: "main",
                                    remoteBranch: "main", setUpstream: false,
                                    forceWithLease: true).arguments,
            ["push", "--force-with-lease", "--", "origin", "refs/heads/main:refs/heads/main"])
    }

    /// A branch called `-x` is a legal ref. Fully qualifying the refspec is what
    /// keeps it out of option position.
    func testALeadingDashBranchCannotReachOptionPosition() {
        XCTAssertEqual(
            GitClient.pushArguments(remote: "origin", localBranch: "-x",
                                    remoteBranch: "-x", setUpstream: false).arguments,
            ["push", "--", "origin", "refs/heads/-x:refs/heads/-x"],
            "the dash-leading branch stays inside the qualified refspec")
    }

    // MARK: - Remote.split

    func testSplitRejectsAnEmptyBranchHalf() {
        XCTAssertNil(Remote.split(upstream: "origin/", among: [origin]))
        XCTAssertNil(Remote.split(upstream: nil, among: [origin]))
        XCTAssertNil(Remote.split(upstream: "origin", among: [origin]))
        XCTAssertNil(Remote.split(upstream: "elsewhere/main", among: [origin]),
                     "an upstream on no configured remote does not split")
    }

    func testSplitPicksTheLongestMatchingRemoteName() {
        let simple = Remote.split(upstream: "origin/main", among: [origin])
        XCTAssertEqual(simple?.remote.name, "origin")
        XCTAssertEqual(simple?.branch, "main")

        let nested = Remote.split(upstream: "up/stream/port", among: [up, upStream])
        XCTAssertEqual(nested?.remote.name, "up/stream", "longest prefix wins")
        XCTAssertEqual(nested?.branch, "port")
    }

    /// Nested remote names make the string genuinely ambiguous: with `origin`
    /// and `origin/features` both configured, `origin/features/x` is either
    /// `origin/features` + `x` or `origin` + `features/x`. The local branch
    /// name settles it when it can — but only *when* it can, and a match is a
    /// guess too. A local `features/x` that tracks `origin/features`'s branch
    /// `x` produces the same upstream string and matches the **other** reading,
    /// so it resolves to `origin` + `features/x`: confidently, and wrongly. The
    /// heuristic has no failure it can detect. Only `%(upstream:remotename)` on
    /// `RepoStatus` settles nested names for real — tracked as **o-G4** in
    /// ANALYSIS.md, so this pin of a known-wrong answer has an owner rather than
    /// sitting in CI defending itself indefinitely.
    func testSplitUsesTheLocalBranchToBreakANestedRemoteTie() {
        let remotes = [origin, nestedFeatures]

        let asOrigin = Remote.split(upstream: "origin/features/x", among: remotes,
                                    localBranch: "features/x")
        XCTAssertEqual(asOrigin?.remote.name, "origin")
        XCTAssertEqual(asOrigin?.branch, "features/x")

        let asNested = Remote.split(upstream: "origin/features/x", among: remotes,
                                    localBranch: "x")
        XCTAssertEqual(asNested?.remote.name, "origin/features")
        XCTAssertEqual(asNested?.branch, "x")

        // With no local branch to compare, longest prefix still decides.
        XCTAssertEqual(
            Remote.split(upstream: "origin/features/x", among: remotes)?.remote.name,
            "origin/features")
    }

    /// The tie-break matters because it decides where a push *lands*, so pin it
    /// at the level push actually goes through, not just at `Remote.split`.
    func testResolveCarriesTheNestedRemoteTieBreakThrough() {
        let remotes = [origin, nestedFeatures]

        XCTAssertEqual(
            PushCapability.resolve(
                status: status(head: "x", upstream: "origin/features/x"), remotes: remotes),
            .push(remote: "origin/features", localBranch: "x", remoteBranch: "x"))

        XCTAssertEqual(
            PushCapability.resolve(
                status: status(head: "features/x", upstream: "origin/features/x"),
                remotes: remotes),
            .push(remote: "origin", localBranch: "features/x", remoteBranch: "features/x"))
    }

    /// When the local branch name matches *neither* reading, nothing settles the
    /// ambiguity — so this refuses instead of guessing.
    ///
    /// An earlier version of this test pinned the longest-prefix guess as
    /// expected behaviour, on the grounds that it was "documented". That was
    /// wrong twice over. It is the same mistake `upstreamRemoteMissing` exists
    /// to prevent, and worse: the guess resolves to `.push`, which *enables
    /// force push*, so one confirmation could `--force-with-lease` a ref on a
    /// remote the user never chose. And pinning it meant CI would have defended
    /// the wrong answer against the fix.
    func testResolveRefusesAnAmbiguousUpstreamRatherThanGuessing() {
        let resolved = PushCapability.resolve(
            status: status(head: "trunk", upstream: "origin/features/x"),
            remotes: [origin, nestedFeatures])

        XCTAssertEqual(resolved, .unavailable(
            .ambiguousUpstream(upstream: "origin/features/x", branch: "trunk")))
        XCTAssertFalse(resolved.allowsForcePush,
                       "an unresolved upstream must not offer to overwrite one")
        XCTAssertTrue(resolved.help.contains("origin/features/x"),
                      "the message must name the string it cannot read")
    }

    /// One candidate remote is not ambiguous, however nested its name looks.
    func testASingleCandidateRemoteResolvesEvenWithoutABranchNameMatch() {
        XCTAssertEqual(
            PushCapability.resolve(
                status: status(head: "trunk", upstream: "origin/features/x"),
                remotes: [nestedFeatures]),
            .push(remote: "origin/features", localBranch: "trunk", remoteBranch: "x"))
    }

    func testTheRemoteOperandCannotBeReadAsAnOption() {
        // `git remote add -- -f <url>` is accepted, so a remote really can be
        // called "-f"; `--` is what keeps it an operand.
        let args = GitClient.pushArguments(remote: "-f", localBranch: "main",
                                           remoteBranch: "main", setUpstream: false).arguments
        XCTAssertEqual(args, ["push", "--", "-f", "refs/heads/main:refs/heads/main"])
    }

    func testForcePushArgumentsAreTheOnesForcePushRuns() {
        XCTAssertEqual(
            GitClient.forcePushArguments(remote: "origin", localBranch: "main",
                                         remoteBranch: "main").arguments,
            GitClient.pushArguments(remote: "origin", localBranch: "main",
                                    remoteBranch: "main", setUpstream: false,
                                    forceWithLease: true).arguments,
            "the confirmation dialog and the command it describes share one definition")
        // Also for operands that look like options. The dash tests exercise
        // `pushArguments`; if `forcePushArguments` ever grew its own formatting
        // and dropped the `--` or the qualification, only the *destructive* path
        // would carry the regression and the suite would stay green.
        XCTAssertEqual(
            GitClient.forcePushArguments(remote: "-f", localBranch: "-x",
                                         remoteBranch: "main").arguments,
            GitClient.pushArguments(remote: "-f", localBranch: "-x", remoteBranch: "main",
                                    setUpstream: false, forceWithLease: true).arguments,
            "the equivalence holds for option-shaped operands too")
    }
}
