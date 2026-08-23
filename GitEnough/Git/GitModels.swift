import Foundation

/// A ref attached to a commit (branch head, tag, remote branch, or the HEAD marker),
/// parsed from `%D` decorations. Shown as a chip in the history list.
public struct RefDecoration: Hashable, Identifiable {
    public enum Kind: Hashable {
        case head           // the "HEAD ->" marker itself
        case localBranch    // "main"
        case remoteBranch   // "origin/main"
        case tag            // "tag: v1.0"
    }
    public let kind: Kind
    public let name: String

    public var id: String { "\(kind)-\(name)" }
}

/// One commit as loaded from `git log`.
public struct Commit: Identifiable, Hashable {
    public let hash: String
    public let parents: [String]
    public let author: String
    public let email: String
    public let date: Date?
    public let subject: String
    public let decorations: [RefDecoration]

    public var id: String { hash }
    public var shortHash: String { String(hash.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    /// True when HEAD points at this commit (its decoration list contains .head).
    public var isHead: Bool { decorations.contains { $0.kind == .head } }
}

/// A local or remote branch, from `git for-each-ref`.
public struct Branch: Identifiable, Hashable {
    public let name: String            // short name, e.g. "main" or "origin/feature"
    public let isRemote: Bool
    public let isHead: Bool
    public let upstream: String?       // e.g. "origin/main"
    public let ahead: Int
    public let behind: Int

    public var id: String { (isRemote ? "remote/" : "local/") + name }

    /// For a remote branch like "origin/main", the local name "main" a tracking
    /// checkout would get. Nil for HEAD symref entries (e.g. "origin/HEAD").
    public var localNameForRemote: String? {
        guard isRemote else { return nil }
        guard let slash = name.firstIndex(of: "/") else { return nil }
        let rest = name[name.index(after: slash)...]
        return rest == "HEAD" ? nil : String(rest)
    }
}

/// A remote, from `git remote -v` (fetch and push lines collapsed by name).
public struct Remote: Identifiable, Hashable {
    public let name: String
    public let url: String

    public var id: String { name }

    /// Short host-ish label for the status bar, e.g. "github.com/L-K-M/GitEnough".
    public var displayHost: String {
        var text = url
        if let range = text.range(of: #"^git@([^:]+):"#, options: .regularExpression) {
            let host = text[range].dropFirst(4).dropLast(1)
            let pathPart = text[range.upperBound...]
            return "\(host)/\(pathPart)".replacingOccurrences(of: ".git", with: "")
        }
        if let parsed = URL(string: text), let host = parsed.host {
            return host + parsed.path.replacingOccurrences(of: ".git", with: "")
        }
        return text
    }
}

/// The staged/unstaged state of a single path, from status porcelain v2.
/// `x` is the staged column, `y` the worktree column ('.' = unchanged).
public struct FileChange: Identifiable, Hashable {
    public enum Status: String, Hashable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case untracked = "?"
        case typeChanged = "T"
        case unmerged = "U"

        public var label: String {
            switch self {
            case .added: return "Added"
            case .modified: return "Modified"
            case .deleted: return "Deleted"
            case .renamed: return "Renamed"
            case .copied: return "Copied"
            case .untracked: return "Untracked"
            case .typeChanged: return "Type changed"
            case .unmerged: return "Conflicted"
            }
        }
    }

    public let path: String
    public let originalPath: String?    // set for renames/copies
    public let stagedStatus: Status?    // X column
    public let unstagedStatus: Status?  // Y column

    public var id: String { path + "|" + (originalPath ?? "") }

    public var isStaged: Bool { stagedStatus != nil }
    public var hasUnstaged: Bool { unstagedStatus != nil }
    public var isConflicted: Bool { stagedStatus == .unmerged || unstagedStatus == .unmerged }
    public var isUntracked: Bool { stagedStatus == .untracked || unstagedStatus == .untracked }

    /// The most relevant status for display.
    public var displayStatus: Status { stagedStatus ?? unstagedStatus ?? .modified }
}

/// Parsed `git status --porcelain=v2 --branch`.
public struct RepoStatus: Equatable {
    public var head: String?                 // branch name, or nil when detached/empty
    public var headHash: String?             // OID column (hash or "(initial)")
    public var upstream: String?
    public var ahead: Int = 0
    public var behind: Int = 0
    public var staged: [FileChange] = []     // entries with an X status
    public var unstaged: [FileChange] = []   // entries with a Y status or untracked
    public var conflicted: [FileChange] = [] // unmerged entries (subset of the above)

    public static let empty = RepoStatus()

    public var isDetached: Bool { head == nil && headHash != nil && headHash != "(initial)" }
    public var isUnborn: Bool { headHash == "(initial)" }
    public var isDirty: Bool { !staged.isEmpty || !unstaged.isEmpty }
    public var changeCount: Int { staged.count + unstaged.count }
}

/// A stash entry from `git stash list`.
public struct StashEntry: Identifiable, Hashable {
    public let index: Int          // stash@{n}
    public let branch: String      // branch the stash was taken on
    public let message: String

    public var id: Int { index }
    public var ref: String { "stash@{\(index)}" }
}

/// One file row in a commit's changed-files list (`git diff-tree --name-status`).
public struct CommitFile: Identifiable, Hashable {
    public let status: FileChange.Status
    public let path: String
    public let originalPath: String?

    public var id: String { path }
}

/// Everything shown in the commit detail pane.
public struct CommitDetail: Equatable {
    public var hash: String
    public var author: String
    public var email: String
    public var date: Date?
    public var parents: [String]
    public var subject: String
    public var body: String
    public var files: [CommitFile]
}

/// Which sequencer operation git currently has in progress.
public enum InProgressOperation: Equatable {
    case merge
    case rebase
    case cherryPick
    case revert

    /// Noun for banners and buttons ("Merge", "Rebase", …).
    public var noun: String {
        switch self {
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        }
    }
}

/// The state of an in-progress sequencer operation (merge, rebase, cherry-pick,
/// revert), for the conflict-resolution UI.
public struct MergeState: Equatable {
    public var operation: InProgressOperation?
    /// Human label, e.g. "Merge branch 'feature'" or "Rebasing main".
    public var operationLabel: String?
    public var conflictedFiles: [String]

    public var isInProgress: Bool { operation != nil }
    public var isResolvingConflicts: Bool { !conflictedFiles.isEmpty }
}
