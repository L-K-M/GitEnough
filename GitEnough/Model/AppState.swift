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

    let store = RepoStore()

    @Published var selectedRepoPath: String? {
        didSet { UserDefaults.standard.set(selectedRepoPath, forKey: "selectedRepository") }
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

    private var viewModels: [String: RepoViewModel] = [:]

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
        selectedRepoPath = UserDefaults.standard.string(forKey: "selectedRepository")
        if selectedRepoPath == nil {
            selectedRepoPath = store.repositories.first?.path
        }
        // Watch-folder discovery: cheap file-system scan, no git invocation.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.scanDiscoveryFolder()
            self?.autoFetchIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        discoveryTimer = timer
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
    /// every registered repo on a background queue.
    func refreshSummaries() {
        let repos = store.repositories
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [String: RepoSummary] = [:]
            for repo in repos {
                guard FileManager.default.fileExists(atPath: repo.path) else {
                    result[repo.path] = RepoSummary(branch: nil, isDirty: false,
                                                  ahead: 0, behind: 0, isValid: false)
                    continue
                }
                let client = GitClient(worktree: repo.url)
                if let status = try? client.status() {
                    result[repo.path] = RepoSummary(status: status)
                } else {
                    result[repo.path] = RepoSummary(branch: nil, isDirty: false,
                                                  ahead: 0, behind: 0, isValid: false)
                }
            }
            DispatchQueue.main.async {
                self?.store.summaries = result
            }
        }
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
