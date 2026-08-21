import AppKit

/// Application delegate for the bits SwiftUI doesn't cover: quit when the last
/// window closes, and refresh all repo state when the app becomes active (cheap
/// catch-all next to RepoWatcher's file-mtime polling).
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by GitEnoughApp so the delegate can reach app state.
    weak var appState: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshSummaries()
        appState?.scanDiscoveryFolder()
        if let repo = appState?.selectedRepository, let state = appState {
            // Cheap refresh only: reloading the full topo log + graph layout on
            // every Cmd-Tab back was pure cost (a visible hitch on large
            // repos). The 2.5 s RepoWatcher owns history invalidation — its
            // timer fires promptly on activation even after App Nap, so
            // external commits made while backgrounded are caught within one
            // poll interval.
            state.viewModel(for: repo).refresh(includeHistory: false)
        }
    }
}
