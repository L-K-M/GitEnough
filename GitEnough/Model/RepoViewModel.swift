import AppKit
import Foundation

/// All state and operations for one open repository.
///
/// Every git command runs on a single serial background queue (`queue`), so ops
/// can never interleave and fight over the index lock. Mutating operations follow
/// one pattern (`perform`): run the command, take a fresh snapshot of status /
/// branches / history on the same queue, then apply everything to the @Published
/// properties in one hop to the main thread.
final class RepoViewModel: ObservableObject, Identifiable {

    let repo: Repository
    var id: String { repo.id }

    let client: GitClient
    let queue: DispatchQueue
    private var watcher: RepoWatcher?
    private var historyLimit: Int

    /// Called on the main thread after each applied snapshot, so the sidebar
    /// summary (branch, dirty dot, ahead/behind) tracks repo operations live
    /// instead of only updating on app activation. Set by AppState.
    var onStatusChange: ((RepoSummary) -> Void)?

    private let queueKey = DispatchSpecificKey<UInt8>()

    static let historyPageSize = 300

    // MARK: - Published state

    @Published private(set) var status: RepoStatus = .empty
    @Published private(set) var branches: [Branch] = []
    @Published private(set) var remotes: [Remote] = []
    @Published private(set) var commits: [Commit] = []
    @Published private(set) var layout: GraphLayout = .empty
    @Published private(set) var stash: [StashEntry] = []
    @Published private(set) var mergeState = MergeState(operation: nil, operationLabel: nil,
                                                        conflictedFiles: [])
    @Published private(set) var canLoadMoreHistory = false

    @Published private(set) var isBusy = false
    @Published private(set) var activity: String?
    @Published var errorMessage: String?

    /// Rolling log of the git commands this repo has run (newest last). Powers
    /// the status-bar "what is it doing" readout and the activity popover.
    let activityLog = GitActivityLog()
    @Published private(set) var activityEntries: [GitActivityLog.Entry] = []

    /// The git commands running right now — usually zero or one (the queue is
    /// serial), but a merge tool runs off-queue and can overlap with repo ops.
    var runningActivityEntries: [GitActivityLog.Entry] {
        activityEntries.filter { $0.isRunning }
    }

    /// Non-blocking indicator while an external merge tool is open. Unlike
    /// `isBusy` this never occupies the serial repo queue: the tool can stay open
    /// as long as the user needs, and Ours/Theirs/Mark Resolved keep working.
    @Published private(set) var mergeToolActivity: String?

    /// Commit detail pane.
    @Published private(set) var selectedCommitDetail: CommitDetail?
    @Published private(set) var selectedCommitFileDiff: String = ""

    /// Changes pane: the diff of the currently selected worktree file.
    @Published private(set) var selectedFileDiff: String = ""
    @Published private(set) var isLoadingDiff = false

    /// Commit box.
    @Published var draftCommitMessage: String = ""
    @Published var amendLastCommit = false
    @Published private(set) var isGeneratingMessage = false
    @Published var messageGenerationError: String?

    /// True when amending would rewrite a commit the upstream already has
    /// (upstream set, nothing ahead → HEAD is reachable from upstream) —
    /// i.e. when the UI should warn and confirm before committing.
    var amendWouldRewritePushedCommit: Bool {
        amendLastCommit && status.upstream != nil && status.ahead == 0
    }

    init(repo: Repository, historyLimit: Int = RepoViewModel.historyPageSize) {
        self.repo = repo
        self.client = GitClient(worktree: repo.url)
        self.queue = DispatchQueue(label: "gitenough.repo.\(repo.name)", qos: .userInitiated)
        self.historyLimit = historyLimit
        self.queue.setSpecific(key: queueKey, value: 1)
        client.activityLog = activityLog
        activityLog.onChange = { [weak self] entries in
            DispatchQueue.main.async { self?.activityEntries = entries }
        }
    }

    deinit {
        watcher = nil // cancels the timer
    }

    // MARK: - Lifecycle

    /// Starts watching the repo and performs the initial load. Idempotent.
    func start() {
        guard watcher == nil else { return }
        refresh(includeHistory: true)
        queue.async { [weak self] in
            guard let self, let gitDir = self.client.gitDir() else { return }
            DispatchQueue.main.async {
                self.watcher = RepoWatcher(gitDir: gitDir, worktree: self.repo.url,
                                           queue: self.queue) { [weak self] in
                    self?.collectAndApply(includeHistory: true)
                }
            }
        }
    }

    // MARK: - Snapshot loading

    private struct Snapshot {
        let status: RepoStatus
        let branches: [Branch]
        let remotes: [Remote]
        let stash: [StashEntry]
        let mergeState: MergeState
        let commits: [Commit]?
        let layout: GraphLayout?
        let canLoadMore: Bool
    }

    /// Must be called on `queue`.
    private func collectSnapshot(includeHistory: Bool) -> Snapshot {
        let status = (try? client.status()) ?? .empty
        let branches = (try? client.branches()) ?? []
        let remotes = (try? client.remotes()) ?? []
        let stash = (try? client.stashList()) ?? []
        let operation = client.inProgressOperation()
        var operationLabel: String?
        if let operation { operationLabel = client.operationLabel(for: operation) }
        let mergeState = MergeState(
            operation: operation,
            operationLabel: operationLabel,
            conflictedFiles: (try? client.conflictedPaths()) ?? []
        )
        var commits: [Commit]?
        var layout: GraphLayout?
        var canLoadMore = canLoadMoreHistory
        if includeHistory {
            // Load one extra commit to know whether "Load more" should be offered.
            let loaded = (try? client.log(limit: historyLimit + 1)) ?? []
            canLoadMore = loaded.count > historyLimit
            let trimmed = Array(loaded.prefix(historyLimit))
            commits = trimmed
            layout = GraphLayout.layout(commits: trimmed)
        }
        return Snapshot(status: status, branches: branches, remotes: remotes, stash: stash,
                        mergeState: mergeState, commits: commits, layout: layout,
                        canLoadMore: canLoadMore)
    }

    /// Must be called on the main thread.
    private func apply(_ snapshot: Snapshot) {
        status = snapshot.status
        branches = snapshot.branches
        remotes = snapshot.remotes
        stash = snapshot.stash
        mergeState = snapshot.mergeState
        canLoadMoreHistory = snapshot.canLoadMore
        if let commits = snapshot.commits { self.commits = commits }
        if let layout = snapshot.layout { self.layout = layout }
        onStatusChange?(RepoSummary(status: snapshot.status))
    }

    /// Runs a snapshot load on the queue and applies it on main.
    private func collectAndApply(includeHistory: Bool) {
        // Already on the queue when invoked from the watcher; hop if needed.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            let snapshot = collectSnapshot(includeHistory: includeHistory)
            DispatchQueue.main.async { self.apply(snapshot) }
        } else {
            queue.async {
                let snapshot = self.collectSnapshot(includeHistory: includeHistory)
                DispatchQueue.main.async { self.apply(snapshot) }
            }
        }
    }

    /// Manual / external-trigger refresh (⌘R, window activation, watcher).
    func refresh(includeHistory: Bool = true) {
        collectAndApply(includeHistory: includeHistory)
    }

    func loadMoreHistory() {
        historyLimit += Self.historyPageSize
        collectAndApply(includeHistory: true)
    }

    // MARK: - Mutating operations

    /// Runs `work` on the serial queue, then refreshes and applies a snapshot.
    /// `onSuccess` runs on main only when `work` didn't throw (used e.g. to clear
    /// the commit box only after a successful commit).
    private func perform(_ activity: String,
                         includeHistory: Bool = true,
                         onSuccess: (() -> Void)? = nil,
                         _ work: @escaping (GitClient) throws -> Void) {
        isBusy = true
        self.activity = activity
        errorMessage = nil
        queue.async {
            var caught: Error?
            do {
                try work(self.client)
            } catch {
                caught = error
            }
            let snapshot = self.collectSnapshot(includeHistory: includeHistory)
            DispatchQueue.main.async {
                self.apply(snapshot)
                self.isBusy = false
                self.activity = nil
                if let caught {
                    self.errorMessage = caught.localizedDescription
                } else {
                    onSuccess?()
                }
            }
        }
    }

    // MARK: Network

    func fetch() { perform("Fetching…") { try $0.fetch() } }

    func pull(rebase: Bool) {
        perform(rebase ? "Pulling (rebase)…" : "Pulling…") { try $0.pull(rebase: rebase) }
    }

    func push() { perform("Pushing…") { try $0.push(setUpstream: false) } }

    /// The remote a branch without an upstream should be published to — "origin"
    /// when it exists (it's the natural target even alongside other remotes),
    /// otherwise the first configured remote.
    var publishRemoteName: String {
        remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name ?? "origin"
    }

    /// Push -u <publishRemoteName> HEAD for a branch with no upstream yet — which
    /// is not necessarily a remote named "origin". Guarded: with no remotes at
    /// all there is nothing to publish to (the Publish button hides, but no call
    /// path should be able to push to a fabricated "origin").
    func publishBranch() {
        guard !remotes.isEmpty else { return }
        let remote = publishRemoteName
        perform("Publishing branch…") { try $0.push(setUpstream: true, remote: remote) }
    }

    // MARK: Pull request

    /// True while the forge is being asked whether the current branch has an
    /// open pull request (drives the toolbar button's busy state).
    @Published private(set) var isResolvingPullRequest = false

    /// Opens the current branch's pull request on the forge website (GitHub,
    /// GitLab, Forgejo/Gitea): the PR itself when one is open for the branch,
    /// else the forge's "create a pull request" page. The lookup is an
    /// unauthenticated best-effort API call; when it can't tell — private repo,
    /// offline, unknown forge — the create page is opened, which shows an
    /// "already has a pull request" banner once the browser is signed in.
    func openPullRequest() {
        guard !isResolvingPullRequest else { return }
        if status.isUnborn {
            errorMessage = "Can't open a pull request: this repository has no commits yet."
            return
        }
        guard let branch = status.head else {
            errorMessage = "Can't open a pull request: HEAD is detached — check out a branch first."
            return
        }
        guard let remote = preferredRemote() else {
            errorMessage = "Can't open a pull request: the repository has no remotes."
            return
        }
        // A branch that isn't on the remote yet has no PR to find and no
        // compare to run — the forge would only show a dead "nothing to
        // compare" page. No upstream tracking and no matching remote branch
        // is a reliable "never pushed" signal; the Publish button is nearby.
        if status.upstream == nil,
           !branches.contains(where: { $0.isRemote && $0.name == "\(remote.name)/\(branch)" }) {
            errorMessage = "“\(branch)” isn't on \(remote.name) yet — publish the branch first, then open its pull request."
            return
        }
        guard let forge = ForgeRepo.parse(remoteURL: remote.url) else {
            errorMessage = "The remote “\(remote.name)” (\(remote.url)) doesn't point at a forge website, so there is no pull-request page to open."
            return
        }
        isResolvingPullRequest = true
        errorMessage = nil
        // The remote's default branch (the PR base) comes from git, so it goes
        // through the serial queue like every other git read; the network
        // lookup runs off it — only URLSession, no process to block on.
        let fallbackBase = branches.contains { $0.isRemote && $0.name == "\(remote.name)/master" }
            ? "master" : "main"
        queue.async { [weak self] in
            let base = self?.client.remoteDefaultBranch(remote: remote.name) ?? fallbackBase
            Task { [weak self] in
                let pullRequest = await PullRequestFinder.shared
                    .findOpenPullRequest(for: forge, headBranch: branch)
                let url = pullRequest?.url ?? forge.newPullRequestURL(base: base, head: branch)
                await MainActor.run { [weak self] in
                    self?.isResolvingPullRequest = false
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// The remote a pull request would live on: the branch's upstream remote
    /// when one is configured, else "origin", else the first configured remote.
    private func preferredRemote() -> Remote? {
        if let upstream = status.upstream,
           let remoteName = upstream.split(separator: "/").first.map(String.init),
           let remote = remotes.first(where: { $0.name == remoteName }) {
            return remote
        }
        return remotes.first { $0.name == "origin" } ?? remotes.first
    }

    // MARK: Branches

    func checkout(branch: Branch) {
        if branch.isRemote {
            guard let local = branch.localNameForRemote else { return }
            perform("Checking out \(local)…") { try $0.checkoutTracking(remoteBranch: branch.name, localName: local) }
        } else {
            guard !branch.isHead else { return }
            perform("Checking out \(branch.name)…") { try $0.checkout(branch: branch.name) }
        }
    }

    func createBranch(named name: String, at startPoint: String? = nil, checkout: Bool) {
        perform("Creating branch \(name)…") { try $0.createBranch(name, at: startPoint, checkout: checkout) }
    }

    func deleteBranch(_ branch: Branch, force: Bool) {
        perform("Deleting \(branch.name)…") { try $0.deleteBranch(branch.name, force: force) }
    }

    func merge(branch: Branch) {
        perform("Merging \(branch.name)…") { try $0.merge(branch.name) }
    }

    func renameBranch(_ branch: Branch, to newName: String) {
        perform("Renaming branch…") { try $0.renameBranch(old: branch.name, new: newName) }
    }

    // MARK: Merge / conflicts

    /// Continues whichever sequencer operation is in progress (merge commit,
    /// rebase, cherry-pick, or revert) — the banner's primary action.
    func continueOperation() {
        switch mergeState.operation {
        case nil:
            break
        case .merge:
            perform("Committing merge…") { try $0.mergeContinue() }
        case .rebase:
            perform("Continuing rebase…") { try $0.rebaseContinue() }
        case .cherryPick:
            perform("Continuing cherry-pick…") { try $0.cherryPickContinue() }
        case .revert:
            perform("Continuing revert…") { try $0.revertContinue() }
        }
    }

    /// Aborts whichever sequencer operation is in progress.
    func abortOperation() {
        switch mergeState.operation {
        case nil:
            break
        case .merge:
            perform("Aborting merge…") { try $0.mergeAbort() }
        case .rebase:
            perform("Aborting rebase…") { try $0.rebaseAbort() }
        case .cherryPick:
            perform("Aborting cherry-pick…") { try $0.cherryPickAbort() }
        case .revert:
            perform("Aborting revert…") { try $0.revertAbort() }
        }
    }

    /// Opens the external merge tool for one conflicted file. The tool process
    /// (e.g. FileMerge via opendiff) can stay open for minutes, so it must NOT
    /// run on the serial repo queue — a blocking call there would jam every
    /// subsequent repo operation behind it (which is exactly what used to make
    /// Ours/Theirs/Mark Resolved look dead and the spinner spin forever).
    ///
    /// When the tool exits we verify the file ourselves (its exit code / git's
    /// "was it resolved?" prompt are unreliable headless): no conflict markers
    /// left → stage it; markers left → tell the user.
    func openMergeTool(_ tool: MergeTool, path: String) {
        guard mergeToolActivity == nil else {
            errorMessage = "A merge tool is already open — close it before opening another."
            return
        }
        mergeToolActivity = "Waiting for \(tool.name)…"
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var caught: Error?
            do {
                try self.client.runMergeTool(tool.gitName, path: path)
            } catch {
                caught = error
            }
            // Verifying and staging go through the serial repo queue like every
            // other mutating operation — concurrent `git add`s could otherwise
            // fight over the index lock.
            self.queue.async {
                var autoResolved = false
                if caught == nil {
                    do {
                        if !self.client.fileHasConflictMarkers(path) {
                            try self.client.markResolved(path: path)
                            autoResolved = true
                        }
                    } catch {
                        caught = error
                    }
                }
                let snapshot = self.collectSnapshot(includeHistory: false)
                DispatchQueue.main.async {
                    self.apply(snapshot)
                    self.mergeToolActivity = nil
                    if let caught {
                        self.errorMessage = caught.localizedDescription
                    } else if !autoResolved,
                              self.mergeState.conflictedFiles.contains(path) {
                        self.errorMessage = "\(tool.name) closed but \(path) still contains conflict markers — resolve them and choose “Mark Resolved”."
                    }
                }
            }
        }
    }

    func resolveConflict(path: String, ours: Bool) {
        perform("Resolving conflict…", includeHistory: false) {
            try $0.resolveConflict(path: path, ours: ours)
        }
    }

    /// `git add` a conflicted path the user resolved by hand or in a tool that
    /// didn't stage it.
    func markResolved(path: String) {
        perform("Marking resolved…", includeHistory: false) {
            try $0.markResolved(path: path)
        }
    }

    // MARK: Staging / commit

    func stage(_ changes: [FileChange]) {
        perform("Staging…", includeHistory: false) {
            try $0.stage(paths: changes.flatMap(\.affectedPaths))
        }
    }

    func stageAll() {
        perform("Staging all…", includeHistory: false) { try $0.stageAll() }
    }

    func unstage(_ changes: [FileChange]) {
        perform("Unstaging…", includeHistory: false) {
            try $0.unstage(paths: changes.flatMap(\.affectedPaths))
        }
    }

    /// Adds an untracked file's path to the repo's root `.gitignore` (creating
    /// the file if needed). A plain file append, not a git command — the
    /// post-op snapshot picks up the change and the row disappears.
    func ignore(_ change: FileChange) {
        // gitignore doesn't affect tracked files — ignoring one would be a
        // silent no-op, so refuse it here like the UI does.
        guard change.isUntracked else { return }
        perform("Updating .gitignore…", includeHistory: false) { client in
            // A broader existing pattern (*.log, build/) already covers it.
            guard !client.isIgnored(path: change.path) else { return }
            let url = client.worktree.appendingPathComponent(".gitignore")
            // Only a genuinely missing file maps to empty: a *read* failure
            // (e.g. non-UTF-8 bytes) must throw rather than let the write
            // below clobber the existing file with a single line.
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            let existing = fileExists
                ? try String(contentsOf: url, encoding: .utf8)
                : ""
            let updated = GitIgnore.appending(change.path, to: existing)
            guard updated != existing else { return }
            if fileExists {
                // Append through the existing file (following symlinks, and
                // preserving permissions/ownership) rather than replacing it
                // atomically. `appending` only ever appends, so the new bytes
                // are exactly the difference.
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(updated.dropFirst(existing.count).utf8))
                try handle.close()
            } else {
                try updated.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Tracked paths are restored via git; untracked paths are moved to the Trash
    /// (recoverable, unlike a hard delete).
    func discard(_ changes: [FileChange]) {
        perform("Discarding changes…", includeHistory: false) { client in
            let tracked = changes.filter { !$0.isUntracked }.flatMap(\.affectedPaths)
            if !tracked.isEmpty { try client.discard(paths: tracked) }
            for change in changes where change.isUntracked {
                let url = self.repo.url.appendingPathComponent(change.path)
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    func commit() {
        let message = draftCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let amend = amendLastCommit
        // Only clear the box on success — a rejected hook must not eat the message.
        perform("Committing…", onSuccess: {
            self.draftCommitMessage = ""
            self.amendLastCommit = false
        }) { try $0.commit(message: message, amend: amend) }
    }

    // MARK: Stash

    func stashPush(message: String?, includeUntracked: Bool) {
        perform("Stashing…") { try $0.stashPush(message: message, includeUntracked: includeUntracked) }
    }

    func stashApply(_ entry: StashEntry, pop: Bool) {
        perform(pop ? "Popping stash…" : "Applying stash…") { try $0.stashApply(index: entry.index, pop: pop) }
    }

    func stashDrop(_ entry: StashEntry) {
        perform("Dropping stash…") { try $0.stashDrop(index: entry.index) }
    }

    // MARK: Commit-targeted

    func createBranchAtCommit(named name: String, hash: String) {
        perform("Creating branch…") { try $0.createBranch(name, at: hash, checkout: false) }
    }

    func createTag(named name: String, message: String?, at hash: String) {
        perform("Creating tag…") { try $0.createTag(name: name, message: message, at: hash) }
    }

    func checkoutCommit(_ hash: String) {
        perform("Checking out commit…") { try $0.checkout(branch: hash) }
    }

    func cherryPick(_ hash: String) {
        perform("Cherry-picking…") { try $0.cherryPick(hash) }
    }

    func revert(_ hash: String) {
        perform("Reverting…") { try $0.revert(hash) }
    }

    func reset(to hash: String, mode: GitClient.ResetMode) {
        perform("Resetting…") { try $0.reset(to: hash, mode: mode) }
    }

    // MARK: - Selections / detail loading

    func selectCommit(_ hash: String?) {
        guard let hash else {
            selectedCommitDetail = nil
            selectedCommitFileDiff = ""
            return
        }
        queue.async {
            let detail = try? self.client.commitDetail(hash)
            DispatchQueue.main.async {
                self.selectedCommitDetail = detail
                self.selectedCommitFileDiff = ""
            }
        }
    }

    func selectCommitFile(hash: String, path: String?) {
        guard let path else {
            selectedCommitFileDiff = ""
            return
        }
        queue.async {
            let diff = (try? self.client.commitFileDiff(hash: hash, path: path)) ?? ""
            DispatchQueue.main.async { self.selectedCommitFileDiff = diff }
        }
    }

    /// Loads the worktree/index diff for the file selected in the Changes pane.
    func selectFile(_ change: FileChange?, staged: Bool) {
        guard let change else {
            selectedFileDiff = ""
            return
        }
        isLoadingDiff = true
        queue.async {
            let diff: String
            if change.isUntracked {
                diff = (try? self.client.diffForUntracked(path: change.path)) ?? ""
            } else {
                diff = (try? self.client.diff(path: change.path, staged: staged)) ?? ""
            }
            DispatchQueue.main.async {
                self.selectedFileDiff = diff
                self.isLoadingDiff = false
            }
        }
    }

    // MARK: - Smart commit message

    func generateCommitMessage() {
        guard !isGeneratingMessage else { return }
        isGeneratingMessage = true
        messageGenerationError = nil
        let branch = status.head
        queue.async {
            let stat = (try? self.client.stagedDiffStat()) ?? ""
            let diff = (try? self.client.stagedDiff()) ?? ""
            let generator = CommitMessageGenerator(configuration: LLMConfiguration.load())
            Task {
                do {
                    let message = try await generator.generateCommitMessage(
                        diffStat: stat, diff: diff, branch: branch)
                    await MainActor.run {
                        self.draftCommitMessage = message
                        self.isGeneratingMessage = false
                    }
                } catch {
                    await MainActor.run {
                        self.messageGenerationError = error.localizedDescription
                        self.isGeneratingMessage = false
                    }
                }
            }
        }
    }
}
