import SwiftUI

/// The right-hand pane of the History tab: full commit metadata, the changed-file
/// list, and the patch of the selected file.
struct CommitDetailView: View {

    @ObservedObject var viewModel: RepoViewModel
    let selectedHash: String?
    /// Selects another commit in the history list (parent-chip navigation).
    var onSelectCommit: ((String) -> Void)? = nil

    @State private var selectedFile: CommitFile?
    @State private var bodyExpanded = false

    private static let collapsedBodyLineLimit = 6

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
                            if FileManager.default.fileExists(
                                atPath: viewModel.repo.url.appendingPathComponent(file.path).path) {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [viewModel.repo.url.appendingPathComponent(file.path)])
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }
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
            bodyExpanded = false
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
                    .lineLimit(bodyExpanded ? nil : Self.collapsedBodyLineLimit)
                if detail.bodyNeedsExpansionToggle {
                    Button(bodyExpanded ? "Show less" : "Show more") {
                        bodyExpanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
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
            if !detail.parents.isEmpty {
                HStack(spacing: 6) {
                    Text(detail.parents.count > 1 ? "Merge of" : "Parent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(detail.parents, id: \.self) { parent in
                        Button {
                            onSelectCommit?(parent)
                        } label: {
                            Text(String(parent.prefix(7)))
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Select parent \(parent.prefix(7)) in the history")
                    }
                }
            }
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
    /// True when the collapsed view plausibly hides content. lineLimit counts
    /// *wrapped, rendered* lines while components(separatedBy:) counts logical
    /// ones, so a short-line-count body of long paragraphs also gets the
    /// toggle via a character threshold (≈6 wrapped lines at this width).
    var bodyNeedsExpansionToggle: Bool {
        body.components(separatedBy: "\n").count > 6 || body.count > 240
    }
}
