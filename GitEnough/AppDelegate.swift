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
            state.viewModel(for: repo).refresh(includeHistory: true)
        }
    }
}
