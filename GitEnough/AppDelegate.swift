import AppKit

/// Application delegate for the bits SwiftUI doesn't cover: quit when the last
/// window closes, and refresh all repo state when the app becomes active (cheap
/// catch-all next to RepoWatcher's file-mtime polling).
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by GitEnoughApp so the delegate can reach app state.
    weak var appState: AppState?

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
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshSummaries()
        appState?.scanDiscoveryFolder()
        if let repo = appState?.selectedRepository, let state = appState {
            state.viewModel(for: repo).refresh(includeHistory: true)
        }
    }
}
