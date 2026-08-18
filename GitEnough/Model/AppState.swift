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
    private var lastAutoFetch = Date.distantPast

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

    /// Registers the repository containing `url` and selects it. On failure, sets
    /// `addRepositoryError` for the sheet to show.
    @discardableResult
    func addRepository(at url: URL) -> Bool {
        if let repo = store.add(url: url) {
            select(repo)
            refreshSummaries()
            addRepositoryError = nil
            return true
        }
        addRepositoryError = "“\(url.lastPathComponent)” is not inside a git repository."
        return false
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
                    result[repo.path] = RepoSummary(
                        branch: status.head ?? status.headHash.map { String($0.prefix(7)) },
                        isDirty: status.isDirty,
                        ahead: status.ahead,
                        behind: status.behind,
                        isValid: true
                    )
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
        guard Date().timeIntervalSince(lastAutoFetch) >= TimeInterval(minutes * 60) else { return }
        guard let viewModel = activeViewModel, !viewModel.isBusy else { return }
        lastAutoFetch = Date()
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
