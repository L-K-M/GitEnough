import Foundation

/// The detail pane's tabs. In AppState (not the view) so menu commands with
/// keyboard shortcuts can switch tabs too.
enum DetailTab: String, CaseIterable, Identifiable {
    case history = "History"
    case changes = "Changes"
    case branches = "Branches"

    var id: String { rawValue }
}

/// Top-level app state: repository list (via `store`), the current selection, and
/// the cache of per-repo view models (one per repo, created lazily, kept alive so
/// switching repos doesn't lose scroll position or reload history).
final class AppState: ObservableObject {

    private static let selectedRepositoryKey = "selectedRepository"

    let store = RepoStore()

    @Published var selectedRepoPath: String? {
        didSet { Self.persistSelection(selectedRepoPath) }
    }
    @Published var selectedTab: DetailTab = .history

    /// Add-repository sheet state and its validation error.
    @Published var showingAddRepository = false
    @Published var addRepositoryError: String?

    /// Why a dropped folder couldn't be added. Unlike the Add sheet, a drop has
    /// no inline error surface, so ContentView shows this as an alert.
    @Published var dropAddError: String?

    /// New-branch sheet (triggered from the Repository menu, shown by the detail pane).
    @Published var showingNewBranch = false

    /// Path of the most recently added repository. Purely a UI cue: the sidebar
    /// scrolls to reveal it — in a long manually-sorted list a new bottom/top
    /// row can otherwise land out of view and read as "didn't appear".
    @Published var lastAddedRepoPath: String?

    private var viewModels: [String: RepoViewModel] = [:]

    /// App-wide persistent git command history ("shell history" window).
    /// Every repo view model's activity log forwards events here.
    let activityStore = GitActivityStore()

    /// UserDefaults key for the watch folder (Settings → General → Repository
    /// discovery). Shared with SettingsView's @AppStorage.
    static let discoveryFolderKey = "discoveryFolder"

    /// UserDefaults key for the auto-fetch interval in minutes (0 = never).
    /// Shared with SettingsView's @AppStorage.
    static let autoFetchMinutesKey = "autoFetchMinutes"

    private var discoveryTimer: Timer?
    /// repo path → last auto-fetch, so switching repos doesn't make a
    /// never-fetched repo wait out an interval it earned elsewhere.
    private var lastAutoFetchByRepo: [String: Date] = [:]

    /// The view model for the currently selected repository, if any.
    var activeViewModel: RepoViewModel? {
        guard let repo = selectedRepository else { return nil }
        return viewModel(for: repo)
    }

    init() {
        let savedPath = UserDefaults.standard.string(forKey: Self.selectedRepositoryKey)
        // Initialize the wrapped property before consulting another instance
        // property (`store`), then replace it with the validated selection.
        selectedRepoPath = savedPath
        selectedRepoPath = Self.restoredSelection(
            savedPath, repositories: store.repositories)
        // Property observers don't run during initialization. Persist a repaired
        // spelling or fallback so the stored value agrees with the live selection.
        if selectedRepoPath != savedPath {
            Self.persistSelection(selectedRepoPath)
        }
        // Watch-folder discovery: cheap file-system scan, no git invocation.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.scanDiscoveryFolder()
            self?.autoFetchIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        discoveryTimer = timer
    }

    /// Resolves a persisted spelling to the corresponding registered row.
    /// RepoStore treats normalized paths as identity, so startup must do the
    /// same; otherwise a symlink or `.` spelling leaves the detail pane on the
    /// Welcome screen even though that repository is visible in the sidebar.
    private static func restoredSelection(_ savedPath: String?,
                                          repositories: [Repository]) -> String? {
        guard let savedPath else { return repositories.first?.path }
        let normalizedSavedPath = Repository.normalizedPath(savedPath)
        return repositories.first {
            $0.normalizedPath == normalizedSavedPath
        }?.path ?? repositories.first?.path
    }

    private static func persistSelection(_ path: String?) {
        if let path {
            UserDefaults.standard.set(path, forKey: selectedRepositoryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedRepositoryKey)
        }
    }

    deinit {
        discoveryTimer?.invalidate()
    }

    var selectedRepository: Repository? {
        store.repositories.first { $0.path == selectedRepoPath }
    }

    /// The view model for a repo, creating + starting it on first use.
    func viewModel(for repo: Repository) -> RepoViewModel {
        if let existing = viewModels[repo.path] { return existing }
        let vm = RepoViewModel(repo: repo)
        vm.onStatusChange = { [weak self] summary in
            self?.store.summaries[repo.path] = summary
        }
        vm.activityLog.onEvent = { [weak self] event in
            self?.activityStore.record(event, repoName: repo.name, repoPath: repo.path)
        }
        viewModels[repo.path] = vm
        vm.start()
        return vm
    }

    func select(_ repo: Repository) {
        selectedRepoPath = repo.path
        store.markOpened(repo)
        // Warm the view model immediately so the detail pane has data.
        _ = viewModel(for: repo)
    }

    /// Registers the repository containing `url` and selects it.
    ///
    /// Validation shells out to git (twice), so it runs on a background queue —
    /// never the main thread; a slow or network volume must not beachball the
    /// UI while the folder is probed. `completion` runs on the main thread with
    /// the registered repository, or nil when `url` isn't inside a git repository
    /// (in which case `addRepositoryError` is set for the sheet to show).
    func addRepository(at url: URL, completion: ((Repository?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let validated = GitClient.isRepository(at: url) ? GitClient.topLevel(of: url) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?(nil)
                    return
                }
                guard let validated else {
                    // The sheet is the only surface that renders this error — the
                    // drop path reports through dropAddError's alert instead.
                    if self.showingAddRepository {
                        self.addRepositoryError = "“\(url.lastPathComponent)” is not inside a git repository."
                    }
                    completion?(nil)
                    return
                }
                let repo = self.store.register(Repository(url: validated))
                self.select(repo)
                self.refreshSummaries()
                self.lastAddedRepoPath = repo.path
                // Success invalidates any previous failure message, sheet or not.
                self.addRepositoryError = nil
                completion?(repo)
            }
        }
    }

    /// Drop-path wrapper around `addRepository`: a drop has no inline error
    /// surface (the Add sheet isn't open), so failures surface as an alert on
    /// ContentView instead of failing silently.
    func addDroppedRepository(at url: URL) {
        addRepository(at: url) { [weak self] repo in
            guard repo == nil else { return }
            self?.dropAddError = "“\(url.lastPathComponent)” is not inside a git repository — nothing was added."
        }
    }

    func remove(_ repo: Repository) {
        viewModels.removeValue(forKey: repo.path)
        store.remove(repo)
        if selectedRepoPath == repo.path {
            selectedRepoPath = store.repositories.first?.path
        }
    }

    /// Refreshes the sidebar summaries (branch name, dirty dot, ahead/behind) for
    /// every registered repo. Each repo is an independent read-only
    /// `--no-optional-locks` status query, so they run concurrently (windowed, to
    /// avoid a process-spawn burst with dozens of repos) instead of one-by-one —
    /// with 15+ repos a serial pass took seconds on every activation.
    func refreshSummaries() {
        let repos = store.repositories
        guard !repos.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let result = await Self.summaries(for: repos)
            await MainActor.run { self?.store.summaries = result }
        }
    }

    /// The per-repo sidebar summaries, computed for up to `maxConcurrent` repos at
    /// a time. Pure-ish (git reads only); static so tests can drive it directly.
    static func summaries(for repos: [Repository],
                          maxConcurrent: Int = 6) async -> [String: RepoSummary] {
        precondition(maxConcurrent > 0)
        return await withTaskGroup(of: (String, RepoSummary).self) { group in
            var iterator = repos.makeIterator()
            var results: [String: RepoSummary] = [:]
            results.reserveCapacity(repos.count)
            func enqueueNext() {
                guard let repo = iterator.next() else { return }
                group.addTask { (repo.path, Self.summary(for: repo)) }
            }
            for _ in 0..<min(maxConcurrent, repos.count) { enqueueNext() }
            while let (path, summary) = await group.next() {
                results[path] = summary
                enqueueNext()
            }
            return results
        }
    }

    /// One repo's sidebar summary. A missing folder or a failed status read yields
    /// an invalid summary rather than an error — the sidebar shows the warning
    /// triangle instead of pretending everything is fine.
    private static func summary(for repo: Repository) -> RepoSummary {
        let invalid = RepoSummary(branch: nil, isDirty: false, ahead: 0, behind: 0, isValid: false)
        guard FileManager.default.fileExists(atPath: repo.path) else { return invalid }
        let client = GitClient(worktree: repo.url)
        guard let status = try? client.status() else { return invalid }
        return RepoSummary(status: status)
    }

    // MARK: - Auto-fetch

    /// Fetches the active repository when the Settings → General interval
    /// (Never / 5 / 15 / 30 / 60 minutes) has elapsed. Shares the one-minute
    /// discovery timer; skipped while an operation is already running so an
    /// automatic fetch never queues behind (or double-books) a manual one.
    private func autoFetchIfDue() {
        let minutes = UserDefaults.standard.integer(forKey: Self.autoFetchMinutesKey)
        guard minutes > 0 else { return }
        guard let viewModel = activeViewModel, !viewModel.isBusy else { return }
        // Multiply in Double: minutes comes from UserDefaults, where a
        // corrupted/out-of-range value must not trap on Int overflow.
        let lastFetch = lastAutoFetchByRepo[viewModel.repo.path] ?? .distantPast
        guard Date().timeIntervalSince(lastFetch) >= TimeInterval(minutes) * 60 else { return }
        lastAutoFetchByRepo[viewModel.repo.path] = Date()
        viewModel.fetch()
    }

    // MARK: - Watch-folder discovery

    /// Scans the configured watch folder (Settings → General) on a background
    /// queue and adds any new repositories it finds to the sidebar. Runs on a
    /// minute timer, on app activation, on launch, and right after the folder is
    /// changed in Settings. No-op when no folder is configured.
    func scanDiscoveryFolder() {
        let folder = UserDefaults.standard.string(forKey: Self.discoveryFolderKey) ?? ""
        guard !folder.isEmpty else { return }
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = RepoDiscovery.findRepositories(in: root)
            guard !found.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.store.addDiscovered(found) > 0 {
                    self.refreshSummaries()
                }
            }
        }
    }
}
