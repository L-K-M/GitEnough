import SwiftUI

/// Program entry point. GitEnough is a regular windowed app (Dock icon, standard
/// menus) built around a single NavigationSplitView window: repositories on the
/// left, the selected repository on the right.
@main
struct GitEnoughApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        // Warm the merge-tool cache before the first frame (~18 cheap probes)
        // so neither the first frame nor the first conflict row pays the
        // one-time detection cost. Synchronously, not hopped onto the main
        // queue: an async hop races view construction, and losing that race
        // puts the detection back inside a body evaluation — the stutter this
        // cache exists to remove. Doing it here also pins the lazy static's
        // one-time initialization to the main thread, which is where its
        // NSWorkspace probes have to run.
        _ = MergeTool.installed
    }

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
