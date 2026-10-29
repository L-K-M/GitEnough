import AppKit
import Combine
import SwiftUI

/// Navigation belongs to a window; repository models and their operation queues
/// belong to the app. Two windows can browse independently without running git
/// through two competing queues for the same working copy.
final class RepositoryWindowState: ObservableObject {
    let appState: AppState
    weak var window: NSWindow?

    @Published var selectedRepoPath: String? {
        didSet {
            guard selectedRepoPath != oldValue else { return }
            observeActiveRepository()
        }
    }
    @Published var selectedTab: DetailTab = .history
    @Published var inspectorVisible = true
    @Published var sidebarSearchRequest = UUID()
    @Published var showingAddRepository = false
    @Published var showingNewBranch = false
    @Published private(set) var isOpeningRepository = false
    @Published var hasAttachedSheet = false
    @Published var lastAddedRepoPath: String?
    @Published var dropAddError: String?
    @Published var addRepositoryError: String?

    private var repositoryObservation: AnyCancellable?
    private var storeObservation: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        selectedRepoPath = appState.selectedRepoPath
        storeObservation = appState.store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repairSelection() }
    }

    var selectedRepository: Repository? {
        appState.store.repositories.first { $0.path == selectedRepoPath }
    }

    var activeViewModel: RepoViewModel? {
        selectedRepository.map { appState.viewModel(for: $0) }
    }

    var isPresentingSheet: Bool {
        showingAddRepository || showingNewBranch || isOpeningRepository || hasAttachedSheet
    }

    func select(_ repo: Repository) {
        selectedRepoPath = repo.path
        // Keep the established last-used repository key for existing installs
        // and the Linux front end. Other windows do not observe this selection.
        appState.select(repo)
        observeActiveRepository()
    }

    func activate() {
        // Background auto-fetch uses AppState's active repository. Focusing an
        // existing window must update it just as choosing a sidebar row does.
        if let repo = selectedRepository { appState.select(repo) }
    }

    func restore(path: String, tab: String, inspectorVisible: Bool) {
        if !path.isEmpty,
           let repo = appState.store.repositories.first(where: {
               $0.normalizedPath == Repository.normalizedPath(path)
           }) {
            selectedRepoPath = repo.path
        }
        selectedTab = DetailTab(rawValue: tab) ?? .history
        self.inspectorVisible = inspectorVisible
        repairSelection()
        observeActiveRepository()
        if window?.isKeyWindow == true { activate() }
    }

    func remove(_ repo: Repository) {
        appState.remove(repo)
        repairSelection()
    }

    func addRepository(at url: URL, completion: ((Repository?) -> Void)? = nil) {
        appState.addRepository(at: url) { [weak self] repo in
            guard let self else { completion?(repo); return }
            if let repo {
                self.select(repo)
                self.lastAddedRepoPath = repo.path
                self.addRepositoryError = nil
                NSDocumentController.shared.noteNewRecentDocumentURL(repo.url)
            } else {
                self.addRepositoryError = "“\(url.lastPathComponent)” is not inside a git repository."
            }
            completion?(repo)
        }
    }

    func addDroppedRepository(at url: URL) {
        addRepository(at: url) { [weak self] repo in
            if repo == nil { self?.dropAddError = self?.addRepositoryError }
        }
    }

    func openRepository() {
        guard !isPresentingSheet else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Repository"
        panel.prompt = "Open"
        panel.message = "Choose a Git repository or a folder inside one."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        isOpeningRepository = true
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isOpeningRepository = false
            guard response == .OK, let url = panel.url else { return }
            self?.addDroppedRepository(at: url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            panel.begin(completionHandler: complete)
        }
    }

    private func repairSelection() {
        guard selectedRepository == nil else { return }
        selectedRepoPath = appState.store.repositories.first?.path
    }

    private func observeActiveRepository() {
        repositoryObservation = activeViewModel?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// Supplies the actual hosting window for attached panels and Finder/Dock
/// routing. No window title or global key-window guess is used for identity.
struct RepositoryWindowRegistration: NSViewRepresentable {
    let state: RepositoryWindowState
    let delegate: AppDelegate

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.state = state
        view.appDelegate = delegate
        return view
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.state = state
        nsView.appDelegate = delegate
        nsView.registerWindow()
    }

    final class RegistrationView: NSView {
        weak var state: RepositoryWindowState?
        weak var appDelegate: AppDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerWindow()
        }

        func registerWindow() {
            guard let window, let state else { return }
            state.window = window
            appDelegate?.register(window: window, state: state)
        }
    }
}
