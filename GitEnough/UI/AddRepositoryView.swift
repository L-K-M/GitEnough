import SwiftUI
import AppKit

/// Sheet for adding a repository: open a local folder, or clone from a URL.
struct AddRepositoryView: View {

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var localPath: String = ""
    @State private var cloneURL: String = ""
    @State private var cloneDestination: String = ""
    @State private var isCloning = false
    @State private var cloneError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Repository")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 12)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Open a local repository")
                        .font(.headline)
                    HStack {
                        TextField("Path", text: $localPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseForLocalRepository() }
                        Button("Add") { addLocal() }
                            .disabled(localPath.isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clone from a URL")
                        .font(.headline)
                    TextField("https://github.com/owner/repo.git", text: $cloneURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Destination folder", text: $cloneDestination)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseForCloneDestination() }
                    }
                    HStack {
                        if isCloning {
                            ProgressView()
                                .controlSize(.small)
                            Text("Cloning…")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Clone") { clone() }
                            .disabled(cloneURL.isEmpty || cloneDestination.isEmpty || isCloning)
                    }
                    if let cloneError {
                        Text(cloneError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(4)
                    }
                }
                .padding(4)
            }
            .padding(.top, 12)

            if let error = appState.addRepositoryError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 12)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Local

    private func browseForLocalRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            localPath = url.path
            if appState.addRepository(at: url) {
                dismiss()
            }
        }
    }

    private func addLocal() {
        let url = URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath)
        if appState.addRepository(at: url) {
            dismiss()
        }
    }

    // MARK: - Clone

    private func browseForCloneDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            cloneDestination = url.path
        }
    }

    private func clone() {
        let trimmedURL = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let base = URL(fileURLWithPath: (cloneDestination as NSString).expandingTildeInPath)
        // Derive the folder name from the URL, like `git clone` does.
        var name = trimmedURL.components(separatedBy: "/").last ?? "repository"
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !name.isEmpty else {
            cloneError = "Could not derive a folder name from that URL."
            return
        }
        let target = base.appendingPathComponent(name)
        isCloning = true
        cloneError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try GitClient.clone(trimmedURL, into: target)
                DispatchQueue.main.async {
                    isCloning = false
                    if appState.addRepository(at: target) {
                        dismiss()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isCloning = false
                    cloneError = error.localizedDescription
                }
            }
        }
    }
}
