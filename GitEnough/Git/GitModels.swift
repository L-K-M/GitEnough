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
    public let refName: String         // canonical full ref, e.g. "refs/heads/main"
    public let isRemote: Bool
    public let isHead: Bool
    public let upstream: String?       // e.g. "origin/main"
    public let ahead: Int
    public let behind: Int
    /// True when the branch still has an upstream *configured* but the remote
    /// ref no longer exists (deleted on the remote, then pruned) —
    /// `%(upstream:track)` reports `[gone]`. Pull against it fails (push
    /// simply re-creates the remote branch), so the UI flags it. Defaulted so
    /// call sites without tracking data (and the memberwise initializer's
    /// existing callers) stay unchanged.
    public var upstreamGone: Bool = false
    /// When the branch tip was last committed to (for-each-ref
    /// `%(committerdate:iso8601-strict)`); nil when the caller's format
    /// omitted it. The "which branches are alive?" datum — renders relative
    /// ("3 days ago") in the branch lists and doubles as stale-branch triage
    /// next to the ahead/behind columns. `var` with a default so existing
    /// memberwise call sites (tests) compile unchanged.
    public var lastCommitDate: Date? = nil

    public var id: String { refName }

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

    /// Selects the remote named by an upstream (`remote/branch`). Remote names
    /// may themselves contain slashes, so split-at-first-slash is ambiguous;
    /// the longest configured prefix is the exact match.
    ///
    /// Deliberately **does not** refuse the ambiguous case that
    /// `PushCapability.resolve` refuses: with no `localBranch` to compare, this
    /// falls through to longest-prefix. That divergence is intended — this feeds
    /// labels and other read-only surfaces, where a best guess beats an empty
    /// field, while Push must not guess about where it writes.
    ///
    /// So `split`'s `remoteWasGuessed` is deliberately ignored here rather than
    /// overlooked: a label naming the wrong one of two plausible remotes is a
    /// cosmetic error. Any caller that *writes* must read that flag —
    /// `PushCapability.resolve` does, and withholds force push on it.
    public static func preferred(for upstream: String?, among remotes: [Remote]) -> Remote? {
        split(upstream: upstream, among: remotes)?.remote
            ?? remotes.first { $0.name == "origin" } ?? remotes.first
    }

    /// Every configured remote whose name could be the remote half of
    /// `upstream`. More than one means the string is genuinely ambiguous:
    /// with `origin` and `origin/features` both configured, `origin/features/x`
    /// is two well-formed readings and nothing in the string picks between them.
    public static func splitCandidates(upstream: String?, among remotes: [Remote]) -> [Remote] {
        guard let upstream else { return [] }
        // Via `branchHalf`, so that "is this a well-formed reading" has exactly
        // one definition here. Equivalent on real input — a candidate can only
        // leave an empty branch half when the upstream ends in a slash, which
        // `git check-ref-format` rejects — but the equivalence is a fact about
        // git, not about this filter, and the next reader shouldn't have to
        // rediscover it.
        return remotes.filter { branchHalf(of: upstream, under: $0) != nil }
    }

    /// Whether `upstream` reads two or more ways under the configured remotes
    /// with nothing to choose between them.
    ///
    /// Lives here, beside `split`, on purpose. `PushCapability.resolve` refuses
    /// when this is true and otherwise takes what `split` returns — so the two
    /// have to agree, and the way they stop agreeing is a future edit to one
    /// tie-break that the other never hears about. Same rule, same file, one
    /// definition.
    public static func isAmbiguous(upstream: String, among remotes: [Remote],
                                   localBranch: String?) -> Bool {
        let candidates = splitCandidates(upstream: upstream, among: remotes)
        guard candidates.count > 1 else { return false }
        guard let localBranch else { return true }
        return !candidates.contains { branchHalf(of: upstream, under: $0) == localBranch }
    }

    /// The branch half of `upstream` under `remote`, or nil when that reading
    /// leaves nothing behind.
    public static func branchHalf(of upstream: String, under remote: Remote) -> String? {
        guard upstream.hasPrefix(remote.name + "/") else { return nil }
        let branch = String(upstream.dropFirst(remote.name.count + 1))
        return branch.isEmpty ? nil : branch
    }

    /// Splits an upstream ref (`origin/main`, `up/stream/topic`) into the
    /// configured remote it names and the branch **on that remote**.
    ///
    /// The branch half matters as much as the remote half: a local branch may
    /// track a differently-named upstream, and the upstream is what the app's
    /// own ahead/behind counters are measured against — so it is the ref Push
    /// has to move. Returns nil when no configured remote is a prefix, which
    /// means the upstream names a remote that no longer exists.
    /// `localBranch`, when known, breaks the tie that nested remote names create.
    /// With remotes `origin` and `origin/features`, the upstream
    /// `origin/features/x` splits two ways and the string alone cannot say
    /// which: it is `origin/features` + `x`, or `origin` + `features/x`. The
    /// branch half matching the local branch name settles it in the case that
    /// actually occurs — a branch tracking its own name on a remote — and
    /// longest-prefix remains the fallback.
    ///
    /// The unambiguous answer is git's own `branch.<name>.remote`, available as
    /// `%(upstream:remotename)` from the `for-each-ref` that already builds the
    /// branch list. Carrying it through would remove the guess entirely; see
    /// ANALYSIS.md.
    ///
    /// `remoteWasGuessed` reports which of those two things happened, because
    /// the caller cannot tell from the result and the difference decides
    /// whether force push is offered. It is true whenever more than one reading
    /// existed — the tie-break and the longest-prefix fallback are both guesses,
    /// however plausible. Returning it rather than letting callers recompute
    /// `splitCandidates` keeps the rule in one place: a future `split` that
    /// resolves multiple readings *definitively* (o-G4) reports `false` here and
    /// every caller follows, where a caller counting candidates itself would
    /// still be withholding force push on knowledge.
    public static func split(upstream: String?,
                             among remotes: [Remote],
                             localBranch: String? = nil)
        -> (remote: Remote, branch: String, remoteWasGuessed: Bool)? {
        guard let upstream else { return nil }
        // `Remote.branchHalf`, not a nested copy of it: the nested version
        // returned "" where the shared one returns nil, so the same rule had two
        // spellings that had to be kept in step by hand.
        let matches = splitCandidates(upstream: upstream, among: remotes)
        let matched = matches.first(where: { remote in
            guard let localBranch else { return false }
            return branchHalf(of: upstream, under: remote) == localBranch
        }) ?? matches.max(by: { $0.name.count < $1.name.count })
        guard let matched, let branch = branchHalf(of: upstream, under: matched) else {
            return nil
        }
        return (matched, branch, matches.count > 1)
    }

    /// Short host-ish label for the status bar, e.g. "github.com/L-K-M/GitEnough".
    public var displayHost: String {
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
    public var isRename: Bool { stagedStatus == .renamed || unstagedStatus == .renamed }
    public var isCopy: Bool { stagedStatus == .copied || unstagedStatus == .copied }

    /// Paths that should move together for stage/unstage/discard. A rename
    /// includes its source deletion; a copy does not — its source is an
    /// independent tracked file whose staged or worktree edits must survive an
    /// action on the copy destination.
    public var affectedPaths: [String] {
        if isRename, let originalPath {
            return [path, originalPath]
        }
        return [path]
    }

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
    public var isDirty: Bool { !staged.isEmpty || !unstaged.isEmpty || !conflicted.isEmpty }

    /// Number of changed paths, not status buckets. A partially staged file is
    /// present in both `staged` and `unstaged`, while an unmerged path may also
    /// be represented in `conflicted`; each still counts as one file to a user.
    public var changeCount: Int {
        var paths = Set<String>()
        paths.reserveCapacity(staged.count + unstaged.count + conflicted.count)
        for change in staged { paths.insert(change.path) }
        for change in unstaged { paths.insert(change.path) }
        for change in conflicted { paths.insert(change.path) }
        return paths.count
    }
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
