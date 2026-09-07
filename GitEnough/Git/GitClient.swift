import Foundation

/// Typed git operations for one repository. Every method is synchronous (see
/// GitShell) — `RepoViewModel` calls them from its serial background queue.
///
/// All repo-scoped commands run as `git -C <worktree> <cmd>` with arguments passed
/// as an array (never through a shell), so spaces and shell metacharacters are safe.
/// Repo-reported paths also use literal pathspec magic: `--` ends option parsing,
/// but does not stop git from interpreting `*`, `?`, `[` or `:(...)` in a filename.
public final class GitClient {

    public let shell: GitShell
    public let worktree: URL

    /// When set, every git invocation this client makes is recorded (begin,
    /// finish, exit code, stderr tail) so the UI can show what is running right
    /// now and what ran before. Owned by the repo's view model; nil in tests
    /// and one-off clients means no recording. Assign exactly once, before
    /// the first command runs — reads happen on background queues without
    /// locking.
    public var activityLog: GitActivityLog?

    public init(worktree: URL, shell: GitShell = .shared) {
        self.worktree = worktree
        self.shell = shell
    }

    /// A path reported by git, forced to use literal pathspec semantics when it
    /// is handed back to a git command. `--` only ends option parsing: without
    /// this prefix, filenames containing `*`, `?`, `[` or a `:(...)` signature
    /// can select other paths (or fail to select themselves).
    public static func literalPathspec(_ path: String) -> String {
        ":(literal)" + path
    }

    private static func literalPathspecs(_ paths: [String]) -> [String] {
        paths.map { literalPathspec($0) }
    }

    // MARK: - Logging wrappers

    /// Every call below goes through these two wrappers instead of touching
    /// `shell` directly, so the activity log always reflects reality — when a
    /// pre-commit hook hangs, the log shows `commit -F -` running for minutes.
    @discardableResult
    private func run(_ args: [String], in directory: URL?,
                     environmentOverrides: [String: String] = [:]) throws -> GitResult {
        guard let log = activityLog else {
            return try shell.run(
                args, in: directory, environmentOverrides: environmentOverrides)
        }
        let id = log.begin(arguments: args)
        do {
            let result = try shell.run(
                args, in: directory, environmentOverrides: environmentOverrides)
            log.finish(id, exitCode: result.exitCode, stderr: result.stderr)
            return result
        } catch {
            // GitError.message carries git's real stderr (hook output!) — never
            // fall back to a generic localizedDescription for git failures.
            let gitError = error as? GitError
            log.finish(id, exitCode: gitError?.exitCode,
                       stderr: gitError?.message ?? error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    private func runChecked(_ args: [String], in directory: URL?,
                            stdin: String? = nil,
                            environmentOverrides: [String: String] = [:]) throws -> GitResult {
        guard let log = activityLog else {
            return try shell.runChecked(
                args, in: directory, stdin: stdin,
                environmentOverrides: environmentOverrides)
        }
        let id = log.begin(arguments: args)
        do {
            let result = try shell.runChecked(
                args, in: directory, stdin: stdin,
                environmentOverrides: environmentOverrides)
            log.finish(id, exitCode: result.exitCode, stderr: result.stderr)
            return result
        } catch {
            let gitError = error as? GitError
            log.finish(id, exitCode: gitError?.exitCode,
                       stderr: gitError?.message ?? error.localizedDescription)
            throw error
        }
    }

    /// Adds Git's global read-only guard after a leading `-C <worktree>` so
    /// activity formatting can still strip the worktree path. Centralizing the
    /// flag prevents a new query from quietly reintroducing optional index
    /// refreshes and lock contention.
    public static func readOnlyArguments(_ args: [String]) -> [String] {
        let insertionIndex = args.count >= 2 && args[0] == "-C" ? 2 : 0
        if args.indices.contains(insertionIndex),
           args[insertionIndex] == "--no-optional-locks" {
            return args
        }
        var result = args
        result.insert("--no-optional-locks", at: insertionIndex)
        return result
    }

    private func runRead(_ args: [String], in directory: URL?) throws -> GitResult {
        try run(Self.readOnlyArguments(args), in: directory)
    }

    private func runReadChecked(_ args: [String], in directory: URL?) throws -> GitResult {
        try runChecked(Self.readOnlyArguments(args), in: directory)
    }

    // MARK: - Discovery / validation

    /// True when `directory` is inside a git worktree.
    public static func isRepository(at directory: URL) -> Bool {
        guard let result = try? GitShell.shared.run(
            readOnlyArguments(["rev-parse", "--is-inside-work-tree"]),
            in: directory) else { return false }
        return result.exitCode == 0
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The canonical top-level path of the worktree containing `directory`
    /// (so adding `repo/Documentation/` registers the repo root).
    public static func topLevel(of directory: URL) -> URL? {
        guard let result = try? GitShell.shared.run(
            readOnlyArguments(["rev-parse", "--show-toplevel"]), in: directory),
            result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The `.git` directory (a file for linked worktrees — resolved by git).
    public func gitDir() -> URL? {
        guard let result = try? runRead(
            ["-C", worktree.path, "rev-parse", "--absolute-git-dir"], in: nil),
            result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func version() -> String? {
        guard let result = try? GitShell.shared.run(["--version"], in: nil),
              result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `(major, minor)` from a `git --version` banner, or nil when it doesn't
    /// look like one. Pure, so the version gate below is testable without a git.
    ///
    /// Handles the shapes real gits emit: `git version 2.43.0`,
    /// `git version 2.39.3 (Apple Git-146)`, `git version 2.30.1.windows.1`.
    public static func parseVersion(_ banner: String) -> (major: Int, minor: Int)? {
        let fields = banner.split(separator: " ")
        // Anchored on git's literal `version` token when the banner has one, so
        // a numeric token in wrapper output ("shim 1.2: git version 2.43.0")
        // cannot be misread as the version and cached as "too old" for the life
        // of the process. Falling back to scanning every field keeps a bare
        // `2.43.0` — which some wrappers print instead of a full banner —
        // parsing as it did. That fallback is why the anchored form is worth
        // having at all: a purely anchored parse would return nil there.
        // Anchored: the first numeric token after `version` is the answer.
        // Unanchored: the *last* one is, because a wrapper prints its own
        // version before git's, never after — `shim 3.5: git 2.20` must read
        // (2, 20), and first-match read (3, 5).
        //
        // The two misreads are not symmetric, which is why this is worth the
        // extra pass. Reading too low silently drops `--force-if-includes`, and
        // the dialog already says it cannot confirm the version. Reading too
        // high appends the flag on a git that lacks it, and every force push
        // then fails with "unknown option" until the app restarts, because the
        // probe is a `static let` cached for the process.
        let anchor = fields.firstIndex(of: "version")
        let start = anchor.map { $0 + 1 } ?? fields.startIndex
        var parsed: (major: Int, minor: Int)?
        for field in fields[start...] {
            let parts = field.split(separator: ".")
            guard parts.count >= 2,
                  let major = Int(parts[0]), let minor = Int(parts[1]) else { continue }
            parsed = (major, minor)
            if anchor != nil { break }
        }
        return parsed
    }

    /// Whether this git understands `--force-if-includes` (2.30, Dec 2020).
    ///
    /// Resolved once per process. `pushArguments` stays referentially
    /// transparent within a run, which is what the confirmation dialog needs:
    /// it and the client call the same function and get the same command.
    ///
    /// That is also why an *indeterminate* probe — `version()` nil, or a banner
    /// `parseVersion` cannot read — is cached as `false` rather than retried.
    /// Retrying looks safer and is not: a probe that failed when the dialog
    /// opened and succeeded when the user confirmed would build a different
    /// command, and `forcePush(confirming:)` would refuse a legitimate push
    /// with "the upstream changed while the confirmation was open". The
    /// staleness guarantee needs this constant within a run more than it needs
    /// a second chance at the answer.
    ///
    /// The user-visible half is handled where it belongs: the confirmation
    /// dialog reads this flag and, when it is false, says it cannot confirm the
    /// git version rather than promising a protection that is not there.
    /// `RepoViewModel.init` warms it on the repo queue so the first touch is
    /// not a subprocess on the main thread.
    /// Public because `pushArguments` and `forcePushArguments` are public and
    /// name it as a default argument value — Swift requires a default on a
    /// public function to be visible wherever that function is. It sits beside
    /// `version()` and `parseVersion(_:)`, which were already public; internal
    /// was the anomaly.
    public static let supportsForceIfIncludes: Bool = {
        guard let banner = version(), let v = parseVersion(banner) else { return false }
        return versionSupportsForceIfIncludes(v)
    }()

    /// The gate itself, as a pure function of a parsed version.
    ///
    /// Extracted so a test can pin *this* comparison rather than its own copy of
    /// it. `testTheVersionGateComparison` used to write `>= (2, 30)` inline, so
    /// moving the threshold or regressing the operator changed production and
    /// left the test green — and the only end-to-end check sits behind
    /// `XCTSkipUnless(supportsForceIfIncludes)`, meaning a gate regression makes
    /// the runner *skip* the assertion that would have caught it. On every host.
    /// Deliberately *not* an overload of the property above: `pushArguments`
    /// names `supportsForceIfIncludes` as a default argument value, and putting
    /// a function into that name's overload set makes a resolvable-but-fragile
    /// expression out of one that is currently unambiguous. A distinct name
    /// costs nothing and cannot go wrong.
    public static func versionSupportsForceIfIncludes(
        _ version: (major: Int, minor: Int)) -> Bool {
        (version.major, version.minor) >= (2, 30)
    }

    // MARK: - Status / branches / remotes

    public func status() throws -> RepoStatus {
        let result = try runReadChecked(
            ["-C", worktree.path, "status", "--porcelain=v2", "--branch",
             "--untracked-files=normal"],
            in: nil)
        return GitParsers.parseStatus(result.stdout)
    }

    public func branches() throws -> [Branch] {
        let f = GitParsers.fieldSep
        // Derive display names from the full refs: `refname:short` becomes
        // ambiguous when, for example, a branch and tag share the same name —
        // hence `%(upstream)`, not `%(upstream:short)`.
        // committerdate in strict ISO 8601 parses with the same formatter as
        // the log format and yields an absolute Date (sortable, testable),
        // rendered relative ("3 days ago") in the branch lists.
        let format = "%(refname)\(f)%(refname:short)\(f)%(upstream)\(f)%(upstream:track)\(f)%(HEAD)\(f)%(committerdate:iso8601-strict)"
        let result = try runReadChecked(
            ["-C", worktree.path, "for-each-ref",
             "--format=\(format)", "refs/heads", "refs/remotes"],
            in: nil)
        return GitParsers.parseBranches(result.stdout)
    }

    public func remotes() throws -> [Remote] {
        let result = try runReadChecked(["-C", worktree.path, "remote", "-v"], in: nil)
        return GitParsers.parseRemotes(result.stdout)
    }

    /// The remote's default branch (its HEAD): `refs/remotes/origin/HEAD` →
    /// "main". The symref is established by clone and maintained by recent
    /// fetches; nil when git hasn't set it yet — callers then fall back to
    /// "main"/"master" guessing. Used as the base branch of a new pull request.
    public func remoteDefaultBranch(remote: String) -> String? {
        guard let result = try? runRead(
            ["-C", worktree.path, "symbolic-ref", "--short",
             "refs/remotes/\(remote)/HEAD"], in: nil),
            result.exitCode == 0 else { return nil }
        let short = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard short.hasPrefix("\(remote)/") else { return nil }
        return String(short.dropFirst(remote.count + 1))
    }

    // MARK: - History

    /// Refs that must never seed the history graph nor decorate its commits:
    /// the stash (older stashes live in refs/stash's reflog, which --all does not
    /// traverse), filter-branch backups, bisect state, prefetched commits, notes
    /// trees, replace mappings, and post-rewrite bookkeeping. None are history
    /// the user wants to see.
    public static let hiddenRefs = ["refs/stash", "refs/original/*", "refs/bisect/*",
                             "refs/prefetch/*", "refs/notes/*", "refs/replace/*",
                             "refs/rewritten/*"]

    /// Newest-first, topologically ordered commits across all refs — the input to
    /// the graph layout. `skip`/`limit` drive the "Load more" pagination.
    public func log(limit: Int, skip: Int = 0) throws -> [Commit] {
        let f = GitParsers.fieldSep
        let r = GitParsers.recordSep
        let format = "%H\(f)%P\(f)%an\(f)%ae\(f)%aI\(f)%D\(f)%s\(r)"
        // --exclude filters the ref set of the *next* --all, so it must precede
        // it. --decorate-refs-exclude is position-independent; grouped for clarity.
        // --decorate=full makes %D emit full ref names (refs/heads/…,
        // refs/remotes/…, tag: refs/tags/…), so parseDecorations classifies by
        // exact prefix instead of guessing remote-ness from a "/" in the name.
        var args = ["-C", worktree.path, "log", "--decorate=full"]
        args += Self.hiddenRefs.map { "--exclude=\($0)" }
        args += ["--all"]
        args += Self.hiddenRefs.map { "--decorate-refs-exclude=\($0)" }
        args += ["--topo-order", "--date-order",
                 "--pretty=tformat:\(format)",
                 "--max-count=\(limit)"]
        if skip > 0 { args.append("--skip=\(skip)") }
        let result = try runReadChecked(args, in: nil)
        return GitParsers.parseLog(result.stdout)
    }

    /// Full header + changed-file list for the detail pane.
    public func commitDetail(_ hash: String) throws -> CommitDetail? {
        let f = GitParsers.fieldSep
        let r = GitParsers.recordSep
        let format = "%H\(f)%an\(f)%ae\(f)%aI\(f)%P\(f)%s\(f)%b\(r)"
        // -m --first-parent: for merges, show the diff against the first parent.
        let result = try runReadChecked(
            ["-C", worktree.path, "show", "-m", "--first-parent",
             "--format=\(format)", "--name-status", "--no-color", hash],
            in: nil)
        return GitParsers.parseCommitDetail(result.stdout)
    }

    /// Hashes of the commits `git push` would send: HEAD's commits that its
    /// upstream doesn't have (`rev-list @{upstream}..HEAD`). Empty when no
    /// upstream is configured, on a detached/unborn HEAD, or on any error —
    /// the history markers built from this are best-effort decoration.
    public func unpushedCommitHashes() throws -> Set<String> {
        let result = try run(
            ["-C", worktree.path, "--no-optional-locks",
             "rev-list", "@{upstream}..HEAD"], in: nil)
        guard result.exitCode == 0 else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    // MARK: - Diffs

    /// Flags every patch-producing read passes. `--no-ext-diff` is the one that
    /// matters: `diff.external` (what difftastic's own install instructions set,
    /// `git config --global diff.external difft`) replaces the patch with the
    /// external tool's rendered output. Parsing that as a unified diff colours
    /// it at random, and feeding it to the commit-message model describes the
    /// wrong thing entirely. It is also a process launched on the repo's serial
    /// queue, so a pager-ish tool would block every repository operation behind
    /// it. Harmless on `--stat`, which never invokes the driver — passed there
    /// anyway so no reader has to work out which reads are exposed.
    ///
    /// Deliberately *not* `--no-textconv`. A `diff.<driver>.textconv` filter,
    /// configured through gitattributes, is a different mechanism and usually a
    /// wanted one: it is how a repository makes a binary format readable in a
    /// diff at all. Suppressing it would hand the diff pane — and the
    /// commit-message model — raw binary where the repository has arranged for
    /// prose. `--no-ext-diff` removes a *replacement* for the patch; textconv
    /// only changes what the patch is computed over.
    ///
    /// The security half of that tradeoff, stated so it is a decision rather
    /// than an omission: a textconv filter is an **arbitrary executable named by
    /// the repository being viewed**, so rendering a diff in a repo that arrived
    /// with a hostile `.git/config` runs it.
    ///
    /// Note the asymmetry, because it is easy to get backwards: git also runs
    /// that repository's *hooks*, but only when the user commits, checks out or
    /// merges — a deliberate action. **textconv runs on render.** Measured
    /// against git 2.43: one `git diff --no-color --no-ext-diff -- <path>`, with
    /// no hooks present and no mutating command, executed the filter twice (once
    /// per side). `--no-ext-diff` does not suppress it; it is a different
    /// mechanism. So for someone who merely opens a hostile clone and looks at
    /// it, textconv is the *first* repo-named executable reached, not a small
    /// addition to a larger existing hole.
    ///
    /// Keeping it is still the right call — suppressing it costs every
    /// legitimate binary-format diff and would not make opening an untrusted
    /// working copy safe, which is not a property this app has. But that is a
    /// reason to do the trust work, not to treat this as minor. Tracked as
    /// `o-L14` in ANALYSIS.md.
    ///
    /// That trust work has a second half worth naming here, because it is easy
    /// to miss when the risk is filed under "runs code": the filter's *output*
    /// is what `stagedDiff()` hands the commit-message model. An untrusted
    /// textconv therefore also writes directly into an LLM prompt. File
    /// contents already reach that prompt, so this widens no boundary on its
    /// own — but a per-repo trust gate that only stops process execution and
    /// leaves the model input alone would be solving half the problem.
    private static let patchReadFlags = ["--no-color", "--no-ext-diff"]

    /// Unified diff for one worktree/index path.
    public func diff(path: String, staged: Bool) throws -> String {
        var args = ["-C", worktree.path, "diff"] + Self.patchReadFlags
        if staged { args.append("--staged") }
        args.append(contentsOf: ["--", Self.literalPathspec(path)])
        return try runReadChecked(args, in: nil).stdout
    }

    /// Untracked files have no index entry; diff them against /dev/null.
    /// A path ending in "/" is a fully-untracked directory collapsed by
    /// `--untracked-files=normal`: `diff --no-index /dev/null dir/` fails
    /// outright ("Could not access 'dir/null'"), so directories instead get a
    /// synthetic listing of their untracked contents — honest and useful where
    /// a patch is impossible.
    public func diffForUntracked(path: String) throws -> String {
        if path.hasSuffix("/") {
            return try untrackedDirectoryListing(path: path)
        }
        let result = try runRead(
            ["-C", worktree.path, "diff"] + Self.patchReadFlags
                + ["--no-index", "--", "/dev/null", path],
            in: nil)
        // --no-index exits 1 when files differ (i.e. always, here); 0/1 are both OK.
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw GitError(message: result.stderr, exitCode: result.exitCode)
        }
        return result.stdout
    }

    /// The "diff" for a collapsed untracked directory: the untracked files
    /// inside it (`git ls-files --others --exclude-standard`), one per line,
    /// which DiffView renders as plain context lines. Staging and discarding
    /// the directory already work via the directory path itself.
    private func untrackedDirectoryListing(path: String) throws -> String {
        // Literal pathspec magic: without it, a directory named "foo*/" would
        // glob-match siblings, and a "weird:name/" would read as pathspec magic.
        let result = try runChecked(
            ["-C", worktree.path, "ls-files", "--others", "--exclude-standard",
             "-z", "--", ":(literal)" + path],
            in: nil)
        let files = result.stdout.components(separatedBy: "\0")
            .filter { !$0.isEmpty }.sorted()
        // Cap the listing: an accidentally-unignored node_modules/ holds tens
        // of thousands of entries, and rendering them all is exactly the stall
        // this cheap synthetic "diff" exists to avoid.
        let shown = files.prefix(Self.listingCap)
        var lines = ["Untracked directory: \(path)",
                     "\(files.count) file\(files.count == 1 ? "" : "s") — stage the directory to diff its contents."]
        lines.append(contentsOf: shown.map { "  \($0)" })
        if files.count > shown.count {
            lines.append("  … and \(files.count - shown.count) more")
        }
        return lines.joined(separator: "\n")
    }

    /// Maximum entries rendered for one untracked directory.
    private static let listingCap = 200

    /// Patch of one file within a commit (for the detail pane).
    public func commitFileDiff(hash: String, path: String) throws -> String {
        try runReadChecked(
            // `--format=` is load-bearing, not tidiness: `DiffParser`'s input
            // contract is patch-only output. A commit message reaching it would
            // arrive while the parser is outside a hunk, where a bullet starting
            // "-" colours as a deletion and a quoted "@@" opens a phantom hunk.
            ["-C", worktree.path, "show", "-m", "--first-parent", "--format="]
                + Self.patchReadFlags + [hash, "--", Self.literalPathspec(path)],
            in: nil).stdout
    }

    /// Full staged patch — the input for LLM commit-message generation.
    public func stagedDiff() throws -> String {
        try runReadChecked(
            ["-C", worktree.path, "diff", "--staged"] + Self.patchReadFlags,
            in: nil).stdout
    }

    /// `--stat` summary of the staged changes (always sent to the model in full).
    public func stagedDiffStat() throws -> String {
        try runReadChecked(
            ["-C", worktree.path, "diff", "--staged", "--stat"] + Self.patchReadFlags,
            in: nil).stdout
    }

    /// True when an existing gitignore rule already covers `path`
    /// (`git check-ignore`), so "Ignore" doesn't pile redundant specific
    /// entries under a broader pattern like `*.log` or `build/`.
    public func isIgnored(path: String) -> Bool {
        guard let result = try? runRead(
            ["-C", worktree.path, "check-ignore", "-q", "--", path], in: nil) else { return false }
        return result.exitCode == 0
    }

    // MARK: - Staging

    /// Stages the named paths. Unlike `stageAll`, this takes no view on conflicts:
    /// naming a path *is* the user saying "this one is resolved", which is what
    /// git's own `add` means during a merge. The UI never routes a conflicted
    /// path here — porcelain v2 `u` entries land in `RepoStatus.conflicted`
    /// alone, so they are absent from the staged/unstaged lists these actions
    /// read — and the deliberate gesture goes through `markResolved`, which
    /// refuses while conflict markers are still in the file. A new caller that
    /// can reach an unmerged path should call `markResolved` instead.
    ///
    /// The invariant is pinned by `GitParsersTests`
    /// (`testEveryUnmergedShapeStaysOutOfTheStagedAndUnstagedLists`) rather than
    /// asserted here, so it fails at the point of drift — the parser — instead
    /// of costing a `git diff` subprocess on every stage.
    public func stage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runChecked(
            ["-C", worktree.path, "add", "--"] + Self.literalPathspecs(paths), in: nil)
    }

    /// Stages everything — but never while a path is unmerged.
    ///
    /// `git add -A` on an unmerged path stages the **worktree content**, conflict
    /// markers and all, and clears the unmerged state, which is git's way of
    /// saying "I resolved this". Verified against git 2.43: during a conflicted
    /// merge, `git add -A` turns `u UU … f.txt` into `1 M. … f.txt`, the commit
    /// then succeeds, and the committed file contains
    /// `<<<<<<< HEAD … ======= … >>>>>>> other`.
    ///
    /// The check and the `add` are two separate git processes, so a conflict
    /// created *between* them — by a terminal, an editor integration — can still
    /// slip through. This narrows the window to milliseconds; it does not close
    /// it, and only an index lock would.
    ///
    /// In the app that is worse than the raw command, because the conflict UI is
    /// rendered from the unmerged entries: staging them makes the warning
    /// disappear and the Commit button light up. The user is shown every signal
    /// that the conflict is resolved, at the moment it has been buried.
    ///
    /// So the guard lives here rather than only in a button's `disabled`: both
    /// front ends call this, and only one of them renders conflicts at all.
    public func stageAll() throws {
        let conflicted = try conflictedPaths()
        guard conflicted.isEmpty else {
            throw GitError(
                message: Self.stageAllRefusalPrefix + " while \(conflicted.count) file\(conflicted.count == 1 ? " is" : "s are") still conflicted (\(Self.namingFiles(conflicted))). Staging one " + Self.conflictStagingConsequence + ". Resolve each first, then stage it.",
                exitCode: -1)
        }
        try runChecked(["-C", worktree.path, "add", "-A"], in: nil)
    }

    /// The opening words of `stageAll`'s refusal, shared with the test that has
    /// to tell that refusal apart from any other `GitError`.
    ///
    /// `exitCode: -1` cannot do that job — fourteen sites in this module use it
    /// for "synthesized rather than from git", `GitShell`'s "git isn't
    /// installed" among them — so the test matches the prefix. Which made the
    /// sentence's first words load-bearing in a file that has no idea, and a
    /// reword to "Cannot stage everything" would have turned the tests red while
    /// the guard kept working perfectly. Internal rather than public: this is a
    /// seam for the tests, not surface for a front end.
    static let stageAllRefusalPrefix = "Can't stage everything"

    /// What staging a conflicted path actually does — stated once, because the
    /// refusal above and the front ends' tooltips make the same claim and the
    /// tooltip is the one users read.
    ///
    /// `namingFiles` deduplicated the file list and left this duplicated, and it
    /// had already drifted: the tooltip said only "accepts whatever is in the
    /// worktree", which reads as "go find the markers" — and a modify/delete
    /// conflict (`UD`/`DU`/`DD`) has no markers anywhere. That is the shape
    /// `testStageAllRefusesAModifyDeleteConflictThatHasNoMarkers` exists for,
    /// and the quieter of the two failures: nothing looks wrong afterwards.
    static let conflictStagingConsequence =
        "accepts whatever is in the worktree — markers and all, or one side silently winning"

    /// Names up to `limit` paths and counts the rest — the "a.txt, b.txt and 2
    /// more" fragment that tells the user *which* files are in the way.
    ///
    /// Shared with the SwiftUI tooltip, which states the same rule about the
    /// same list — and on macOS is the copy the user actually reads, since the
    /// button is disabled while anything is unmerged and the refusal is a
    /// backstop for callers rather than a message anyone sees. Written twice,
    /// the two drift on the first edit to either, and the copy that drifts
    /// unnoticed is the one nobody is looking at.
    ///
    /// Internal, like `stageAllRefusalPrefix` and `conflictStagingConsequence`
    /// below. This was `public` on the reasoning that "a front end needs it" —
    /// true, but the front end that needs it is `UI/`, which is *excluded from*
    /// the SwiftPM library rather than a separate module, so it compiles into
    /// this one and sees internal fine. The GTK front end is genuinely separate
    /// and renders no Stage All tooltip; when it does, all three become public
    /// together rather than one of them guessing ahead.
    static func namingFiles(_ paths: [String], limit: Int = 3) -> String {
        // Clamped, because both failure modes below the floor are silent or
        // fatal rather than merely wrong. `limit: 0` names nothing and returns
        // " and 3 more" — a leading separator in a user-facing alert. A
        // negative limit is worse: `Collection.prefix(_:)` requires a
        // non-negative length, so it traps the process. A caller computing a
        // limit (`min(3, count)`) reaches both without meaning to.
        let limit = max(1, limit)
        let shown = paths.prefix(limit).joined(separator: ", ")
        guard paths.count > limit else { return shown }
        return shown + " and \(paths.count - limit) more"
    }

    /// True when `rev-parse --verify --quiet HEAD` succeeds — that is, HEAD
    /// resolves to a well-formed object *name*. It does not prove the object is
    /// in the database; the matrix in `isUnbornHEAD()` turns on exactly that
    /// distinction, so this doc used to contradict the analysis below it.
    private func hasHEAD() -> Bool {
        (try? runReadChecked(
            ["-C", worktree.path, "rev-parse", "--verify", "--quiet", "HEAD"], in: nil)) != nil
    }

    /// True when HEAD is **unborn**: a symbolic ref pointing at a branch that
    /// does not exist yet. That is the one state where `restore --staged` and
    /// `reset` have no baseline and dropping the index entry is the correct
    /// equivalent.
    ///
    /// Both callers *verify* with this after a failure rather than treating the
    /// failure as proof — which is a different thing from checking beforehand,
    /// and the difference matters: a pre-check is the check-then-act ordering
    /// `unstage` was restructured to avoid. Inferring is the dangerous version:
    /// a blanket `catch` around
    /// `restore --staged` accepts every other cause too — a locked index, a
    /// permissions problem, a path that moved underneath the click — and falls
    /// through to `rm --cached`, which succeeds. The user clicks Unstage, the
    /// operation reports success, the rows flip from Modified to Deleted, and
    /// the next commit removes the files.
    ///
    /// "HEAD does not resolve" is not enough on its own, which is why this is
    /// two commands rather than one: a corrupt `refs/heads/<branch>` fails
    /// `rev-parse --verify HEAD` exactly as an unborn HEAD does, so keying off
    /// that alone would send a *corrupt* repository down the index-surgery path
    /// — staging deletions of files that really exist. `symbolic-ref` separates
    /// them (verified against git 2.43): unborn exits 0 and prints the target,
    /// a corrupt target exits 128. A repository in that state therefore reaches
    /// `restore --staged` and fails loudly, which is what it should do.
    private func isUnbornHEAD() -> Bool {
        // `hasHEAD()` first, and it carries more weight than it looks. Raised in
        // review: a `refs/heads/<branch>` file holding a well-formed SHA whose
        // *object* is missing would be read as unborn and routed to
        // `rm --cached`. It is not — `rev-parse --verify` checks that the ref
        // resolves to a well-formed object name, not that the object exists, so
        // that state exits 0 and stops here. Measured across all four states on
        // git 2.43 (rev-parse / symbolic-ref exit codes):
        //
        //     healthy                     0 / 0    → not unborn
        //     garbage ref contents        1 / 128  → not unborn
        //     well-formed SHA, no object  0 / 0    → not unborn
        //     genuinely unborn            1 / 0    → unborn
        //
        // Only the last reaches the index surgery below, which is the contract.
        guard !hasHEAD() else { return false }
        return (try? runReadChecked(
            ["-C", worktree.path, "symbolic-ref", "--quiet", "HEAD"], in: nil)) != nil
    }

    /// Unstages `paths`, falling back to dropping the index entry only when
    /// there is genuinely no HEAD to restore against.
    ///
    /// **Restore first, ask afterwards.** The obvious shape — check
    /// `isUnbornHEAD()`, then branch — is a check-then-act across two
    /// processes, and the window has teeth: a commit landing in it (another
    /// terminal, an editor plugin, a hook) sends now-*tracked* files to
    /// `rm --cached`, which stages deletions. That is precisely the bug this
    /// function exists to prevent, arriving through the guard added to prevent
    /// it. Attempting the restore first closes *that* direction — if a commit
    /// lands before the restore, it simply succeeds and the `rm` branch is
    /// never reached.
    ///
    /// A window remains after the check — a commit landing between
    /// `isUnbornHEAD()` and the `rm`, or between `hasHEAD()` and `symbolic-ref`
    /// inside it — so the fallback **repairs** rather than assuming. See the
    /// `reset` following the `rm` below.
    ///
    /// An earlier version of this comment claimed no repair was possible and
    /// that only an index lock could close the window. That was wrong, and the
    /// error was picking the wrong command to test: `restore --staged` refuses a
    /// pathspec absent from the index, which is exactly what the `rm` leaves
    /// behind, but `reset` re-creates the entry from HEAD regardless.
    ///
    /// Safe because the failure is unambiguous rather than silent. Measured on
    /// git 2.43, `git restore --staged -- <path>` against an unborn HEAD exits
    /// 128 with `fatal: could not resolve HEAD` and leaves the index untouched
    /// — so it cannot quietly no-op its way past the branch that should have
    /// run. It also drops a subprocess from every unstage on a normal repo,
    /// where `isUnbornHEAD()` used to run `rev-parse` before each one.
    ///
    /// The fallback stays narrow on purpose: only a *positive* unborn-HEAD
    /// answer takes it. **Where HEAD resolves**, any other restore failure —
    /// most often a stale pathspec from a selection the index has moved on
    /// from — is rethrown. Swallowing those is the blanket `try?` this whole
    /// change removed, and a benign error the user can read beats a silent
    /// no-op on a button they pressed.
    ///
    /// On an unborn HEAD the asymmetry is deliberate and worth stating, since
    /// the sentence above does not cover it: every restore failure reaches the
    /// fallback there, and `--ignore-unmatch` makes a pathspec matching nothing
    /// exit 0. A repeat unstage on an unborn repo is therefore an idempotent
    /// no-op rather than an error.
    public func unstage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let literalSpecs = Self.literalPathspecs(paths)
        do {
            try runChecked(
                ["-C", worktree.path, "restore", "--staged", "--"] + literalSpecs, in: nil)
        } catch {
            guard isUnbornHEAD() else { throw error }
            // Unborn HEAD: nothing to restore against, so unstaging is exactly
            // dropping the index entry. `--cached` never touches worktree files.
            //
            // `-f` is not optional here, and `discard` below has always passed
            // it. `git rm --cached` refuses an entry whose content differs from
            // *both* HEAD and the worktree — and on an unborn HEAD git diffs
            // against the empty tree, so every staged entry differs from HEAD
            // and the check reduces to "refuse if the file was edited after
            // staging". Measured on git 2.43 in a fresh repo:
            //
            //     $ echo a > f; git add f; echo b >> f
            //     $ git rm --cached -r --ignore-unmatch -- f
            //     error: the following file has staged content different from
            //     both the file and the HEAD: f  (use -f to force removal)
            //
            // That is stage-a-file-and-keep-editing-it — the ordinary flow, in
            // the one repository state this branch exists for. `--ignore-unmatch`
            // does not bypass it; only `-f` does, and `-f` still touches nothing
            // outside the index.
            //
            // `--ignore-unmatch` stays for a different case: a pathspec matching
            // nothing succeeds quietly here where the restore above would have
            // thrown. Leniency costs a silent no-op; strictness up there
            // prevents a staged deletion.
            try runChecked(
                ["-C", worktree.path, "rm", "--cached", "-f", "-r", "--ignore-unmatch", "--"]
                    + literalSpecs,
                in: nil)
            // Repairs the window this ordering narrows but cannot close. If a
            // first commit landed between `isUnbornHEAD()` and the `rm`, those
            // paths are now tracked and the `rm` just staged their deletion —
            // the exact damage this function exists to prevent.
            //
            // `reset`, not `restore --staged`, and that is the whole reason this
            // repair works where the earlier one didn't: `restore --staged`
            // refuses a pathspec absent from the index, which is precisely the
            // state the `rm` leaves. `reset` re-creates the entry from HEAD
            // regardless — measured, git 2.43:
            //
            //     git rm --cached -f f.txt   →  "D  f.txt" staged deletion
            //     git reset -q HEAD -- f.txt →  exit 0, entry back, status clean
            //
            // Skipped entirely in the ordinary unborn case, where `hasHEAD()`
            // is false and there was never anything to repair.
            if hasHEAD() {
                try runChecked(
                    ["-C", worktree.path, "reset", "-q", "HEAD", "--"] + literalSpecs,
                    in: nil)
            }
        }
    }

    /// Reverts tracked paths to their HEAD state — both the index and the
    /// worktree. Untracked paths must be handled by the caller (they need a file
    /// move to the Trash, not a git command).
    ///
    /// A plain `git checkout -- <path>` only restores the worktree from the
    /// index, so for a file whose changes are *staged* it silently discards
    /// nothing. Instead: unstage first (`reset`), then restore the worktree
    /// for the paths that are still tracked afterwards. A staged *new* file
    /// has no HEAD state to restore; it ends up untracked with its content
    /// kept, rather than being destroyed.
    ///
    /// On an unborn HEAD there is nothing to restore against at all, so
    /// discarding just unstages (the files stay on disk as untracked).
    public func discard(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        // Git pathspecs glob by default: a file literally named "a*.txt" would
        // make these commands also match unrelated tracked files (abc.txt…).
        // Force literal matching everywhere a real path is passed.
        let literalSpecs = Self.literalPathspecs(paths)
        // Reset first, ask afterwards — the same ordering `unstage` uses, and
        // for the same reason. Guarding on `isUnbornHEAD()` *before* the
        // mutation is a check-then-act across two processes: a first commit
        // landing in the window sends now-tracked files to `rm --cached -f`,
        // staging their deletion. That is the bug this whole change exists to
        // prevent, and leaving it on the sibling path while fixing `unstage`
        // was fixing half of a symmetric pair.
        //
        // Safe because the reset either works or fails loudly. On git 2.43
        // `reset -q HEAD -- <path>` *succeeds* on an unborn HEAD (measured:
        // exit 0, index emptied), falling back to the empty tree — so on
        // current git the fallback below is unreachable and the ordering costs
        // nothing. It stays for older git, where the reset fails and the
        // unborn answer is what justifies index surgery.
        do {
            try runChecked(
                ["-C", worktree.path, "reset", "-q", "HEAD", "--"] + literalSpecs, in: nil)
        } catch {
            // Only a *positive* unborn answer takes the fallback; a corrupt
            // HEAD rethrows. `-f` makes that distinction load-bearing rather
            // than merely correct — a bare `rev-parse --verify --quiet HEAD`
            // probe fails for a corrupt HEAD exactly as it does for an unborn
            // one, and a corrupt repository reaching `rm --cached -f` would
            // have its matched paths silently staged-deleted. `isUnbornHEAD()`
            // is two commands for precisely this reason, and the corrupt-ref
            // integration test pins that it separates them.
            guard isUnbornHEAD() else { throw error }
            // Unborn HEAD: there is nothing to restore against, so discarding
            // can only unstage. `--cached` never touches worktree files; `-f`
            // bypasses the check that refuses staged-new files edited after
            // staging. Nothing is tracked, so there is no checkout step to run.
            try runChecked(
                ["-C", worktree.path, "rm", "--cached", "-r", "-f", "--ignore-unmatch", "--"]
                    + literalSpecs,
                in: nil)
            // The same repair as `unstage`, for the same window — narrower here,
            // since on git 2.43 the reset above succeeds on an unborn HEAD and
            // this branch is unreachable. It matters on older git, where the
            // reset fails and the race is live.
            if hasHEAD() {
                try runChecked(
                    ["-C", worktree.path, "reset", "-q", "HEAD", "--"] + literalSpecs,
                    in: nil)
                // Still returns, and now for a different reason than the line
                // above gives. Once the repair has run the paths *are* tracked,
                // so "nothing is tracked" no longer explains the skip — but the
                // checkout below would restore the worktree from a commit that
                // landed mid-operation and that the user never saw, discarding
                // edits made since. Leaving the index correct and the worktree
                // untouched is the safer half to deliver.
                return
            }
            return
        }
        let tracked = try runReadChecked(
            ["-C", worktree.path, "ls-files", "-z", "--"] + literalSpecs,
            in: nil).stdout
        let stillTracked = tracked.components(separatedBy: "\0").filter { !$0.isEmpty }
        if !stillTracked.isEmpty {
            try runChecked(
                ["-C", worktree.path, "checkout", "--"]
                    + Self.literalPathspecs(stillTracked),
                in: nil)
        }
    }

    public func commit(message: String, amend: Bool = false) throws {
        var args = ["-C", worktree.path, "commit", "-F", "-"]
        if amend { args.append("--amend") }
        try runChecked(args, in: nil, stdin: message)
    }

    // MARK: - Network

    public func fetch() throws {
        try runChecked(
            ["-C", worktree.path, "fetch", "--all", "--prune"], in: nil)
    }

    public func pull(rebase: Bool) throws {
        var args = ["-C", worktree.path, "pull"]
        args.append(rebase ? "--rebase" : "--no-rebase")
        try runChecked(args, in: nil)
    }

    /// Pushes exactly one branch to exactly one remote.
    ///
    /// The refspec is never left implicit. A bare `git push` delegates the
    /// choice of what to send to `push.default`, `remote.pushDefault` and
    /// `branch.<name>.pushRemote`: under `push.default = matching` (git's
    /// default before 2.0, and still present in plenty of inherited configs) it
    /// pushes *every* branch that exists on both sides, so a single force push
    /// rewrites branches the user never selected; under `current` it pushes to a
    /// same-named branch that need not be the configured upstream the app's
    /// ahead/behind counters are measured against; under `nothing` it fails
    /// outright. Naming the refspec makes all three irrelevant.
    ///
    /// Both sides are fully qualified so that a branch sharing its short name
    /// with a tag cannot be selected instead, and so a name beginning with `-`
    /// can never land in option position.
    ///
    /// `forceWithLease` rewrites the remote branch to the local history, but —
    /// unlike a bare --force — refuses when the remote moved past what this
    /// repo last fetched, so a teammate's unpulled commits can't be clobbered
    /// silently. With an explicit refspec the lease applies to that one ref.
    public func push(remote: String, localBranch: String, remoteBranch: String,
                     setUpstream: Bool, forceWithLease: Bool = false) throws {
        // The boundary `pushArguments`' comment names, which until now did not
        // exist: it said user-typed input should be validated here because this
        // API throws, while the only check was a `precondition` one level down
        // that traps in release builds too. A future branch-name field would
        // have shipped a crash on empty input, and the comment inviting the
        // reliance was the thing that made that likely.
        // Trimmed first: whitespace is how a user-typed field actually produces
        // "empty" (a stray paste, a trailing newline), and `isEmpty` alone lets
        // " " through to git as an operand, which fails with a refspec error
        // rather than the clear one this guard exists to give. Safe to trim
        // rather than reject, because neither a refname nor a remote name may
        // carry leading or trailing whitespace — no legitimate name changes.
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let localBranch = localBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteBranch = remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, !localBranch.isEmpty, !remoteBranch.isEmpty else {
            throw GitError(
                message: "Can't push: the remote and branch names must not be empty.",
                exitCode: -1)
        }
        try push(Self.pushArguments(
            remote: remote, localBranch: localBranch, remoteBranch: remoteBranch,
            setUpstream: setUpstream, forceWithLease: forceWithLease))
    }

    /// Runs a command built by `pushArguments`/`forcePushArguments`, so a caller
    /// that has already resolved the exact command (the force-push confirmation
    /// shows it to the user first) runs that command rather than rebuilding it.
    public func push(_ command: PushCommand) throws {
        try runChecked(["-C", worktree.path] + command.arguments, in: nil)
    }

    /// A push argv that came from `pushArguments`/`forcePushArguments`.
    ///
    /// The point is the `fileprivate` initializer: there is no way to build one
    /// from raw `[String]`, so no caller can add `--force` or drop the refspec
    /// on the way to `push(_:)`. An `assert` was the first attempt and does not
    /// hold — it compiles out of release builds, which are the ones users run,
    /// and inspecting `arguments.first` would have let `["push", "--force", …]`
    /// straight through anyway. The type makes the contract structural.
    public struct PushCommand: Equatable {
        public let arguments: [String]

        /// Whether this command carries `--force-if-includes`, i.e. whether it
        /// refuses remote work that *was fetched into this repository but never
        /// integrated* into the local branch.
        ///
        /// That is the flag's incremental guarantee, and naming it precisely
        /// matters because the dialog's wording comes from here. Remote work
        /// that was never fetched is already refused by `--force-with-lease`
        /// alone — the remote tip differs from the stale remote-tracking ref, so
        /// the lease fails. What the lease cannot catch is the case this app
        /// creates for itself: auto-fetch updates the tracking ref behind the
        /// user, the lease then matches, and only `--force-if-includes` still
        /// objects that the fetched tip is not reachable from what is being
        /// pushed. An earlier version of this doc said "commits the local branch
        /// never had", which describes the lease's job, not this one.
        ///
        /// Lives here, beside the builder that appends the flag, because the
        /// confirmation dialog picks its wording from it. A literal
        /// `contains("--force-if-includes")` at the view would be a second
        /// spelling of the emitter's decision, and the one that produces the
        /// user-facing safety claim.
        public var refusesUnintegratedRemoteWork: Bool {
            arguments.contains("--force-if-includes")
        }
        fileprivate init(_ arguments: [String]) { self.arguments = arguments }
    }

    /// The argv `push` runs, without the repo-scoping `-C` pair. Pure, so the
    /// confirmation dialog can show the user the exact command rather than a
    /// description of it — and so the command shown and the command run cannot
    /// drift apart.
    /// `forceIfIncludes` defaults to the probed capability, and exists as a
    /// parameter so the tests can pin *both* flag shapes on any host. Deriving
    /// the expectation from `supportsForceIfIncludes` — the same property the
    /// builder reads — made those tests tautological: a gate that regressed to
    /// `<= (2, 30)` would have flipped the argv and the assertion together, and
    /// the suite would have stayed green on every machine while the protection
    /// that decides whether a teammate's commits survive was silently off.
    public static func pushArguments(remote: String, localBranch: String, remoteBranch: String,
                                     setUpstream: Bool,
                                     forceWithLease: Bool = false,
                                     forceIfIncludes: Bool = supportsForceIfIncludes) -> PushCommand {
        // Trimmed here as well as in the throwing `push`, because the
        // confirmation dialog reaches git through this builder and `push(_:)`,
        // never through that guard — so validation placed only there would sit
        // on the path typed input is *least* likely to take. The `precondition`
        // below then sees the normalised values.
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let localBranch = localBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteBranch = remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["push"]
        if forceWithLease {
            args.append("--force-with-lease")
            // `--force-with-lease` alone compares against the remote-tracking
            // ref, which this app updates behind the user's back: auto-fetch
            // (`AppState.autoFetchIfDue`) runs on a timer when enabled. So a
            // teammate's commit can arrive in `refs/remotes/origin/main`
            // *between* the confirmation opening and the user pressing the
            // button, the lease then matches, and the push destroys work the
            // user was never shown.
            //
            // Reproduced against git 2.43: rewrite locally, fetch, then
            // `push --force-with-lease` → "forced update", teammate's commit
            // gone. Adding `--force-if-includes` → rejected, commit survives.
            // It requires the fetched tip to be reachable from what is being
            // pushed, which is precisely "you actually integrated what you
            // fetched".
            //
            // Gated because it needs git 2.30+; without the gate an older git
            // fails every force push with "unknown option".
            if forceIfIncludes { args.append("--force-if-includes") }
        }
        if setUpstream { args.append("-u") }
        // `--` ends option parsing. Qualifying the refspec covers the branch
        // names, but the remote is its own operand — and a remote really can be
        // called `-f`: `git remote add -- -f <url>` is accepted, and without the
        // separator `git push … -f refs/…` would parse it as --force.
        args.append("--")
        args.append(remote)
        // git reads an empty source side as a *delete*: `refs/heads/:refs/heads/x`
        // is `git push origin :x`. `PushCommand` exists so no caller can build a
        // destructive command on the way to `push(_:)`, and a zero-length branch
        // name is the one shape that smuggles the worst one through the type.
        //
        // `remote` is checked too, for symmetry rather than for danger: an empty
        // remote makes git fail loudly ("does not appear to be a git
        // repository") rather than do something unintended, but leaving it out
        // invited the question of why only the branches, with no answer here.
        //
        // A `precondition` rather than a thrown error because every value on
        // this path comes from parsed git output, so an empty one is a bug in
        // this app and not a state a user can reach or a message a UI could
        // usefully show. If a future caller ever feeds this user-typed text,
        // the validation belongs at *that* boundary — `push(remote:…)` already
        // throws — and this stays the net underneath it.
        precondition(!remote.isEmpty && !localBranch.isEmpty && !remoteBranch.isEmpty,
                     "an empty remote or branch name cannot build a valid push refspec")
        args.append("refs/heads/\(localBranch):refs/heads/\(remoteBranch)")
        return PushCommand(args)
    }

    /// The argv a force push runs. One definition so the confirmation dialog and
    /// the command it describes share their *flags* too, not just the refspec.
    ///
    /// That paid off immediately: `--force-if-includes` was added to
    /// `pushArguments` after this comment was written, and the dialog picked it
    /// up with no change here — which is exactly the drift this shape prevents.
    public static func forcePushArguments(
        remote: String, localBranch: String, remoteBranch: String,
        forceIfIncludes: Bool = supportsForceIfIncludes
    ) -> PushCommand {
        pushArguments(remote: remote, localBranch: localBranch,
                      remoteBranch: remoteBranch, setUpstream: false,
                      forceWithLease: true, forceIfIncludes: forceIfIncludes)
    }

    // MARK: - Branches

    public func createBranch(_ name: String, at startPoint: String? = nil, checkout: Bool) throws {
        // Same option-injection guard as createTag: a leading-dash name must
        // never reach git in option position.
        guard !name.hasPrefix("-") else {
            throw GitError(message: "Branch names must not start with “-”.", exitCode: -1)
        }
        var args = ["-C", worktree.path]
        args.append(checkout ? "checkout" : "branch")
        if checkout { args.append("-b") }
        args.append(name)
        if let startPoint { args.append(startPoint) }
        try runChecked(args, in: nil)
    }

    public func checkout(branch: String) throws {
        try runChecked(["-C", worktree.path, "checkout", branch], in: nil)
    }

    /// Checks out a remote branch as a new local tracking branch.
    public func checkoutTracking(remoteBranch: String, localName: String) throws {
        try runChecked(
            ["-C", worktree.path, "checkout", "-b", localName, "--track", remoteBranch],
            in: nil)
    }

    public func deleteBranch(_ name: String, force: Bool) throws {
        try runChecked(
            ["-C", worktree.path, "branch", force ? "-D" : "-d", name], in: nil)
    }

    /// Deletes a branch on its remote (`push <remote> --delete <branch>`).
    /// `remoteBranch` is the for-each-ref short name "<remote>/<branch>".
    public func deleteRemoteBranch(_ remoteBranch: String) throws {
        // Remote names may themselves contain "/" ("up/stream" — git allows
        // it), so split by longest-prefix match against the configured
        // remotes, never by first slash: splitting "up/stream/feature" at the
        // first slash would push the deletion of "stream/feature" to the
        // remote "up" — the wrong server, and the wrong branch if it has one
        // by that name.
        let remoteNames = try remotes().map(\.name)
        guard let remote = remoteNames
            .filter({ remoteBranch.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count }) else {
            throw GitError(message: "No configured remote matches \(remoteBranch)", exitCode: -1)
        }
        let branch = String(remoteBranch.dropFirst(remote.count + 1))
        guard !branch.isEmpty else {
            throw GitError(message: "Not a remote branch: \(remoteBranch)", exitCode: -1)
        }
        // "origin/HEAD" is the remote's default-branch symref: deleting it
        // asks the remote to delete its default branch. (branches() filters
        // the symref from the UI already; guard here regardless.)
        guard branch != "HEAD" else {
            throw GitError(message: "Can't delete the remote's HEAD — it points at the remote's default branch.", exitCode: -1)
        }
        // The parts come from for-each-ref output, never free-typed — but a
        // leading dash would still land in option position, so guard anyway.
        guard !remote.hasPrefix("-"), !branch.hasPrefix("-") else {
            throw GitError(message: "Refusing to delete a ref starting with “-”.", exitCode: -1)
        }
        // Fully qualified: a tag sharing the branch's name would otherwise
        // fail the deletion with "dst refspec matches more than one".
        try runChecked(
            ["-C", worktree.path, "push", remote, "--delete", "refs/heads/\(branch)"],
            in: nil)
    }

    public func renameBranch(old: String, new: String) throws {
        try runChecked(["-C", worktree.path, "branch", "-m", old, new], in: nil)
    }

    // MARK: - Tags

    /// Creates a tag pointing at `hash`. With a non-empty message the tag is
    /// annotated (`-a -m`), otherwise lightweight. `git tag` validates the
    /// refname itself, so invalid names surface as git errors.
    public func createTag(name: String, message: String?, at hash: String) throws {
        // A name in option position could be parsed as a git flag (`-f` would
        // force-move an existing tag) — reject it before git ever sees it.
        guard !name.hasPrefix("-") else {
            throw GitError(message: "Tag names must not start with “-”.", exitCode: -1)
        }
        var args = ["-C", worktree.path, "tag"]
        if let message, !message.isEmpty {
            args.append(contentsOf: ["-a", "-m", message])
        }
        args.append(contentsOf: [name, hash])
        try runChecked(args, in: nil)
    }

    // MARK: - Merging

    /// Merge modifiers: `squash` stages the branch's combined changes without
    /// creating a commit (the user then commits via the commit box — message,
    /// hooks and all); `noFastForward` records a merge commit even when a
    /// fast-forward would do. Mutually exclusive in git; callers pass at most
    /// one. `--no-edit` only applies to the non-squash path (squash never
    /// commits, so there is no message to edit).
    public func merge(_ branch: String, squash: Bool = false, noFastForward: Bool = false) throws {
        var args = ["-C", worktree.path, "merge"]
        if squash {
            args.append("--squash")
        } else {
            args.append("--no-edit")
            if noFastForward { args.append("--no-ff") }
        }
        args.append(branch)
        try runChecked(args, in: nil)
    }

    public func mergeAbort() throws {
        try runChecked(["-C", worktree.path, "merge", "--abort"], in: nil)
    }

    /// Commits an in-progress merge after conflicts were resolved (staged).
    public func mergeContinue() throws {
        try runChecked(["-C", worktree.path, "commit", "--no-edit"], in: nil)
    }

    public func mergeHead() throws -> String? {
        let result = try runRead(
            ["-C", worktree.path, "rev-parse", "--verify", "-q", "MERGE_HEAD"], in: nil)
        guard result.exitCode == 0 else { return nil }
        let hash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// First line of MERGE_MSG — "Merge branch 'feature'" — for the banner label.
    public func mergeMessageLabel() -> String? {
        guard let result = try? runRead(
            ["-C", worktree.path, "rev-parse", "--verify", "-q", "MERGE_HEAD"], in: nil),
            result.exitCode == 0 else { return nil }
        guard let gitDir = gitDir() else { return nil }
        let messageURL = gitDir.appendingPathComponent("MERGE_MSG")
        guard let text = try? String(contentsOf: messageURL, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func conflictedPaths() throws -> [String] {
        let result = try runReadChecked(
            ["-C", worktree.path, "diff", "--name-only", "--diff-filter=U", "-z"], in: nil)
        return result.stdout.components(separatedBy: "\0").filter { !$0.isEmpty }
    }

    /// Hands one conflicted file to an external merge tool (`git mergetool`).
    /// Blocks until the tool exits. Afterwards the caller refreshes: if the tool
    /// (or git's "was the merge successful?" prompt, which gets a headless EOF
    /// because `GitShell.run` gives every child `/dev/null` on stdin) didn't
    /// stage the file, the UI still offers “Mark Resolved”.
    ///
    /// **`--no-prompt` is load-bearing.** With `mergetool.prompt` on, git's
    /// "Hit return to start merge resolution tool" reads the `/dev/null` stdin
    /// every child now gets, hits EOF, and skips the file without launching
    /// anything — invisibly, since the prompt goes to the captured stdout pipe.
    /// Unset behaves as false because this call always passes `--tool=`, so the
    /// flag protects users who set the option themselves. If the tool returns
    /// the file unresolved, mergetool exits 1 and `runChecked` throws; before
    /// the `/dev/null` change that same case blocked forever on the launching
    /// terminal's tty. (Measured matrix at the invocation below.)
    public func runMergeTool(_ tool: String, path: String) throws {
        // git-mergetool is a shell script. Even after its initial git command
        // selects a literal path, it expands the returned filename with an
        // unquoted `set -- $files`; `*`, `?`, and `[` can therefore open and
        // stage lookalike conflicts. Run that script with shell globbing off,
        // and force literal semantics for every nested git command it launches.
        let literalEnvironment = [
            "GIT_LITERAL_PATHSPECS": "1",
            "SHELLOPTS": "noglob",
        ]
        // SHELLOPTS is Bash's, and only Bash reads it at startup. macOS /bin/sh
        // is Bash, so the mitigation holds there; on most Linux distributions
        // /bin/sh is dash, which ignores it entirely. Rather than let the tool
        // quietly resolve every conflicted lookalike, refuse the one case that
        // is unsafe — the user still has Ours, Theirs and Mark Resolved, all of
        // which pass literal pathspecs straight to git.
        if path.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }),
           Self.shellGlobsDespiteNoglob {
            throw GitError(
                message: """
                    Can't open a merge tool for “\(path)”: this system's /bin/sh \
                    expands that name as a wildcard, and git mergetool would \
                    resolve every conflicted file matching it. Resolve this one \
                    with Ours, Theirs, or Mark Resolved instead.
                    """,
                exitCode: -1)
        }
        // Measured against git 2.43, fake tool, stdin from /dev/null:
        //
        //     mergetool.prompt=true,  no flag      → tool NEVER launched
        //     mergetool.prompt=true,  --no-prompt  → tool launched
        //     mergetool.prompt unset, no flag      → tool launched
        //
        // Kept next to the flag it justifies, so re-verifying means re-running
        // the command on this line rather than trusting a doc block.
        try runChecked(
            ["-C", worktree.path,
             "-c", "mergetool.keepBackup=false",   // don't litter .orig files
             "mergetool", "--no-prompt", "--tool=\(tool)", "--", path],
            in: nil, environmentOverrides: literalEnvironment)
    }

    /// Whether `/bin/sh` still expands globs with `SHELLOPTS=noglob` set —
    /// i.e. whether `runMergeTool`'s protection against git-mergetool's
    /// unquoted `set -- $files` actually works here.
    ///
    /// Probed rather than assumed per platform: what matters is which shell is
    /// installed as `/bin/sh`, not which OS is running. The probe asks the real
    /// shell to expand `?` in a directory holding exactly one file — with
    /// globbing off it stays `?`, with globbing on it becomes the filename.
    static let shellGlobsDespiteNoglob: Bool = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughGlobProbe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("a"))
        } catch {
            return true   // Can't prove it's safe, so assume it isn't.
        }
        guard let result = try? ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "set -- ?; printf %s \"$1\""],
            environmentOverrides: ["SHELLOPTS": "noglob"],
            workingDirectory: directory)
        else { return true }
        return result.standardOutput != "?"
    }()

    /// Marks a conflicted path resolved (for when the user fixed it by hand or in
    /// a tool that didn't stage it).
    public func markResolved(path: String) throws {
        if try fileHasConflictMarkers(path) {
            throw GitError(
                message: "\(path) still contains conflict markers. Remove them before marking the file resolved.",
                exitCode: -1)
        }
        try runChecked(
            ["-C", worktree.path, "add", "--", Self.literalPathspec(path)], in: nil)
    }

    /// True when the file still contains git conflict markers (`<<<<<<<`,
    /// `=======`, `>>>>>>>` at line start). Used after an external merge tool
    /// exits: opendiff-style tools can't be trusted to stage the file or answer
    /// git's "was it resolved?" prompt (which hits a headless EOF), so GitEnough
    /// verifies the file itself. Throws when the file can't be inspected so a
    /// read/permission failure can never be mistaken for a resolved conflict.
    public func fileHasConflictMarkers(_ path: String, chunkSize: Int = 64 * 1024) throws -> Bool {
        let url = worktree.appendingPathComponent(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let opening = Array("<<<<<<<".utf8)
        let closing = Array(">>>>>>>".utf8)
        var prefix: [UInt8] = []
        prefix.reserveCapacity(opening.count)
        var atLineStart = true

        while let data = try handle.read(upToCount: max(1, chunkSize)), !data.isEmpty {
            for byte in data {
                if byte == 0x0A { // newline
                    atLineStart = true
                    prefix.removeAll(keepingCapacity: true)
                } else if atLineStart {
                    prefix.append(byte)
                    if prefix.count == opening.count {
                        // A bare "=======" is also a legitimate Markdown
                        // Setext underline, so only angle-bracket sides count.
                        if prefix == opening || prefix == closing { return true }
                        atLineStart = false
                    }
                }
            }
        }
        return false
    }

    /// Resolves a conflicted path by checking out one side and staging it.
    public func resolveConflict(path: String, ours: Bool) throws {
        let literalSpec = Self.literalPathspec(path)
        try runChecked(
            ["-C", worktree.path, "checkout", ours ? "--ours" : "--theirs", "--",
             literalSpec],
            in: nil)
        try runChecked(["-C", worktree.path, "add", "--", literalSpec], in: nil)
    }

    // MARK: - Sequencer state (merge / rebase / cherry-pick / revert)

    /// Which sequencer operation is currently in progress, if any.
    ///
    /// Rebase is detected via the `rebase-merge`/`rebase-apply` state directories and
    /// checked FIRST: during a conflicted rebase git writes MERGE_MSG (and other
    /// sequencer files) but *not* MERGE_HEAD, so merge-only detection misses it —
    /// exactly the gap that used to make conflicted rebases invisible in the UI.
    public func inProgressOperation() -> InProgressOperation? {
        guard let gitDir = gitDir() else { return nil }
        let fileManager = FileManager.default
        func stateExists(_ relative: String) -> Bool {
            fileManager.fileExists(atPath: gitDir.appendingPathComponent(relative).path)
        }
        // Same detection git's own shell prompt uses: rebase-merge is always a
        // rebase; rebase-apply is also created by `git am`, whose `applying`
        // marker file distinguishes it.
        if stateExists("rebase-merge") { return .rebase }
        if stateExists("rebase-apply"), !stateExists("rebase-apply/applying") { return .rebase }
        if stateExists("CHERRY_PICK_HEAD") { return .cherryPick }
        if stateExists("REVERT_HEAD") { return .revert }
        let mergeHead = (try? mergeHead()) ?? nil
        return mergeHead != nil ? .merge : nil
    }

    /// A human label for the operation banner: MERGE_MSG's first line for merges,
    /// "Rebasing <branch>" for rebases, a plain phrase otherwise.
    public func operationLabel(for operation: InProgressOperation) -> String? {
        switch operation {
        case .merge:
            return mergeMessageLabel()
        case .rebase:
            guard let gitDir = gitDir() else { return nil }
            // head-name holds the full ref of the branch being rebased.
            for relative in ["rebase-merge/head-name", "rebase-apply/head-name"] {
                let url = gitDir.appendingPathComponent(relative)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let ref = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if ref.hasPrefix("refs/heads/") {
                    return "Rebasing \(String(ref.dropFirst("refs/heads/".count)))"
                }
                // A detached-HEAD rebase writes the literal "detached" here;
                // the generic "Rebase in progress" beats "Rebasing detached".
                if ref != "detached", !ref.isEmpty { return "Rebasing \(ref)" }
            }
            return nil
        case .cherryPick:
            return "Cherry-pick in progress"
        case .revert:
            return "Revert in progress"
        }
    }

    /// Continues an in-progress rebase. Safe headless: GIT_EDITOR=true (set by
    /// GitShell) makes `--continue` accept git's prepared commit message instead
    /// of blocking on an editor.
    public func rebaseContinue() throws {
        try runChecked(["-C", worktree.path, "rebase", "--continue"], in: nil)
    }

    public func rebaseAbort() throws {
        try runChecked(["-C", worktree.path, "rebase", "--abort"], in: nil)
    }

    public func cherryPickContinue() throws {
        try runChecked(["-C", worktree.path, "cherry-pick", "--continue"], in: nil)
    }

    public func cherryPickAbort() throws {
        try runChecked(["-C", worktree.path, "cherry-pick", "--abort"], in: nil)
    }

    public func revertContinue() throws {
        try runChecked(["-C", worktree.path, "revert", "--continue"], in: nil)
    }

    public func revertAbort() throws {
        try runChecked(["-C", worktree.path, "revert", "--abort"], in: nil)
    }

    // MARK: - Stash

    public func stashList() throws -> [StashEntry] {
        let f = GitParsers.fieldSep
        let result = try runReadChecked(
            ["-C", worktree.path, "stash", "list", "--format=%gd\(f)%gs"], in: nil)
        return GitParsers.parseStash(result.stdout)
    }

    public func stashPush(message: String?, includeUntracked: Bool) throws {
        var args = ["-C", worktree.path, "stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if let message, !message.isEmpty {
            args.append(contentsOf: ["-m", message])
        }
        try runChecked(args, in: nil)
    }

    public func stashApply(index: Int, pop: Bool) throws {
        try runChecked(
            ["-C", worktree.path, "stash", pop ? "pop" : "apply", "stash@{\(index)}"],
            in: nil)
    }

    public func stashDrop(index: Int) throws {
        try runChecked(
            ["-C", worktree.path, "stash", "drop", "stash@{\(index)}"], in: nil)
    }

    // MARK: - Commit-targeted actions

    /// Cherry-picks one commit. For a merge commit git refuses to guess which
    /// parent's changes to replay — pass `mainline` (1-based parent index;
    /// 1 = first parent, the branch merged *into*) to pick its diff.
    public func cherryPick(_ hash: String, mainline: Int? = nil) throws {
        var args = ["-C", worktree.path, "cherry-pick"]
        if let mainline {
            precondition(mainline >= 1, "mainline is a 1-based parent index")
            args.append(contentsOf: ["-m", String(mainline)])
        }
        args.append(hash)
        try runChecked(args, in: nil)
    }

    public enum ResetMode: String {
        case soft = "--soft"
        case mixed = "--mixed"
        case hard = "--hard"
    }

    public func reset(to hash: String, mode: ResetMode) throws {
        try runChecked(["-C", worktree.path, "reset", mode.rawValue, hash], in: nil)
    }

    /// Reverts one commit. Same `mainline` contract as `cherryPick` — a merge
    /// commit needs the parent to revert against (1 = first parent).
    public func revert(_ hash: String, mainline: Int? = nil) throws {
        var args = ["-C", worktree.path, "revert", "--no-edit"]
        if let mainline {
            precondition(mainline >= 1, "mainline is a 1-based parent index")
            args.append(contentsOf: ["-m", String(mainline)])
        }
        args.append(hash)
        try runChecked(args, in: nil)
    }

    // MARK: - Clone

    /// Clones `url` into `destination`. Progress goes to stderr (which we surface).
    public static func clone(_ url: String, into destination: URL) throws {
        try GitShell.shared.runChecked(["clone", "--", url, destination.path], in: nil)
    }
}
