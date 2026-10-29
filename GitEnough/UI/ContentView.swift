import SwiftUI
import AppKit

/// The two-pane shell: repositories on the left, the selected repository on the
/// right.
struct ContentView: View {

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: RepoStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var windowState: RepositoryWindowState
    @SceneStorage("repositoryPath") private var savedRepositoryPath = ""
    @SceneStorage("repositoryTab") private var savedTab = DetailTab.history.rawValue
    @SceneStorage("repositoryInspectorVisible") private var savedInspectorVisible = true
    @SceneStorage("repositorySidebarVisible") private var savedSidebarVisible = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var gitAlertDismissed = false
    @State private var restored = false
    private let appDelegate: AppDelegate

    init(appState: AppState, appDelegate: AppDelegate) {
        _windowState = StateObject(wrappedValue: RepositoryWindowState(appState: appState))
        self.appDelegate = appDelegate
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } detail: {
            if let repo = windowState.selectedRepository {
                // Distinct identity per repo: view-local state (history
                // filter, selections, sheet drafts) must not leak across a
                // repository switch.
                RepoDetailView(repo: repo, viewModel: appState.viewModel(for: repo))
                    .id(repo.path)
            } else {
                WelcomeView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $windowState.showingAddRepository) {
            AddRepositoryView()
        }
        .alert("Couldn't add repository",
               isPresented: dropErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(windowState.dropAddError ?? "")
        }
        .onAppear {
            appDelegate.appState = appState
            appDelegate.openRepositoryWindow = { [openWindow] in openWindow(id: "repository") }
            if !restored {
                windowState.restore(path: savedRepositoryPath, tab: savedTab,
                                    inspectorVisible: savedInspectorVisible)
                columnVisibility = savedSidebarVisible ? .all : .detailOnly
                restored = true
            }
            appState.refreshSummaries()
            appState.scanDiscoveryFolder()
        }
        .onChange(of: windowState.selectedRepoPath) { _, path in
            savedRepositoryPath = path ?? ""
        }
        .onChange(of: windowState.selectedTab) { _, tab in savedTab = tab.rawValue }
        .onChange(of: windowState.inspectorVisible) { _, visible in savedInspectorVisible = visible }
        .onChange(of: columnVisibility) { _, visibility in
            savedSidebarVisible = visibility != .detailOnly
        }
        .alert("git is not installed", isPresented: gitUnavailable) {
            Button("Install Command Line Tools") {
                try? Process.run(URL(fileURLWithPath: "/usr/bin/xcode-select"),
                                 arguments: ["--install"])
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("GitEnough drives the git command-line tool, which ships with the Xcode Command Line Tools. Install them, then relaunch GitEnough.")
        }
        .background(RepositoryWindowRegistration(state: windowState, delegate: appDelegate))
        .environmentObject(windowState)
        .focusedSceneObject(windowState)
    }

    private var dropErrorPresented: Binding<Bool> {
        Binding(
            get: { windowState.dropAddError != nil },
            set: { isPresented in
                if !isPresented { windowState.dropAddError = nil }
            }
        )
    }

    private var gitUnavailable: Binding<Bool> {
        Binding(
            get: { !GitShell.shared.isAvailable && !gitAlertDismissed },
            set: { isPresented in
                if !isPresented {
                    gitAlertDismissed = true
                    GitShell.shared.reprobe()
                }
            }
        )
    }
}
