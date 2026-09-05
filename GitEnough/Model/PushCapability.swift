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
            }
        }
    }

    /// A branch with a usable upstream. `remoteBranch` can differ from
    /// `localBranch` when the branch tracks a differently-named upstream.
    case push(remote: String, localBranch: String, remoteBranch: String)
    /// A branch with no usable upstream: push it and set one.
    case publish(remote: String, branch: String)
    case unavailable(UnavailableReason)

    /// Pure resolution from a loaded repository snapshot. State checks precede
    /// upstream checks deliberately: detached and unborn HEADs have no upstream,
    /// but that does not make either one a publishable local branch.
    public static func resolve(status: RepoStatus, remotes: [Remote]) -> PushCapability {
        if status.isUnborn { return .unavailable(.unbornHead) }
        if status.isDetached { return .unavailable(.detachedHead) }
        guard let head = status.head else { return .unavailable(.noCurrentBranch) }
        guard let fallback = remotes.first(where: { $0.name == "origin" }) ?? remotes.first else {
            return .unavailable(.noRemotes)
        }
        if let upstream = Remote.split(upstream: status.upstream, among: remotes,
                                       localBranch: head) {
            return .push(remote: upstream.remote.name,
                         localBranch: head,
                         remoteBranch: upstream.branch)
        }
        // Either there is no upstream, or the one configured names a remote that
        // no longer exists (renamed or removed). Publishing is the right answer
        // to both: it pushes to a remote the user can see in the label and
        // re-points the upstream at something real. Falling back to a plain push
        // would send the branch somewhere nothing in the UI named.
        return .publish(remote: fallback.name, branch: head)
    }

    public var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Only a branch that already has an upstream has anything to overwrite.
    public var allowsForcePush: Bool {
        if case .push = self { return true }
        return false
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
        case .publish(let remote, let branch):
            return "Push \(branch) and set upstream to \(remote) (⇧⌘P)"
        case .unavailable(let reason):
            return reason.message
        }
    }
}
