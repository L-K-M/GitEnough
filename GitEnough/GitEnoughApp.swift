import SwiftUI

/// Program entry point. GitEnough is a regular windowed app (Dock icon, standard
/// menus) built around a single NavigationSplitView window: repositories on the
/// left, the selected repository on the right.
@main
struct GitEnoughApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        // Warm the merge-tool cache here (main thread, ~18 cheap probes) so
        // the first conflict row doesn't pay the one-time detection hitch.
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

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.store)
        }
    }
}
