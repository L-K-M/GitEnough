import SwiftUI
import AppKit

/// Cloning has its own sheet; opening an existing repository uses NSOpenPanel.
struct AddRepositoryView: View {

    @EnvironmentObject var windowState: RepositoryWindowState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var urlFocused: Bool

    @State private var cloneURL = ""
    @State private var cloneDestination = ""
    @State private var isCloning = false
    @State private var cloneError: String?

    private var canClone: Bool {
        !cloneURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cloneDestination.isEmpty && !isCloning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Repository")
                .font(.title2.weight(.semibold))
            Text("Download a working copy from a Git remote.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Repository URL:", text: $cloneURL,
                          prompt: Text("https://github.com/owner/repository.git"))
                    .focused($urlFocused)
                    .autocorrectionDisabled()
                    .help("HTTPS, SSH, and git@host:owner/repository.git URLs are supported.")
                LabeledContent("Clone into:") {
                    HStack {
                        Text(cloneDestination.isEmpty ? "Choose a folder" : (cloneDestination as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(cloneDestination.isEmpty ? .secondary : .primary)
                            .help(cloneDestination)
                        Spacer()
                        Button("Choose…") { browseForCloneDestination() }
                    }
                }
            }
            .disabled(isCloning)

            if let name = CloneURL(cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)).suggestedFolderName,
               !cloneDestination.isEmpty {
                Text("A new folder named “\(name)” will be created inside the chosen folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = cloneError ?? windowState.addRepositoryError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(5)
            }

            HStack {
                if isCloning {
                    ProgressView().controlSize(.small)
                    Text("Cloning repository…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCloning)
                Button("Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canClone)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(isCloning)
        .onAppear {
            windowState.addRepositoryError = nil
            urlFocused = true
        }
    }

    private func browseForCloneDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder that will contain your new working copy."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { cloneDestination = url.path }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func clone() {
        guard canClone else { return }
        let trimmedURL = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(fileURLWithPath: (cloneDestination as NSString).expandingTildeInPath)
        guard let name = CloneURL(trimmedURL).suggestedFolderName else {
            cloneError = "Enter a Git URL with a repository name."
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
                    windowState.addRepository(at: target) { repo in
                        if repo != nil { dismiss() }
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
