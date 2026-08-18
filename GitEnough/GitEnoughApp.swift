import SwiftUI

/// Program entry point. GitEnough is a regular windowed app (Dock icon, standard
/// menus) built around a single NavigationSplitView window: repositories on the
/// left, the selected repository on the right.
@main
struct GitEnoughApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("GitEnough") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.store)
                .frame(minWidth: 860, minHeight: 520)
                .onAppear { appDelegate.appState = appState }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            AppCommands(appState: appState)
        }

        /// The persistent git command history ("shell history") — one shared
        /// window, reachable via View → Git Activity History (⇧⌘A) or the
        /// status-bar activity popover.
        Window("Git Activity", id: "git-activity") {
            ActivityHistoryView(store: appState.activityStore)
        }
        .defaultSize(width: 760, height: 480)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.store)
        }
    }
}
