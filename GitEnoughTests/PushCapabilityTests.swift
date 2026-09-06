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
    /// A remote whose own name contains a slash still splits on the longest
    /// configured name, rather than at the first slash.
    ///
    /// Two remotes or one changes only whether the answer is a guess. With just
    /// `up/stream` configured there is a single reading of `up/stream/port`, so
    /// this is knowledge and force push stays armed.
    func testSlashNamedRemoteSplitsOnTheLongestConfiguredName() {
        XCTAssertEqual(
            PushCapability.resolve(status: status(head: "port", upstream: "up/stream/port"),
                                   remotes: [upStream]),
            .push(remote: "up/stream", localBranch: "port", remoteBranch: "port"))

        // Add `up` and the same string reads two ways — `up` + `stream/port`,
        // or `up/stream` + `port`. The local branch name settles it, and the
        // branch half is still resolved correctly, which is what this test is
        // about; the remote half is now a tie-break match, so force push is
        // withheld until `o-G4` can ask git which remote the branch tracks.
        let contested = PushCapability.resolve(
            status: status(head: "port", upstream: "up/stream/port"),
            remotes: [up, upStream])
        XCTAssertEqual(
            contested,
            .pushToGuessedRemote(remote: "up/stream", localBranch: "port",
                                 remoteBranch: "port"))
        XCTAssertFalse(contested.allowsForcePush)
        XCTAssertTrue(contested.tracksAnUpstream)
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
        // `--force-if-includes` rides along on git 2.30+, so the expectation is
        // built from the same gate the builder uses rather than hardcoded — the
        // point of the test is flag *order* relative to the refspec.
        let lease = GitClient.supportsForceIfIncludes
            ? ["--force-with-lease", "--force-if-includes"]
            : ["--force-with-lease"]
        XCTAssertEqual(
            GitClient.pushArguments(remote: "origin", localBranch: "main",
                                    remoteBranch: "main", setUpstream: false,
                                    forceWithLease: true).arguments,
            ["push"] + lease + ["--", "origin", "refs/heads/main:refs/heads/main"])
    }

    /// `--force-with-lease` on its own compares against the remote-tracking
    /// ref, and this app moves that ref behind the user's back — `autoFetchIfDue`
    /// fetches on a timer when enabled. Reproduced against git 2.43: rewrite
    /// locally, fetch, then force-push with a bare lease and a teammate's commit
    /// is destroyed; add `--force-if-includes` and the push is rejected instead.
    func testForcePushCarriesForceIfIncludesWhereGitSupportsIt() throws {
        try XCTSkipUnless(GitClient.supportsForceIfIncludes,
                          "git older than 2.30 has no --force-if-includes")
        XCTAssertTrue(
            GitClient.forcePushArguments(remote: "origin", localBranch: "main",
                                         remoteBranch: "main")
                .arguments.contains("--force-if-includes"),
            "a lease that a background fetch can satisfy is not a lease")
    }

    /// The gate is a version comparison on git's banner, so pin the shapes real
    /// gits emit — Apple's and Windows' both carry extra components.
    func testGitVersionParsing() {
        XCTAssertTrue(GitClient.parseVersion("git version 2.43.0").map { $0 >= (2, 30) } == true)
        XCTAssertTrue(GitClient.parseVersion("git version 2.39.3 (Apple Git-146)")
            .map { $0 >= (2, 30) } == true)
        XCTAssertTrue(GitClient.parseVersion("git version 2.30.1.windows.1")
            .map { $0 >= (2, 30) } == true)
        XCTAssertTrue(GitClient.parseVersion("git version 2.29.2").map { $0 >= (2, 30) } == false)
        XCTAssertNil(GitClient.parseVersion("git version banana"))
        XCTAssertNil(GitClient.parseVersion(""))
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

        // With no local branch to compare, longest prefix still decides — a
        // *guess* on the same ambiguity `resolve` refuses. Safe only for callers
        // that never move refs (labels, the status bar); anything that writes
        // must pass a `localBranch` so the ambiguity can be refused. See o-G4.
        XCTAssertEqual(
            Remote.split(upstream: "origin/features/x", among: remotes)?.remote.name,
            "origin/features")
    }

    /// The tie-break matters because it decides where a push *lands*, so pin it
    /// at the level push actually goes through, not just at `Remote.split`.
    func testResolveCarriesTheNestedRemoteTieBreakThrough() {
        let remotes = [origin, nestedFeatures]

        // Both readings exist, so *whichever* the tie-break picks is a guess —
        // including the one that happens to be right.
        XCTAssertEqual(
            PushCapability.resolve(
                status: status(head: "x", upstream: "origin/features/x"), remotes: remotes),
            .pushToGuessedRemote(remote: "origin/features", localBranch: "x", remoteBranch: "x"))

        // Known-wrong by design: a local `features/x` that actually tracks
        // `origin/features`'s branch `x` matches the *other* reading and lands
        // here. Pinned so the behaviour is visible rather than accidental —
        // o-G4 in ANALYSIS.md owns the fix, and this expectation flips when
        // `%(upstream:remotename)` lands on RepoStatus.
        let guessed = PushCapability.resolve(
            status: status(head: "features/x", upstream: "origin/features/x"),
            remotes: remotes)
        XCTAssertEqual(
            guessed,
            .pushToGuessedRemote(remote: "origin", localBranch: "features/x",
                                 remoteBranch: "features/x"))

        // The containment that makes the known-wrong answer survivable until
        // o-G4. A plain push to a guessed ref is recoverable; a
        // `--force-with-lease` to one is not, and the lease guards against
        // staleness, never against the wrong target.
        XCTAssertFalse(guessed.allowsForcePush,
                       "a tie-break match is still a guess; it must not arm "
                       + "--force-with-lease on a remote the user never chose")
        XCTAssertTrue(guessed.tracksAnUpstream,
                      "…but it does have an upstream to count against, so the "
                      + "ahead badge still applies")
    }

    /// A remote whose name is the *whole* upstream is not a second reading:
    /// `origin/main` under remote `origin/main` would leave an empty branch
    /// half, and `git check-ref-format` rejects a ref ending in a slash, so it
    /// cannot arise. Pinned because reading it as a candidate would make this
    /// ordinary setup refuse as ambiguous.
    func testARemoteNamedLikeTheWholeUpstreamIsNotACandidate() {
        let remotes = [origin, Remote(name: "origin/main",
                                      url: "https://example.com/m.git")]
        XCTAssertEqual(Remote.splitCandidates(upstream: "origin/main", among: remotes)
                        .map(\.name), ["origin"])
        XCTAssertFalse(Remote.isAmbiguous(upstream: "origin/main", among: remotes,
                                          localBranch: "topic"))
        XCTAssertEqual(
            PushCapability.resolve(
                status: status(head: "topic", upstream: "origin/main"), remotes: remotes),
            .push(remote: "origin", localBranch: "topic", remoteBranch: "main"),
            "one well-formed reading is not a guess, so force push stays armed")
        XCTAssertEqual(Remote.preferred(for: "origin/main", among: remotes)?.name, "origin")
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

    /// An upstream with no remote left to account for it, in the most extreme
    /// form: every remote deleted. Its own reason, not the generic `.noRemotes`.
    ///
    /// This replaces `testNoRemotesIsReportedBeforeAnyRefIsChosen`, which fed
    /// the same input and expected `.noRemotes`. Moving the `.noRemotes` guard
    /// below the upstream block changed that answer deliberately, and leaving
    /// both tests standing meant the suite asserted two things about one call.
    func testAnUpstreamWithNoRemotesAtAllStillNamesTheUpstream() {
        let orphaned = PushCapability.resolve(
            status: status(head: "main", upstream: "origin/main"), remotes: [])
        XCTAssertEqual(
            orphaned,
            .unavailable(.upstreamRemoteMissing(upstream: "origin/main", branch: "main")))
        XCTAssertTrue(orphaned.help.contains("origin/main"),
                      "the user who most needs the specific guidance must get it")

        // No upstream and no remotes is still just "no remotes" — the generic
        // message is right when there is genuinely nothing more to say.
        let bare = PushCapability.resolve(status: status(head: "main"), remotes: [])
        XCTAssertEqual(bare, .unavailable(.noRemotes))
        XCTAssertTrue(bare.help.contains("no remotes"))
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
