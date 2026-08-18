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

    private let queueKey = DispatchSpecificKey<UInt8>()

    static let historyPageSize = 300

    // MARK: - Published state

    @Published private(set) var status: RepoStatus = .empty
    @Published private(set) var branches: [Branch] = []
    @Published private(set) var remotes: [Remote] = []
    @Published private(set) var commits: [Commit] = []
    @Published private(set) var layout: GraphLayout = .empty
    @Published private(set) var stash: [StashEntry] = []
    @Published private(set) var mergeState = MergeState(isMerging: false, mergingRef: nil,
                                                        conflictedFiles: [])
    @Published private(set) var canLoadMoreHistory = false

    @Published private(set) var isBusy = false
    @Published private(set) var activity: String?
    @Published var errorMessage: String?

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

    init(repo: Repository, historyLimit: Int = RepoViewModel.historyPageSize) {
        self.repo = repo
        self.client = GitClient(worktree: repo.url)
        self.queue = DispatchQueue(label: "gitenough.repo.\(repo.name)", qos: .userInitiated)
        self.historyLimit = historyLimit
        self.queue.setSpecific(key: queueKey, value: 1)
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
        let mergeHead = (try? client.mergeHead()) ?? nil
        let mergeState = MergeState(
            isMerging: mergeHead != nil,
            mergingRef: mergeHead != nil ? client.mergeMessageLabel() : nil,
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

    /// Push -u origin HEAD for a branch with no upstream yet.
    func publishBranch() { perform("Publishing branch…") { try $0.push(setUpstream: true) } }

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

    func mergeAbort() { perform("Aborting merge…") { try $0.mergeAbort() } }

    func mergeContinue() { perform("Committing merge…") { try $0.mergeContinue() } }

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
        perform("Staging…", includeHistory: false) { try $0.stage(paths: changes.map(\.path)) }
    }

    func stageAll() {
        perform("Staging all…", includeHistory: false) { try $0.stageAll() }
    }

    func unstage(_ changes: [FileChange]) {
        perform("Unstaging…", includeHistory: false) { try $0.unstage(paths: changes.map(\.path)) }
    }

    /// Tracked paths are restored via git; untracked paths are moved to the Trash
    /// (recoverable, unlike a hard delete).
    func discard(_ changes: [FileChange]) {
        perform("Discarding changes…", includeHistory: false) { client in
            let tracked = changes.filter { !$0.isUntracked }.map(\.path)
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
