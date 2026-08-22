import Foundation

/// The one decision used by every Push surface. It distinguishes a normal
/// push from first-time publication and carries an actionable reason when the
/// repository is not in a state Git can safely push.
enum PushCapability: Equatable {

    enum UnavailableReason: Equatable {
        case detachedHead
        case unbornHead
        case noRemotes
        case noCurrentBranch

        var message: String {
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

    case push
    case publish(remote: String)
    case unavailable(UnavailableReason)

    /// Pure resolution from a loaded repository snapshot. State checks precede
    /// upstream checks deliberately: detached and unborn HEADs have no upstream,
    /// but that does not make either one a publishable local branch.
    static func resolve(status: RepoStatus, remotes: [Remote]) -> PushCapability {
        if status.isUnborn { return .unavailable(.unbornHead) }
        if status.isDetached { return .unavailable(.detachedHead) }
        guard status.head != nil else { return .unavailable(.noCurrentBranch) }
        guard let remote = remotes.first(where: { $0.name == "origin" }) ?? remotes.first else {
            return .unavailable(.noRemotes)
        }
        if status.upstream != nil { return .push }
        return .publish(remote: remote.name)
    }

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    var label: String {
        if case .publish = self { return "Publish" }
        return "Push"
    }

    var help: String {
        switch self {
        case .push:
            return "Push (⇧⌘P)"
        case .publish(let remote):
            return "Push and set upstream to \(remote) (⇧⌘P)"
        case .unavailable(let reason):
            return reason.message
        }
    }
}
