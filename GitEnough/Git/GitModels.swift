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
    let refName: String         // canonical full ref, e.g. "refs/heads/main"
    let isRemote: Bool
    let isHead: Bool
    let upstream: String?       // e.g. "origin/main"
    let ahead: Int
    let behind: Int
    /// True when the branch still has an upstream *configured* but the remote
    /// ref no longer exists (deleted on the remote, then pruned) —
    /// `%(upstream:track)` reports `[gone]`. Pull against it fails (push
    /// simply re-creates the remote branch), so the UI flags it. Defaulted so
    /// call sites without tracking data (and the memberwise initializer's
    /// existing callers) stay unchanged.
    var upstreamGone: Bool = false
    /// When the branch tip was last committed to (for-each-ref
    /// `%(committerdate:iso8601-strict)`); nil when the caller's format
    /// omitted it. The "which branches are alive?" datum — renders relative
    /// ("3 days ago") in the branch lists and doubles as stale-branch triage
    /// next to the ahead/behind columns. `var` with a default so existing
    /// memberwise call sites (tests) compile unchanged.
    var lastCommitDate: Date? = nil

    var id: String { refName }

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

    /// Selects the remote named by an upstream (`remote/branch`). Remote names
    /// may themselves contain slashes, so split-at-first-slash is ambiguous;
    /// the longest configured prefix is the exact match.
    static func preferred(for upstream: String?, among remotes: [Remote]) -> Remote? {
        if let upstream,
           let matched = remotes
            .filter({ upstream.hasPrefix($0.name + "/") })
            .max(by: { $0.name.count < $1.name.count }) {
            return matched
        }
        return remotes.first { $0.name == "origin" } ?? remotes.first
    }

    /// Short host-ish label for the status bar, e.g. "github.com/L-K-M/GitEnough".
    var displayHost: String {
        let text = url
        if let range = text.range(of: #"^git@([^:]+):"#, options: .regularExpression) {
            let host = text[range].dropFirst(4).dropLast(1)
            let pathPart = text[range.upperBound...]
            return "\(host)/\(Self.strippingGitSuffix(String(pathPart)))"
        }
        if let parsed = URL(string: text), let host = parsed.host {
            return host + Self.strippingGitSuffix(parsed.path)
        }
        return text
    }

    /// Strips one trailing ".git" — and only a trailing one. Replacing every
    /// occurrence would mangle names that merely contain it: a GitHub Pages
    /// remote "user.github.io.git" must become "user.github.io", not
    /// "userhub.io".
    private static func strippingGitSuffix(_ path: String) -> String {
        path.hasSuffix(".git") ? String(path.dropLast(4)) : path
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
    var isRename: Bool { stagedStatus == .renamed || unstagedStatus == .renamed }
    var isCopy: Bool { stagedStatus == .copied || unstagedStatus == .copied }

    /// Paths that should move together for stage/unstage/discard. A rename
    /// includes its source deletion; a copy does not — its source is an
    /// independent tracked file whose staged or worktree edits must survive an
    /// action on the copy destination.
    var affectedPaths: [String] {
        if isRename, let originalPath {
            return [path, originalPath]
        }
        return [path]
    }

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
