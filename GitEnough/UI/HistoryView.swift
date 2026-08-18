import SwiftUI
import AppKit

/// The History tab: the IntelliJ-style graph on the left of the commit list, and
/// a commit detail pane on the right.
struct HistoryView: View {

    @ObservedObject var viewModel: RepoViewModel

    @State private var selectedHash: String?
    @State private var branchNameForNewBranch = ""
    @State private var commitForNewBranch: Commit?
    @State private var commitToCheckout: Commit?
    @State private var commitToReset: Commit?
    @State private var commitToTag: Commit?
    @State private var tagName = ""
    @State private var tagMessage = ""

    private var headRow: Int? {
        viewModel.commits.firstIndex { $0.isHead }
    }

    private var selectedRow: Int? {
        viewModel.commits.firstIndex { $0.hash == selectedHash }
    }

    var body: some View {
        HSplitView {
            historyList
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            CommitDetailView(viewModel: viewModel, selectedHash: selectedHash)
                .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selectedHash) { _, newValue in
            viewModel.selectCommit(newValue)
        }
        .onChange(of: viewModel.commits.map(\.hash)) { _, hashes in
            // Keep the selection across refreshes; drop it if the commit vanished
            // (e.g. after a reset --hard).
            if let selectedHash, !hashes.contains(selectedHash) {
                self.selectedHash = nil
            }
        }
        .sheet(item: $commitForNewBranch) { commit in
            newBranchSheet(for: commit)
        }
        .sheet(item: $commitToTag) { commit in
            newTagSheet(for: commit)
        }
        .confirmationDialog("Check out \(commitToCheckout?.shortHash ?? "")?",
                            isPresented: checkoutConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Check Out Commit") {
                if let commit = commitToCheckout {
                    viewModel.checkoutCommit(commit.hash)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This detaches HEAD at \(commitToCheckout?.shortHash ?? ""). New commits here won't belong to any branch unless you create one.")
        }
        .confirmationDialog("Reset current branch to \(commitToReset?.shortHash ?? "")?",
                            isPresented: resetConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Soft — keep index and worktree") {
                if let c = commitToReset { viewModel.reset(to: c.hash, mode: .soft) }
            }
            Button("Mixed — keep worktree, reset index") {
                if let c = commitToReset { viewModel.reset(to: c.hash, mode: .mixed) }
            }
            Button("Hard — discard everything", role: .destructive) {
                if let c = commitToReset { viewModel.reset(to: c.hash, mode: .hard) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var checkoutConfirmationPresented: Binding<Bool> {
        Binding(get: { commitToCheckout != nil }, set: { if !$0 { commitToCheckout = nil } })
    }

    private var resetConfirmationPresented: Binding<Bool> {
        Binding(get: { commitToReset != nil }, set: { if !$0 { commitToReset = nil } })
    }

    // MARK: - List

    private var historyList: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    GraphCanvasView(layout: viewModel.layout,
                                    commitCount: viewModel.commits.count,
                                    headRow: headRow,
                                    selectedRow: selectedRow)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.commits.enumerated()), id: \.element.id) { index, commit in
                            CommitRowView(commit: commit,
                                          isSelected: commit.hash == selectedHash,
                                          isHead: index == headRow)
                            .frame(height: GraphMetrics.rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedHash = commit.hash
                            }
                            .contextMenu {
                                commitContextMenu(commit)
                            }
                        }
                    }
                    .padding(.trailing, 12)
                }
                if viewModel.canLoadMoreHistory {
                    Button("Load older commits…") {
                        viewModel.loadMoreHistory()
                    }
                    .buttonStyle(.link)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func commitContextMenu(_ commit: Commit) -> some View {
        Button("Copy Hash") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.hash, forType: .string)
        }
        Button("Copy Message") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.subject, forType: .string)
        }
        Divider()
        Button("Create Branch Here…") {
            branchNameForNewBranch = ""
            commitForNewBranch = commit
        }
        Button("Tag This Commit…") {
            tagName = ""
            tagMessage = ""
            commitToTag = commit
        }
        Button("Check Out Commit…") {
            commitToCheckout = commit
        }
        Divider()
        Button("Cherry-pick onto Current Branch") {
            viewModel.cherryPick(commit.hash)
        }
        Button("Revert Commit") {
            viewModel.revert(commit.hash)
        }
        Divider()
        Button("Reset Current Branch to Here…") {
            commitToReset = commit
        }
    }

    private func newBranchSheet(for commit: Commit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Branch at \(commit.shortHash)")
                .font(.headline)
            Text(commit.subject)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("Branch name", text: $branchNameForNewBranch)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel") { commitForNewBranch = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    viewModel.createBranchAtCommit(
                        named: branchNameForNewBranch.trimmingCharacters(in: .whitespaces),
                        hash: commit.hash)
                    commitForNewBranch = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(branchNameForNewBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private func newTagSheet(for commit: Commit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag \(commit.shortHash)")
                .font(.headline)
            Text(commit.subject)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("Tag name", text: $tagName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            TextField("Message (optional — makes an annotated tag)", text: $tagMessage)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel") { commitToTag = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create Tag") {
                    let message = tagMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.createTag(
                        named: tagName.trimmingCharacters(in: .whitespaces),
                        message: message.isEmpty ? nil : message,
                        at: commit.hash)
                    commitToTag = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tagName.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

/// One row of the commit list, aligned with the graph: subject, ref chips,
/// author, relative date.
private struct CommitRowView: View {

    let commit: Commit
    let isSelected: Bool
    let isHead: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                .fontWeight(isHead ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)

            ForEach(commit.decorations.prefix(3)) { decoration in
                RefChip(decoration: decoration)
            }
            if commit.decorations.count > 3 {
                Text("+\(commit.decorations.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(commit.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            RelativeDateText(date: commit.date)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.leading, 8)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
    }
}
