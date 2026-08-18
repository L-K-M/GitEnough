import Foundation

/// Typed git operations for one repository. Every method is synchronous (see
/// GitShell) — `RepoViewModel` calls them from its serial background queue.
///
/// All repo-scoped commands run as `git -C <worktree> <cmd>` with arguments passed
/// as an array (never through a shell), so paths with spaces or shell metacharacters
/// are safe. `--` separates pathspecs from revisions everywhere a path is involved.
final class GitClient {

    let shell: GitShell
    let worktree: URL

    /// When set, every git invocation this client makes is recorded (begin,
    /// finish, exit code, stderr tail) so the UI can show what is running right
    /// now and what ran before. Owned by the repo's view model; nil in tests
    /// and one-off clients means no recording. Assign exactly once, before
    /// the first command runs — reads happen on background queues without
    /// locking.
    var activityLog: GitActivityLog?

    init(worktree: URL, shell: GitShell = .shared) {
        self.worktree = worktree
        self.shell = shell
    }

    // MARK: - Logging wrappers

    /// Every call below goes through these two wrappers instead of touching
    /// `shell` directly, so the activity log always reflects reality — when a
    /// pre-commit hook hangs, the log shows `commit -F -` running for minutes.
    @discardableResult
    private func run(_ args: [String], in directory: URL?) throws -> GitResult {
        guard let log = activityLog else { return try shell.run(args, in: directory) }
        let id = log.begin(command: GitActivityLog.displayCommand(for: args))
        do {
            let result = try shell.run(args, in: directory)
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
                            stdin: String? = nil) throws -> GitResult {
        guard let log = activityLog else {
            return try shell.runChecked(args, in: directory, stdin: stdin)
        }
        let id = log.begin(command: GitActivityLog.displayCommand(for: args))
        do {
            let result = try shell.runChecked(args, in: directory, stdin: stdin)
            log.finish(id, exitCode: result.exitCode, stderr: result.stderr)
            return result
        } catch {
            let gitError = error as? GitError
            log.finish(id, exitCode: gitError?.exitCode,
                       stderr: gitError?.message ?? error.localizedDescription)
            throw error
        }
    }

    // MARK: - Discovery / validation

    /// True when `directory` is inside a git worktree.
    static func isRepository(at directory: URL) -> Bool {
        guard let result = try? GitShell.shared.run(
            ["rev-parse", "--is-inside-work-tree"], in: directory) else { return false }
        return result.exitCode == 0
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The canonical top-level path of the worktree containing `directory`
    /// (so adding `repo/Documentation/` registers the repo root).
    static func topLevel(of directory: URL) -> URL? {
        guard let result = try? GitShell.shared.run(
            ["rev-parse", "--show-toplevel"], in: directory),
            result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The `.git` directory (a file for linked worktrees — resolved by git).
    func gitDir() -> URL? {
        guard let result = try? run(
            ["-C", worktree.path, "rev-parse", "--absolute-git-dir"], in: nil),
            result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func version() -> String? {
        guard let result = try? GitShell.shared.run(["--version"], in: nil),
              result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Status / branches / remotes

    func status() throws -> RepoStatus {
        // --no-optional-locks: read-only queries must not take the index lock or
        // refresh stat info, so polling can never fight a concurrent `git commit`.
        let result = try runChecked(
            ["-C", worktree.path, "--no-optional-locks",
             "status", "--porcelain=v2", "--branch", "--untracked-files=normal"],
            in: nil)
        return GitParsers.parseStatus(result.stdout)
    }

    func branches() throws -> [Branch] {
        let f = GitParsers.fieldSep
        let format = "%(refname)\(f)%(refname:short)\(f)%(upstream:short)\(f)%(upstream:track)\(f)%(HEAD)"
        let result = try runChecked(
            ["-C", worktree.path, "for-each-ref",
             "--format=\(format)", "refs/heads", "refs/remotes"],
            in: nil)
        return GitParsers.parseBranches(result.stdout)
    }

    func remotes() throws -> [Remote] {
        let result = try runChecked(["-C", worktree.path, "remote", "-v"], in: nil)
        return GitParsers.parseRemotes(result.stdout)
    }

    /// The remote's default branch (its HEAD): `refs/remotes/origin/HEAD` →
    /// "main". The symref is established by clone and maintained by recent
    /// fetches; nil when git hasn't set it yet — callers then fall back to
    /// "main"/"master" guessing. Used as the base branch of a new pull request.
    func remoteDefaultBranch(remote: String) -> String? {
        guard let result = try? run(
            ["-C", worktree.path, "--no-optional-locks",
             "symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"], in: nil),
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
    static let hiddenRefs = ["refs/stash", "refs/original/*", "refs/bisect/*",
                             "refs/prefetch/*", "refs/notes/*", "refs/replace/*",
                             "refs/rewritten/*"]

    /// Newest-first, topologically ordered commits across all refs — the input to
    /// the graph layout. `skip`/`limit` drive the "Load more" pagination.
    func log(limit: Int, skip: Int = 0) throws -> [Commit] {
        let f = GitParsers.fieldSep
        let r = GitParsers.recordSep
        let format = "%H\(f)%P\(f)%an\(f)%ae\(f)%aI\(f)%D\(f)%s\(r)"
        // --exclude filters the ref set of the *next* --all, so it must precede
        // it. --decorate-refs-exclude is position-independent; grouped for clarity.
        var args = ["-C", worktree.path, "log"]
        args += Self.hiddenRefs.map { "--exclude=\($0)" }
        args += ["--all"]
        args += Self.hiddenRefs.map { "--decorate-refs-exclude=\($0)" }
        args += ["--topo-order", "--date-order",
                 "--pretty=tformat:\(format)",
                 "--max-count=\(limit)"]
        if skip > 0 { args.append("--skip=\(skip)") }
        let result = try runChecked(args, in: nil)
        return GitParsers.parseLog(result.stdout)
    }

    /// Full header + changed-file list for the detail pane.
    func commitDetail(_ hash: String) throws -> CommitDetail? {
        let f = GitParsers.fieldSep
        let r = GitParsers.recordSep
        let format = "%H\(f)%an\(f)%ae\(f)%aI\(f)%P\(f)%s\(f)%b\(r)"
        // -m --first-parent: for merges, show the diff against the first parent.
        let result = try runChecked(
            ["-C", worktree.path, "show", "-m", "--first-parent",
             "--format=\(format)", "--name-status", "--no-color", hash],
            in: nil)
        return GitParsers.parseCommitDetail(result.stdout)
    }

    // MARK: - Diffs

    /// Unified diff for one worktree/index path.
    func diff(path: String, staged: Bool) throws -> String {
        var args = ["-C", worktree.path, "diff", "--no-color", "--no-ext-diff"]
        if staged { args.append("--staged") }
        args.append(contentsOf: ["--", path])
        return try runChecked(args, in: nil).stdout
    }

    /// Untracked files have no index entry; diff them against /dev/null.
    func diffForUntracked(path: String) throws -> String {
        let result = try run(
            ["-C", worktree.path, "diff", "--no-color", "--no-index",
             "--", "/dev/null", path],
            in: nil)
        // --no-index exits 1 when files differ (i.e. always, here); 0/1 are both OK.
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw GitError(message: result.stderr, exitCode: result.exitCode)
        }
        return result.stdout
    }

    /// Patch of one file within a commit (for the detail pane).
    func commitFileDiff(hash: String, path: String) throws -> String {
        try runChecked(
            ["-C", worktree.path, "show", "-m", "--first-parent",
             "--format=", "--no-color", hash, "--", path],
            in: nil).stdout
    }

    /// Full staged patch — the input for LLM commit-message generation.
    func stagedDiff() throws -> String {
        try runChecked(
            ["-C", worktree.path, "diff", "--staged", "--no-color"], in: nil).stdout
    }

    /// `--stat` summary of the staged changes (always sent to the model in full).
    func stagedDiffStat() throws -> String {
        try runChecked(
            ["-C", worktree.path, "diff", "--staged", "--stat", "--no-color"], in: nil).stdout
    }

    // MARK: - Staging

    func stage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runChecked(["-C", worktree.path, "add", "--"] + paths, in: nil)
    }

    func stageAll() throws {
        try runChecked(["-C", worktree.path, "add", "-A"], in: nil)
    }

    func unstage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        do {
            try runChecked(["-C", worktree.path, "restore", "--staged", "--"] + paths, in: nil)
        } catch {
            // On an unborn HEAD (no commits yet) `restore --staged` has nothing to
            // resolve HEAD against; `rm --cached` is the equivalent there.
            try runChecked(["-C", worktree.path, "rm", "--cached", "-r", "--ignore-unmatch", "--"] + paths, in: nil)
        }
    }

    /// Reverts worktree changes for tracked paths. Untracked paths must be handled
    /// by the caller (they need a file move to the Trash, not a git command).
    func discard(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runChecked(["-C", worktree.path, "checkout", "--"] + paths, in: nil)
    }

    func commit(message: String, amend: Bool = false) throws {
        var args = ["-C", worktree.path, "commit", "-F", "-"]
        if amend { args.append("--amend") }
        try runChecked(args, in: nil, stdin: message)
    }

    // MARK: - Network

    func fetch() throws {
        try runChecked(
            ["-C", worktree.path, "fetch", "--all", "--prune", "--tags"], in: nil)
    }

    func pull(rebase: Bool) throws {
        var args = ["-C", worktree.path, "pull", "--tags"]
        args.append(rebase ? "--rebase" : "--no-rebase")
        try runChecked(args, in: nil)
    }

    func push(setUpstream: Bool, remote: String = "origin") throws {
        var args = ["-C", worktree.path, "push"]
        if setUpstream {
            args.append(contentsOf: ["-u", remote, "HEAD"])
        }
        try runChecked(args, in: nil)
    }

    // MARK: - Branches

    func createBranch(_ name: String, at startPoint: String? = nil, checkout: Bool) throws {
        var args = ["-C", worktree.path]
        args.append(checkout ? "checkout" : "branch")
        if checkout { args.append("-b") }
        args.append(name)
        if let startPoint { args.append(startPoint) }
        try runChecked(args, in: nil)
    }

    func checkout(branch: String) throws {
        try runChecked(["-C", worktree.path, "checkout", branch], in: nil)
    }

    /// Checks out a remote branch as a new local tracking branch.
    func checkoutTracking(remoteBranch: String, localName: String) throws {
        try runChecked(
            ["-C", worktree.path, "checkout", "-b", localName, "--track", remoteBranch],
            in: nil)
    }

    func deleteBranch(_ name: String, force: Bool) throws {
        try runChecked(
            ["-C", worktree.path, "branch", force ? "-D" : "-d", name], in: nil)
    }

    func renameBranch(old: String, new: String) throws {
        try runChecked(["-C", worktree.path, "branch", "-m", old, new], in: nil)
    }

    // MARK: - Merging

    func merge(_ branch: String) throws {
        try runChecked(["-C", worktree.path, "merge", "--no-edit", branch], in: nil)
    }

    func mergeAbort() throws {
        try runChecked(["-C", worktree.path, "merge", "--abort"], in: nil)
    }

    /// Commits an in-progress merge after conflicts were resolved (staged).
    func mergeContinue() throws {
        try runChecked(["-C", worktree.path, "commit", "--no-edit"], in: nil)
    }

    func mergeHead() throws -> String? {
        let result = try run(
            ["-C", worktree.path, "rev-parse", "--verify", "-q", "MERGE_HEAD"], in: nil)
        guard result.exitCode == 0 else { return nil }
        let hash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// First line of MERGE_MSG — "Merge branch 'feature'" — for the banner label.
    func mergeMessageLabel() -> String? {
        guard let result = try? run(
            ["-C", worktree.path, "rev-parse", "--verify", "-q", "MERGE_HEAD"], in: nil),
            result.exitCode == 0 else { return nil }
        guard let gitDir = gitDir() else { return nil }
        let messageURL = gitDir.appendingPathComponent("MERGE_MSG")
        guard let text = try? String(contentsOf: messageURL, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func conflictedPaths() throws -> [String] {
        let result = try runChecked(
            ["-C", worktree.path, "diff", "--name-only", "--diff-filter=U", "-z"], in: nil)
        return result.stdout.components(separatedBy: "\0").filter { !$0.isEmpty }
    }

    /// Hands one conflicted file to an external merge tool (`git mergetool`).
    /// Blocks until the tool exits. Afterwards the caller refreshes: if the tool
    /// (or git's "was the merge successful?" prompt, which gets a headless EOF)
    /// didn't stage the file, the UI still offers “Mark Resolved”.
    func runMergeTool(_ tool: String, path: String) throws {
        try runChecked(
            ["-C", worktree.path,
             "-c", "mergetool.keepBackup=false",   // don't litter .orig files
             "mergetool", "--no-prompt", "--tool=\(tool)", "--", path],
            in: nil)
    }

    /// Marks a conflicted path resolved (for when the user fixed it by hand or in
    /// a tool that didn't stage it).
    func markResolved(path: String) throws {
        try runChecked(["-C", worktree.path, "add", "--", path], in: nil)
    }

    /// True when the file still contains git conflict markers (`<<<<<<<`,
    /// `=======`, `>>>>>>>` at line start). Used after an external merge tool
    /// exits: opendiff-style tools can't be trusted to stage the file or answer
    /// git's "was it resolved?" prompt (which hits a headless EOF), so GitEnough
    /// verifies the file itself.
    func fileHasConflictMarkers(_ path: String) -> Bool {
        let url = worktree.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Only the angle-bracket markers: a bare "=======" line is also a
            // legitimate Setext heading underline, which would false-positive.
            if line.hasPrefix("<<<<<<<") || line.hasPrefix(">>>>>>>") {
                return true
            }
        }
        return false
    }

    /// Resolves a conflicted path by checking out one side and staging it.
    func resolveConflict(path: String, ours: Bool) throws {
        try runChecked(
            ["-C", worktree.path, "checkout", ours ? "--ours" : "--theirs", "--", path],
            in: nil)
        try runChecked(["-C", worktree.path, "add", "--", path], in: nil)
    }

    // MARK: - Stash

    func stashList() throws -> [StashEntry] {
        let f = GitParsers.fieldSep
        let result = try runChecked(
            ["-C", worktree.path, "stash", "list", "--format=%gd\(f)%gs"], in: nil)
        return GitParsers.parseStash(result.stdout)
    }

    func stashPush(message: String?, includeUntracked: Bool) throws {
        var args = ["-C", worktree.path, "stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if let message, !message.isEmpty {
            args.append(contentsOf: ["-m", message])
        }
        try runChecked(args, in: nil)
    }

    func stashApply(index: Int, pop: Bool) throws {
        try runChecked(
            ["-C", worktree.path, "stash", pop ? "pop" : "apply", "stash@{\(index)}"],
            in: nil)
    }

    func stashDrop(index: Int) throws {
        try runChecked(
            ["-C", worktree.path, "stash", "drop", "stash@{\(index)}"], in: nil)
    }

    // MARK: - Commit-targeted actions

    func cherryPick(_ hash: String) throws {
        try runChecked(["-C", worktree.path, "cherry-pick", hash], in: nil)
    }

    enum ResetMode: String {
        case soft = "--soft"
        case mixed = "--mixed"
        case hard = "--hard"
    }

    func reset(to hash: String, mode: ResetMode) throws {
        try runChecked(["-C", worktree.path, "reset", mode.rawValue, hash], in: nil)
    }

    func revert(_ hash: String) throws {
        try runChecked(["-C", worktree.path, "revert", "--no-edit", hash], in: nil)
    }

    // MARK: - Clone

    /// Clones `url` into `destination`. Progress goes to stderr (which we surface).
    static func clone(_ url: String, into destination: URL) throws {
        try GitShell.shared.runChecked(["clone", "--", url, destination.path], in: nil)
    }
}
