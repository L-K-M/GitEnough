import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The left pane: the list of registered repositories with a live summary row
/// (current branch, dirty marker, ahead/behind) and drag-and-drop import.
struct SidebarView: View {

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: RepoStore

    private var selection: Binding<String?> {
        Binding(
            get: { appState.selectedRepoPath },
            set: { path in
                if let path, let repo = store.repositories.first(where: { $0.path == path }) {
                    appState.select(repo)
                } else {
                    appState.selectedRepoPath = nil
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(store.repositories) { repo in
                    SidebarRow(repo: repo, summary: store.summaries[repo.path] ?? .unknown)
                        .tag(repo.path)
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([repo.url])
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(repo.path, forType: .string)
                            }
                            Divider()
                            Button("Remove from GitEnough") {
                                appState.remove(repo)
                            }
                        }
                }
                .onMove { offsets, destination in
                    store.move(fromOffsets: offsets, toOffset: destination)
                }
            } header: {
                Text("Repositories")
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showingAddRepository = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a repository (⌘O)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.repositories.isEmpty {
                Text("Drop a folder to add it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    _ = appState.addRepository(at: url)
                }
            }
        }
        return accepted
    }
}

/// One repository row: name, path, branch + dirty/sync state.
private struct SidebarRow: View {

    let repo: Repository
    let summary: RepoSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(repo.name)
                    .font(.headline)
                    .lineLimit(1)
                if !summary.isValid {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .help("This folder is missing or no longer a git repository.")
                }
                Spacer()
                if summary.isDirty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .help("Uncommitted changes")
                }
            }
            Text(abbreviatingHome(repo.path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                if let branch = summary.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if summary.ahead > 0 {
                    Label("\(summary.ahead)", systemImage: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if summary.behind > 0 {
                    Label("\(summary.behind)", systemImage: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
