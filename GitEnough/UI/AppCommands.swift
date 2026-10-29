import SwiftUI
import AppKit

/// The app's menu-bar commands. Everything here forwards to the active repo's view
/// model; items are disabled when no repository is selected or the model is busy.
struct AppCommands: Commands {

    @ObservedObject var appState: AppState
    let appDelegate: AppDelegate
    @ObservedObject var recentRepositories: RecentRepositoryStore
    @FocusedObject private var windowState: RepositoryWindowState?
    @AppStorage("pullRebase") private var pullRebase = false
    @AppStorage("sidebarGroupingMode") private var sidebarGroupingRaw = SidebarGroupingMode.none.rawValue
    @Environment(\.openWindow) private var openWindow

    private var active: RepoViewModel? { sheetPresented ? nil : windowState?.activeViewModel }
    private var recentURLs: [URL] {
        recentRepositories.urls
    }
    private var sheetPresented: Bool {
        windowState?.isPresentingSheet == true
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "repository") }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Repository…") { appDelegate.openRepository() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(sheetPresented)
            Button("Clone Repository…") { appDelegate.cloneRepository() }
                .keyboardShortcut("o", modifiers: [.shift, .command])
                .disabled(sheetPresented)
            Menu("Open Recent") {
                ForEach(recentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        appDelegate.application(NSApplication.shared, open: [url])
                    }
                    .help(url.path)
                }
                Divider()
                Button("Clear Menu") {
                    NSDocumentController.shared.clearRecentDocuments(nil)
                    recentRepositories.clear()
                }
                .disabled(recentURLs.isEmpty)
            }
            .disabled(sheetPresented)
        }

        CommandMenu("Repository") {
            Button("Fetch") { active?.fetch() }
                .keyboardShortcut("f", modifiers: [.option, .command])
                .disabled(active == nil || active?.isBusy == true || active?.remotes.isEmpty != false)

            Button(pullRebase ? "Pull (Rebase)" : "Pull") { active?.pull(rebase: pullRebase) }
                .keyboardShortcut("l", modifiers: [.shift, .command])
                .disabled(active?.canPull != true)

            Button(active?.pushCapability.label ?? "Push") { active?.pushOrPublish() }
                .keyboardShortcut("p", modifiers: [.shift, .command])
                .disabled(active?.canPushOrPublish != true)

            Button("Open Pull Request…") { active?.openPullRequest() }
                .keyboardShortcut("p", modifiers: [.option, .command])
                .disabled(active == nil || active?.isBusy == true
                          || active?.isResolvingPullRequest == true
                          || active?.remotes.isEmpty != false || active?.status.head == nil)

            Divider()

            Button("New Branch…") { windowState?.showingNewBranch = true }
                .keyboardShortcut("b", modifiers: [.shift, .command])
                .disabled(active == nil || active?.isBusy == true)

            Button("Refresh") { active?.refresh(includeHistory: true) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(active == nil || active?.isBusy == true)

            Divider()

            Button("Show in Finder") {
                if let repo = windowState?.selectedRepository {
                    NSWorkspace.shared.activateFileViewerSelecting([repo.url])
                }
            }
            .disabled(windowState?.selectedRepository == nil)

            Button("Open in Terminal") {
                if let repo = windowState?.selectedRepository {
                    // `open -a Terminal <path>` — avoids the NSWorkspace.OpenConfiguration
                    // init() ambiguity and works on every stock macOS install.
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = ["-a", "Terminal", repo.path]
                    try? process.run()
                }
            }
            .disabled(windowState?.selectedRepository == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("History") { windowState?.selectedTab = .history }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(windowState?.selectedRepository == nil || sheetPresented)
            Button("Changes") { windowState?.selectedTab = .changes }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(windowState?.selectedRepository == nil || sheetPresented)
            Button("Branches") { windowState?.selectedTab = .branches }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(windowState?.selectedRepository == nil || sheetPresented)
            Picker("Group Repositories by", selection: $sidebarGroupingRaw) {
                ForEach(SidebarGroupingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .disabled(windowState == nil || sheetPresented)
            Button("Find Repository") { windowState?.sidebarSearchRequest = UUID() }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(windowState == nil || sheetPresented)
            Divider()
            Button(windowState?.inspectorVisible == true ? "Hide Inspector" : "Show Inspector") {
                windowState?.inspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
            .disabled(windowState?.selectedRepository == nil || windowState?.selectedTab != .history || sheetPresented)
            Divider()
            Button("Git Activity History") { openWindow(id: "git-activity") }
                .keyboardShortcut("a", modifiers: [.shift, .command])
        }
    }
}
