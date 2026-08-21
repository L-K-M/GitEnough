import Foundation

/// A ref attached to a commit (branch head, tag, remote branch, or the HEAD marker),
/// parsed from `%D` decorations. Shown as a chip in the history list.
struct RefDecoration: Hashable, Identifiable {
    enum Kind: Hashable {
        case head           // the "HEAD ->" marker itself
        case localBranch    // "main"
        case remoteBranch   // "origin/main"
        case tag            // "tag: v1.0"
    }
    let kind: Kind
    let name: String

    var id: String { "\(kind)-\(name)" }
}

/// One commit as loaded from `git log`.
struct Commit: Identifiable, Hashable {
    let hash: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date?
    let subject: String
    let decorations: [RefDecoration]

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }

    /// True when HEAD points at this commit (its decoration list contains .head).
    var isHead: Bool { decorations.contains { $0.kind == .head } }
}

/// A local or remote branch, from `git for-each-ref`.
struct Branch: Identifiable, Hashable {
    let name: String            // short name, e.g. "main" or "origin/feature"
    let isRemote: Bool
    let isHead: Bool
    let upstream: String?       // e.g. "origin/main"
    let ahead: Int
    let behind: Int

    var id: String { (isRemote ? "remote/" : "local/") + name }

    /// For a remote branch like "origin/main", the local name "main" a tracking
    /// checkout would get. Nil for HEAD symref entries (e.g. "origin/HEAD").
    var localNameForRemote: String? {
        guard isRemote else { return nil }
        guard let slash = name.firstIndex(of: "/") else { return nil }
        let rest = name[name.index(after: slash)...]
        return rest == "HEAD" ? nil : String(rest)
    }
}

/// A remote, from `git remote -v` (fetch and push lines collapsed by name).
struct Remote: Identifiable, Hashable {
    let name: String
    let url: String

    var id: String { name }

    /// Short host-ish label for the status bar, e.g. "github.com/L-K-M/GitEnough".
    var displayHost: String {
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
struct FileChange: Identifiable, Hashable {
    enum Status: String, Hashable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case untracked = "?"
        case typeChanged = "T"
        case unmerged = "U"

        var label: String {
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

    let path: String
    let originalPath: String?    // set for renames/copies
    let stagedStatus: Status?    // X column
    let unstagedStatus: Status?  // Y column

    var id: String { path + "|" + (originalPath ?? "") }

    var isStaged: Bool { stagedStatus != nil }
    var hasUnstaged: Bool { unstagedStatus != nil }
    var isConflicted: Bool { stagedStatus == .unmerged || unstagedStatus == .unmerged }
    var isUntracked: Bool { stagedStatus == .untracked || unstagedStatus == .untracked }

    /// The most relevant status for display.
    var displayStatus: Status { stagedStatus ?? unstagedStatus ?? .modified }
}

/// Parsed `git status --porcelain=v2 --branch`.
struct RepoStatus: Equatable {
    var head: String?                 // branch name, or nil when detached/empty
    var headHash: String?             // OID column (hash or "(initial)")
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var staged: [FileChange] = []     // entries with an X status
    var unstaged: [FileChange] = []   // entries with a Y status or untracked
    var conflicted: [FileChange] = [] // unmerged entries (subset of the above)

    static let empty = RepoStatus()

    var isDetached: Bool { head == nil && headHash != nil && headHash != "(initial)" }
    var isUnborn: Bool { headHash == "(initial)" }
    var isDirty: Bool { !staged.isEmpty || !unstaged.isEmpty || !conflicted.isEmpty }

    /// Number of changed paths, not status buckets. A partially staged file is
    /// present in both `staged` and `unstaged`, while an unmerged path may also
    /// be represented in `conflicted`; each still counts as one file to a user.
    var changeCount: Int {
        var paths = Set<String>()
        paths.reserveCapacity(staged.count + unstaged.count + conflicted.count)
        for change in staged { paths.insert(change.path) }
        for change in unstaged { paths.insert(change.path) }
        for change in conflicted { paths.insert(change.path) }
        return paths.count
    }
}

/// A stash entry from `git stash list`.
struct StashEntry: Identifiable, Hashable {
    let index: Int          // stash@{n}
    let branch: String      // branch the stash was taken on
    let message: String

    var id: Int { index }
    var ref: String { "stash@{\(index)}" }
}

/// One file row in a commit's changed-files list (`git diff-tree --name-status`).
struct CommitFile: Identifiable, Hashable {
    let status: FileChange.Status
    let path: String
    let originalPath: String?

    var id: String { path }
}

/// Everything shown in the commit detail pane.
struct CommitDetail: Equatable {
    var hash: String
    var author: String
    var email: String
    var date: Date?
    var parents: [String]
    var subject: String
    var body: String
    var files: [CommitFile]
}

/// Which sequencer operation git currently has in progress.
enum InProgressOperation: Equatable {
    case merge
    case rebase
    case cherryPick
    case revert

    /// Noun for banners and buttons ("Merge", "Rebase", …).
    var noun: String {
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
struct MergeState: Equatable {
    var operation: InProgressOperation?
    /// Human label, e.g. "Merge branch 'feature'" or "Rebasing main".
    var operationLabel: String?
    var conflictedFiles: [String]

    var isInProgress: Bool { operation != nil }
    var isResolvingConflicts: Bool { !conflictedFiles.isEmpty }
}
