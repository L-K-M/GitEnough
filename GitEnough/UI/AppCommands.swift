import SwiftUI
import AppKit

/// The app's menu-bar commands. Everything here forwards to the active repo's view
/// model; items are disabled when no repository is selected or the model is busy.
struct AppCommands: Commands {

    @ObservedObject var appState: AppState
    @AppStorage("pullRebase") private var pullRebase = false
    @Environment(\.openWindow) private var openWindow

    private var active: RepoViewModel? { appState.activeViewModel }

    var body: some Commands {
        // Replacing (not adding after) the New Item group removes the default
        // "New Window" command: AppState holds a single global selection, so a
        // second window would just fight the first over the same repository.
        CommandGroup(replacing: .newItem) {
            Button("Add Repository…") {
                appState.showingAddRepository = true
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("Repository") {
            Button("Fetch") { active?.fetch() }
                .keyboardShortcut("f", modifiers: [.option, .command])
                .disabled(active == nil)

            Button(pullRebase ? "Pull (Rebase)" : "Pull") { active?.pull(rebase: pullRebase) }
                .keyboardShortcut("l", modifiers: [.shift, .command])
                .disabled(active?.canPull != true)

            Button("Push") { active?.push() }
                .keyboardShortcut("p", modifiers: [.shift, .command])
                .disabled(active?.canPush != true)

            Button("Open Pull Request…") { active?.openPullRequest() }
                .keyboardShortcut("p", modifiers: [.option, .command])
                .disabled(active == nil)

            Divider()

            Button("New Branch…") { appState.showingNewBranch = true }
                .keyboardShortcut("b", modifiers: [.shift, .command])
                .disabled(active == nil)

            Button("Refresh") { active?.refresh(includeHistory: true) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(active == nil)

            Divider()

            Button("Show in Finder") {
                if let repo = appState.selectedRepository {
                    NSWorkspace.shared.activateFileViewerSelecting([repo.url])
                }
            }
            .disabled(appState.selectedRepository == nil)

            Button("Open in Terminal") {
                if let repo = appState.selectedRepository {
                    // `open -a Terminal <path>` — avoids the NSWorkspace.OpenConfiguration
                    // init() ambiguity and works on every stock macOS install.
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = ["-a", "Terminal", repo.path]
                    try? process.run()
                }
            }
            .disabled(appState.selectedRepository == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("History") { appState.selectedTab = .history }
                .keyboardShortcut("1", modifiers: .command)
            Button("Changes") { appState.selectedTab = .changes }
                .keyboardShortcut("2", modifiers: .command)
            Button("Branches") { appState.selectedTab = .branches }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("Git Activity History") { openWindow(id: "git-activity") }
                .keyboardShortcut("a", modifiers: [.shift, .command])
        }
    }
}
