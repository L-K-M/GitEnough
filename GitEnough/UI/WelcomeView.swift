import SwiftUI
import AppKit

/// Shown when no repository is selected (fresh install, or after removing all).
struct WelcomeView: View {

    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("GitEnough")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("A git client that is just enough.\nAdd a repository to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    appState.showingAddRepository = true
                } label: {
                    Label("Add Repository…", systemImage: "plus")
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            Text("You can also drop any folder into the sidebar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
