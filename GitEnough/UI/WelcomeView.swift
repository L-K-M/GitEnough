import SwiftUI
import AppKit

/// Shown when no repository is selected (fresh install, or after removing all).
struct WelcomeView: View {

    @EnvironmentObject var windowState: RepositoryWindowState

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("GitEnough")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("A git client that is just good enough.\nOpen a repository to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    windowState.openRepository()
                } label: {
                    Label("Open Repository…", systemImage: "folder")
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Clone Repository…") { windowState.showingAddRepository = true }
                    .controlSize(.large)
            }
            Text("You can also drop any folder into the sidebar, or set a watch folder in Settings → General.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
