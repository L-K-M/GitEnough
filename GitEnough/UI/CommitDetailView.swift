import SwiftUI

/// The right-hand pane of the History tab: full commit metadata, the changed-file
/// list, and the patch of the selected file.
struct CommitDetailView: View {

    @ObservedObject var viewModel: RepoViewModel
    let selectedHash: String?

    @State private var selectedFile: CommitFile?

    var body: some View {
        if let hash = selectedHash, let detail = viewModel.selectedCommitDetail,
           detail.hash == hash {
            detailView(detail)
        } else if selectedHash != nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyPane(systemImage: "clock.arrow.circlepath",
                      title: "No commit selected",
                      subtitle: "Select a commit in the history to see its details.")
        }
    }

    private func detailView(_ detail: CommitDetail) -> some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header(detail)
                    .padding(12)
                Divider()
                List(selection: $selectedFile) {
                    ForEach(detail.files) { file in
                        HStack(spacing: 6) {
                            FileStatusBadge(status: file.status)
                            Text(file.path)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contextMenu {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.path, forType: .string)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [viewModel.repo.url.appendingPathComponent(file.path)])
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                        }
                        .tag(file)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 120)
            }
            DiffView(diff: viewModel.selectedCommitFileDiff)
        }
        .onChange(of: selectedHash) { _, _ in
            selectedFile = nil
        }
        .onChange(of: selectedFile) { _, file in
            viewModel.selectCommitFile(hash: detail.hash, path: file?.path)
        }
    }

    private func header(_ detail: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.subject)
                .font(.headline)
                .textSelection(.enabled)
            if !detail.body.isEmpty {
                Text(detail.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            HStack(spacing: 12) {
                Label(detail.author, systemImage: "person")
                if let date = detail.date {
                    Label(date.formatted(date: .abbreviated, time: .shortened),
                          systemImage: "calendar")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(detail.shortHash)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail.hash, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy full hash")
                Text("\(detail.files.count) file\(detail.files.count == 1 ? "" : "s") changed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension CommitDetail {
    var shortHash: String { String(hash.prefix(7)) }
}
