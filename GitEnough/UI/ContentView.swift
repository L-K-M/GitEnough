import SwiftUI
import AppKit

/// The two-pane shell: repositories on the left, the selected repository on the
/// right.
struct ContentView: View {

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: RepoStore
    @State private var gitAlertDismissed = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } detail: {
            if let repo = appState.selectedRepository {
                RepoDetailView(repo: repo, viewModel: appState.viewModel(for: repo))
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $appState.showingAddRepository) {
            AddRepositoryView()
        }
        .onAppear {
            appState.refreshSummaries()
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
