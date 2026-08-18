import SwiftUI
import AppKit

/// The History tab: the IntelliJ-style graph on the left of the commit list, and
/// a commit detail pane on the right.
struct HistoryView: View {

    @ObservedObject var viewModel: RepoViewModel

    @State private var selectedHash: String?
    @State private var filterText = ""
    /// What actually drives the filter: trimmed, and debounced ~150 ms so a
    /// fast typer doesn't re-filter thousands of loaded commits per keystroke.
    @State private var activeFilter = ""
    @State private var filterDebounceTask: Task<Void, Never>?
    @State private var branchNameForNewBranch = ""
    @State private var commitForNewBranch: Commit?
    @State private var commitToCheckout: Commit?
    @State private var commitToReset: Commit?

    private var isFiltering: Bool { !activeFilter.isEmpty }

    /// Commits matching the filter (subject / author / hash prefix).
    /// `localizedStandardContains` is Finder-style: case- *and*
    /// diacritic-insensitive, so "muller" finds "Müller". Only searches the
    /// loaded pages — "Load older commits…" widens the searchable set.
    private var visibleCommits: [Commit] {
        guard isFiltering else { return viewModel.commits }
        let needle = activeFilter.lowercased()
        return viewModel.commits.filter {
            $0.subject.localizedStandardContains(activeFilter)
                || $0.author.localizedStandardContains(activeFilter)
                || $0.hash.lowercased().hasPrefix(needle)
        }
    }

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
        .onChange(of: filterText) { _, newValue in
            filterDebounceTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            filterDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                activeFilter = trimmed
            }
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
        // Evaluated once per body evaluation and shared by the list, the
        // empty-state check, and the filter bar's counter.
        let visible = visibleCommits
        return VStack(spacing: 0) {
            filterBar(matchCount: visible.count)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        // The graph only aligns with the full, unfiltered row
                        // sequence — hide it while filtering.
                        if !isFiltering {
                            GraphCanvasView(layout: viewModel.layout,
                                            commitCount: viewModel.commits.count,
                                            headRow: headRow,
                                            selectedRow: selectedRow)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(visible, id: \.id) { commit in
                                CommitRowView(commit: commit,
                                              isSelected: commit.hash == selectedHash,
                                              isHead: commit.isHead)
                                .frame(height: GraphMetrics.rowHeight)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedHash = commit.hash
                                }
                                .contextMenu {
                                    commitContextMenu(commit)
                                }
                            }
                            if isFiltering && visible.isEmpty {
                                VStack(spacing: 4) {
                                    Text("No commits match “\(activeFilter)”")
                                        .font(.callout)
                                    Text("Only the \(viewModel.commits.count) loaded commits are searched — load older commits to search deeper.")
                                        .font(.caption)
                                }
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .padding(.horizontal, 32)
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
            // Reset the scroll offset when toggling the filter — otherwise a
            // deep scroll position can land the filtered (shorter) list in
            // blank space.
            .id(isFiltering)
        }
    }

    // MARK: - Filter bar

    private func filterBar(matchCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter by subject, author, or hash", text: $filterText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if isFiltering {
                Text("\(matchCount) of \(viewModel.commits.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("\(matchCount) of \(viewModel.commits.count) commits shown")
                Button {
                    filterText = ""
                    filterDebounceTask?.cancel()
                    activeFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
                // No Esc shortcut here: .cancelAction would capture Esc
                // window-wide while a filter is active, fighting the sheets
                // and confirmation dialogs this view also hosts.
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
