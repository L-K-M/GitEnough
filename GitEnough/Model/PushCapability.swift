import Foundation

/// The one decision used by every Push surface. It distinguishes a normal
/// push from first-time publication and carries an actionable reason when the
/// repository is not in a state Git can safely push.
///
/// Both actionable cases carry the exact refs involved. That is deliberate: a
/// bare `git push` delegates the decision to the user's `push.default`, which
/// can push branches the user never selected — with `push.default = matching`,
/// a single force push rewrites every branch that exists on both sides. The
/// button, the tooltip, the confirmation dialog and the command therefore all
/// read the same resolved refs, and there is nothing left for a config setting
/// to reinterpret.
public enum PushCapability: Equatable {

    public enum UnavailableReason: Equatable {
        case detachedHead
        case unbornHead
        case noRemotes
        case noCurrentBranch
        /// `branch.<name>.remote` names a remote that is no longer configured.
        /// Carries the whole upstream string rather than a guessed remote half:
        /// splitting at the first slash would name `origin` for a vanished
        /// `origin/features`, which was never the branch's remote.
        case upstreamRemoteMissing(upstream: String, branch: String)
        /// Two or more configured remotes are prefixes of the upstream string
        /// and nothing available distinguishes them.
        case ambiguousUpstream(upstream: String, branch: String)
        /// `branch.<name>.remote = "."` — the branch tracks another *local*
        /// branch, which git reports without a remote prefix (`main`, not
        /// `origin/main`). No remote ever accounted for it, so saying one went
        /// missing sends the user looking for something that never existed.
        case localUpstream(upstream: String, branch: String)

        /// The same reason, phrased for Force Push.
        ///
        /// Derived from `message` rather than written twice, so the two cannot
        /// drift — and guarded rather than assumed, so a future case that
        /// starts differently degrades to the plain sentence instead of losing
        /// its first eleven characters. `PushCapabilityTests` pins that every
        /// case carries the prefix, which is what keeps the guard from
        /// silently becoming the normal path.
        public var forcePushMessage: String {
            let pushPrefix = "Can't push: "
            guard message.hasPrefix(pushPrefix) else { return message }
            return "Can't force push: " + String(message.dropFirst(pushPrefix.count))
        }

        public var message: String {
            switch self {
            case .detachedHead:
                return "Can't push: HEAD is detached. Check out or create a branch first."
            case .unbornHead:
                return "Can't push: this repository has no commits yet. Create the first commit before publishing."
            case .noRemotes:
                return "Can't push: this repository has no remotes configured. Add a remote first."
            case .noCurrentBranch:
                return "Can't push: the current branch is unavailable. Refresh the repository, then check out or create a branch."
            case .upstreamRemoteMissing(let upstream, let branch):
                return "Can't push: \(branch) tracks “\(upstream)”, whose remote is no longer configured. Add it back, or set a new upstream for this branch."
            case .ambiguousUpstream(let upstream, let branch):
                return "Can't push: “\(upstream)” matches more than one configured remote, so GitEnough can't tell which ref \(branch) tracks. Rename one of the remotes, or set the upstream again to disambiguate."
            case .localUpstream(let upstream, let branch):
                return "Can't push: \(branch) tracks the local branch “\(upstream)”, not a branch on a remote. Set an upstream on a remote first."
            }
        }
    }

    /// A branch with a usable upstream. `remoteBranch` can differ from
    /// `localBranch` when the branch tracks a differently-named upstream.
    case push(remote: String, localBranch: String, remoteBranch: String)
    /// The same push, except that the *remote* half was settled by a guess.
    ///
    /// With `origin` and `origin/features` both configured, `origin/features/x`
    /// reads two ways and only `branch.<name>.remote` knows which — which this
    /// app does not read yet (`o-G4`). `resolve` refuses outright when nothing
    /// chooses between the readings, and otherwise takes the one whose branch
    /// half matches the local branch name. That tie-break is a good guess, not
    /// knowledge, so it pushes but does not force: a plain push to a guessed
    /// ref is recoverable, and `--force-with-lease` on the wrong remote is not.
    /// The lease protects against staleness, never against the wrong target.
    case pushToGuessedRemote(remote: String, localBranch: String, remoteBranch: String)
    /// A branch with **no** upstream configured: push it and set one. Not the
    /// same as an upstream that names a missing remote — see
    /// `.upstreamRemoteMissing`, which this deliberately does not absorb.
    case publish(remote: String, branch: String)
    case unavailable(UnavailableReason)

    /// Pure resolution from a loaded repository snapshot. State checks precede
    /// upstream checks deliberately: detached and unborn HEADs have no upstream,
    /// but that does not make either one a publishable local branch.
    public static func resolve(status: RepoStatus, remotes: [Remote]) -> PushCapability {
        if status.isUnborn { return .unavailable(.unbornHead) }
        if status.isDetached { return .unavailable(.detachedHead) }
        guard let head = status.head else { return .unavailable(.noCurrentBranch) }
        // One block, so the ambiguity rule and the resolution that follows it
        // cannot answer differently. `resolve` deciding "not ambiguous" by one
        // rule while `Remote.split` selects by another is how the refusal would
        // start firing on strings split would have resolved, or vice versa.
        if let upstream = status.upstream {
            // Refuse a guess before making one. With `origin` and
            // `origin/features` both configured, "origin/features/x" is two
            // well-formed readings; the local branch name settles it when it
            // happens to match one of them, and when it matches neither,
            // nothing does.
            //
            // Resolving anyway is the same mistake `upstreamRemoteMissing`
            // exists to prevent, and worse here: the result is a `.push`, which
            // *enables force push* — so one confirmation could
            // `--force-with-lease` a ref on a remote the user never chose.
            // "Only git knows" is an argument for refusing, not for picking the
            // longer prefix.
            if Remote.isAmbiguous(upstream: upstream, among: remotes, localBranch: head) {
                return .unavailable(.ambiguousUpstream(upstream: upstream, branch: head))
            }
            // A *configured* upstream that no configured remote can account for
            // is its own state, not the same as having none.
            //
            // Publishing looks like the helpful answer — it would push somewhere
            // real and re-point the branch — but it is the app deciding, on one
            // unconfirmed click, to rewrite `branch.<name>.remote` and to pick
            // the destination by a name heuristic (`origin`, else whichever
            // remote git happens to list first). Worse, `.publish` disallows
            // force push, so a fallback remote that already carries a diverged
            // branch of the same name rejects the push as non-fast-forward with
            // no way forward.
            //
            // Before this type carried refs, `.push` here ran a bare `git push`,
            // which failed loudly against the missing remote. That was the right
            // outcome for the wrong reason; say it deliberately instead.
            guard let match = Remote.split(upstream: upstream, among: remotes,
                                           localBranch: head) else {
                // A slash-less upstream is `branch.<name>.remote = "."`, not a
                // remote that vanished: git reports a local-tracking branch's
                // upstream with no remote half at all. Verified against git
                // 2.43 — `git branch --track topic main` writes `remote = "."`
                // and porcelain v2 emits `# branch.upstream main`.
                guard upstream.contains("/") else {
                    return .unavailable(
                        .localUpstream(upstream: upstream, branch: head))
                }
                return .unavailable(
                    .upstreamRemoteMissing(upstream: upstream, branch: head))
            }
            // Asked, not re-derived. Counting candidates here would be a second
            // spelling of `split`'s own tie-break rule, and the two would part
            // company at exactly the moment that matters: once `split` can
            // resolve multiple readings definitively from `%(upstream:remotename)`
            // (o-G4), a candidate count would still be withholding force push on
            // an answer git had just given us.
            return match.remoteWasGuessed
                ? .pushToGuessedRemote(remote: match.remote.name,
                                       localBranch: head,
                                       remoteBranch: match.branch)
                : .push(remote: match.remote.name,
                        localBranch: head,
                        remoteBranch: match.branch)
        }
        // After the upstream block, not before it: a repository with a
        // configured upstream and *no* remotes is the most extreme case of "an
        // upstream nothing accounts for", and reporting the generic `.noRemotes`
        // there gave the user who most needs the specific guidance the least of
        // it — no branch name, no vanished upstream, no way forward.
        guard let fallback = remotes.first(where: { $0.name == "origin" }) ?? remotes.first else {
            return .unavailable(.noRemotes)
        }
        return .publish(remote: fallback.name, branch: head)
    }

    public var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// True when this is a push to an existing upstream — so an ahead count is
    /// measured against something real and can be shown.
    public var tracksAnUpstream: Bool {
        switch self {
        case .push, .pushToGuessedRemote: return true
        case .publish, .unavailable: return false
        }
    }

    /// Only a branch whose upstream is *known* has something safe to overwrite.
    ///
    /// This is why it was never a synonym for `tracksAnUpstream`: one asks "is
    /// there a remote branch to count against", the other "is there remote
    /// history we are certain enough about to destroy". `.pushToGuessedRemote`
    /// answers yes to the first and no to the second — an ahead count against a
    /// guessed ref is a cosmetic error, a force push to one is not.
    ///
    /// Switched rather than `if case`, for the reason `forcePushResolution`
    /// gives: a new capability must force a decision here rather than inherit
    /// `false` from a fallthrough. This is the predicate that decides whether
    /// remote history can be overwritten; silence is the wrong default for it.
    public var allowsForcePush: Bool {
        switch self {
        case .push: return true
        case .pushToGuessedRemote, .publish, .unavailable: return false
        }
    }

    public var label: String {
        if case .publish = self { return "Publish" }
        return "Push"
    }

    public var help: String {
        switch self {
        case .push(let remote, let local, let remoteBranch):
            return local == remoteBranch
                ? "Push \(local) to \(remote) (⇧⌘P)"
                : "Push \(local) to \(remote)/\(remoteBranch) (⇧⌘P)"
        case .pushToGuessedRemote(let remote, let local, let remoteBranch):
            return "Push \(local) to \(remote)/\(remoteBranch) (⇧⌘P). "
                + "More than one configured remote could account for this "
                + "branch's upstream; GitEnough matched the branch name. Force "
                + "push is off until the upstream says which remote it means."
        case .publish(let remote, let branch):
            return "Push \(branch) and set upstream to \(remote) (⇧⌘P)"
        case .unavailable(let reason):
            return reason.message
        }
    }
}
