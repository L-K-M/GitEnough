import AppKit

/// App-wide activation and external-open handling. Closing a repository window
/// leaves the app running; the Dock can bring back a workspace.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by GitEnoughApp so the delegate can reach app state.
    weak var appState: AppState?
    var openRepositoryWindow: (() -> Void)?

    private final class WindowReference {
        weak var window: NSWindow?
        weak var state: RepositoryWindowState?
        var observers: [NSObjectProtocol] = []

        init(window: NSWindow, state: RepositoryWindowState) {
            self.window = window
            self.state = state
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private var repositoryWindows: [ObjectIdentifier: WindowReference] = [:]
    private var pendingOpenURLs: [URL] = []
    private var pendingOpenPanel = false
    private var pendingCloneSheet = false
    private var lastFocusedRepositoryWindow: ObjectIdentifier?

    override init() {
        // GitShell pipes commit messages to `git commit -F -` on a helper
        // thread. If the child exits before draining stdin (a fast-failing
        // hook, an index.lock race) and the message exceeds the pipe buffer,
        // write() on the broken pipe raises SIGPIPE — whose default
        // disposition kills the whole app. Ignore it process-wide so the
        // write surfaces as an ordinary error instead; nothing in the app
        // relies on SIGPIPE semantics. Installed in init (the adaptor runs it
        // during bootstrap) so no early startup work can race ahead of it;
        // GitShell installs the same disposition lazily on first use, so tests
        // and future entry points are covered even without this delegate.
        // Caveat: ignored dispositions survive exec(), so spawned tools see
        // EPIPE returns instead of dying from SIGPIPE — git handles EPIPE
        // fine; keep it in mind for other piped tools.
        super.init()
        _ = signal(SIGPIPE, SIG_IGN)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func register(window: NSWindow, state: RepositoryWindowState) {
        let identity = ObjectIdentifier(window)
        let isNewWindow = repositoryWindows[identity] == nil
        if isNewWindow {
            let reference = WindowReference(window: window, state: state)
            repositoryWindows[identity] = reference
            reference.observers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                       object: window, queue: .main) { [weak self, weak state] _ in
                    self?.lastFocusedRepositoryWindow = identity
                    state?.activate()
                },
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                       object: window, queue: .main) { [weak self] _ in
                    self?.repositoryWindows.removeValue(forKey: identity)
                },
                NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification,
                                                       object: window, queue: .main) { [weak state] _ in
                    state?.hasAttachedSheet = true
                },
                NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                                                       object: window, queue: .main) { [weak state] _ in
                    state?.hasAttachedSheet = false
                }
            ]
            if window.isKeyWindow {
                lastFocusedRepositoryWindow = identity
                DispatchQueue.main.async { [weak state] in state?.activate() }
            }
        }
        // Only a newly created workspace consumes a queued open. A background
        // update to a window with a pending sheet must not redirect that request
        // into the sheet's underlying repository.
        guard isNewWindow else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for url in urls { state.addDroppedRepository(at: url) }
        if pendingOpenPanel {
            pendingOpenPanel = false
            DispatchQueue.main.async { state.openRepository() }
        }
        if pendingCloneSheet {
            pendingCloneSheet = false
            DispatchQueue.main.async { state.showingAddRepository = true }
        }
    }

    private var preferredRepositoryWindow: WindowReference? {
        NSApplication.shared.keyWindow.flatMap { repositoryWindows[ObjectIdentifier($0)] }
            ?? lastFocusedRepositoryWindow.flatMap { repositoryWindows[$0] }
            ?? repositoryWindows.values.first(where: { $0.window?.isVisible == true && $0.state != nil })
    }

    func openRepository() {
        if let target = preferredRepositoryWindow, let state = target.state,
           !state.isPresentingSheet {
            target.window?.makeKeyAndOrderFront(nil)
            state.openRepository()
        } else {
            pendingOpenPanel = true
            openRepositoryWindow?()
        }
    }

    func cloneRepository() {
        if let target = preferredRepositoryWindow, let state = target.state,
           !state.isPresentingSheet {
            target.window?.makeKeyAndOrderFront(nil)
            state.showingAddRepository = true
        } else {
            pendingCloneSheet = true
            openRepositoryWindow?()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                     hasVisibleWindows flag: Bool) -> Bool {
        if let reference = preferredRepositoryWindow,
           let window = reference.window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openRepositoryWindow?()
        }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        if let target = preferredRepositoryWindow, let state = target.state,
           !state.isPresentingSheet {
            target.window?.makeKeyAndOrderFront(nil)
            for url in urls { state.addDroppedRepository(at: url) }
        } else {
            pendingOpenURLs.append(contentsOf: urls)
            openRepositoryWindow?()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshSummaries()
        appState?.scanDiscoveryFolder()
        if let state = appState {
            // Cheap refresh only: reloading the full topo log + graph layout on
            // every Cmd-Tab back was pure cost (a visible hitch on large
            // repos). The 2.5 s RepoWatcher owns history invalidation — its
            // timer fires promptly on activation even after App Nap, so
            // external commits made while backgrounded are caught within one
            // poll interval.
            let paths = Set(repositoryWindows.values.compactMap { $0.state?.selectedRepoPath })
            for repo in state.store.repositories where paths.contains(repo.path) {
                state.viewModel(for: repo).refresh(includeHistory: false)
            }
        }
    }
}
