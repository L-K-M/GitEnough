import SwiftUI
import AppKit

/// The History tab: the IntelliJ-style graph on the left of the commit list, and
/// a commit detail pane on the right.
struct HistoryView: View {

    @ObservedObject var viewModel: RepoViewModel
    @EnvironmentObject private var windowState: RepositoryWindowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var selectionModel = HistorySelectionModel()
    @State private var searchFocusRequest = 0

    @State private var listFocusRequest = UUID()
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
    @State private var commitToTag: Commit?
    @State private var tagName = ""
    @State private var tagMessage = ""
    /// Set by parent-chip navigation: the row the list should scroll into
    /// view (consumed by the ScrollViewReader in historyList).
    @State private var scrollTarget: String?

    private var isFiltering: Bool { !activeFilter.isEmpty }

    /// Commits matching the filter (subject / author / email / hash prefix / ref
    /// names). `localizedStandardContains` is Finder-style: case- *and*
    /// diacritic-insensitive, so "muller" finds "Müller". Only searches the
    /// loaded pages — "Load older commits…" widens the searchable set.
    /// Ref-name matching (branch / remote / tag decorations) means searching
    /// "feature-x" finds the commit(s) carrying that decoration (typically
    /// the branch tip), not just the ones whose subject happens to mention it.
    private var visibleCommits: [Commit] {
        HistorySearch.filter(viewModel.commits, query: activeFilter)
    }

    private var headRow: Int? {
        viewModel.commits.firstIndex { $0.isHead }
    }

    var body: some View {
        // Split into two builder expressions (core + dialogs): as one giant
        // expression this body timed the Swift type-checker out on CI.
        historyCore
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

    private var historyCore: some View {
        historyList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: $windowState.inspectorVisible) {
                CommitDetailView(viewModel: viewModel, selectionModel: selectionModel,
                                 selectedHash: selectedHash, onSelectCommit: selectParent)
                    .inspectorColumnWidth(min: 300, ideal: 380, max: 680)
            }
            .focusedSceneValue(\.historyCommands, historyCommandContext)
            .onChange(of: selectedHash) { _, newValue in
                selectionModel.selectCommit(newValue, in: viewModel)
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
        .onChange(of: activeFilter) { _, query in
            let visible = visibleCommits
            // Actions in the Commit menu must describe a row the search can
            // show. Clearing a search still permits parent-chip navigation to
            // an older commit beyond the currently loaded history page.
            if query.isEmpty {
                if selectedHash == nil { selectedHash = visible.first?.hash }
            } else if !visible.contains(where: { $0.hash == selectedHash }) {
                selectedHash = visible.first?.hash
            }
        }
        .onAppear {
            if selectedHash == nil { selectedHash = viewModel.commits.first?.hash }
        }
        .onDisappear {
            filterDebounceTask?.cancel()
        }
        .onChange(of: viewModel.commits.map(\.hash)) { _, hashes in
            // A first load selects the newest commit. If history is rewritten,
            // move a vanished selection to the newest remaining row.
            let visible = visibleCommits
            if let selectedHash,
               !hashes.contains(selectedHash)
                || (isFiltering && !visible.contains(where: { $0.hash == selectedHash })) {
                self.selectedHash = visible.first?.hash
            } else if selectedHash == nil {
                selectedHash = visible.first?.hash
            }
        }
    }

    private var historyCommandContext: HistoryCommandContext? {
        guard commitForNewBranch == nil, commitToTag == nil,
              commitToCheckout == nil, commitToReset == nil,
              !windowState.isPresentingSheet else {
            return nil
        }
        return HistoryCommandContext(
            find: { searchFocusRequest &+= 1 },
            selectedCommitCommands: selectedCommit.map { AnyView(commitContextMenu($0)) })
    }

    private var selectedCommit: Commit? {
        viewModel.commits.first { $0.hash == selectedHash }
    }

    private func selectParent(_ hash: String) {
        filterDebounceTask?.cancel()
        filterText = ""
        activeFilter = ""
        if viewModel.commits.contains(where: { $0.hash == hash }) {
            scrollTarget = hash
        }
        selectedHash = hash
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
        let showsUnbornEmptyState = viewModel.status.isUnborn && viewModel.commits.isEmpty
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if showsUnbornEmptyState {
                    // A fresh `git init` used to render a silent blank pane here —
                    // and a filter bar over it would be noise, so the whole layout
                    // branches on one condition. (Gated on isUnborn, not on the
                    // commit list alone — an empty list is also the initial-load
                    // state of a normal repo.)
                    EmptyPane(systemImage: "clock.arrow.circlepath",
                              title: "No commits yet",
                              subtitle: "The history graph starts with your first commit — stage your files in the Changes tab and commit.")
                        .background(Color(nsColor: .textBackgroundColor))
                } else {
                    filterBar(matchCount: visible.count)
                    Divider()
                    List(selection: Binding(get: { selectedHash }, set: {
                        selectedHash = $0
                        listFocusRequest = UUID()
                    })) {
                        commitRows(visible)
                        if viewModel.canLoadMoreHistory {
                            Button("Load Older Commits…") { viewModel.loadMoreHistory() }
                                .buttonStyle(.link)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .listRowSeparator(.hidden)
                                .disabled(viewModel.isBusy)
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, GraphMetrics.rowHeight)
                    .accessibilityLabel("Commit history")
                    .id(activeFilter)

                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                // A beat for the row set to settle (a just-cleared filter
                // re-keys the ScrollView; the target row must exist first).
                // A distant row may not exist on the first layout pass.
                // Retry once
                // after layout, then give up silently (the detail pane is
                // already showing the commit either way).
                DispatchQueue.main.async {
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(target, anchor: .center) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(target, anchor: .center) }
                        scrollTarget = nil
                    }
                }
            }
        }
    }

    // Kept as small, separate @ViewBuilder pieces: one giant builder
    // expression here sent the type-checker past its time limit.
    @ViewBuilder
    private func commitRows(_ visible: [Commit]) -> some View {
        ForEach(Array(visible.enumerated()), id: \.element.id) { row, commit in
            historyRow(row: row, commit: commit)
                .tag(commit.hash)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                .listRowSeparator(.hidden)
        }
        if isFiltering && visible.isEmpty {
            emptyFilterState
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func historyRow(row: Int, commit: Commit) -> some View {
        HStack(spacing: 0) {
            // The graph only aligns with the full, unfiltered row sequence —
            // hide it while filtering.
            if !isFiltering {
                GraphStripView(layout: viewModel.layout, row: row,
                               isHeadRow: row == headRow,
                               isSelected: false,
                               isUnpushedRow: viewModel.unpushedHashes.contains(commit.hash),
                               clipsTail: row == viewModel.commits.count - 1)
            }
            CommitRowView(commit: commit, isHead: commit.isHead)
        }
        .frame(height: GraphMetrics.rowHeight)
        .contentShape(Rectangle())
        .nativeListRowFocus(isSelected: commit.hash == selectedHash, focusRequest: listFocusRequest)
        .contextMenu {
            commitContextMenu(commit)
        }
        // Stable identity for ScrollViewProxy.scrollTo (parent navigation).
        .id(commit.hash)
    }

    private var emptyFilterState: some View {
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

    // MARK: - Filter bar

    private func filterBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            HistorySearchField(text: $filterText, focusRequest: searchFocusRequest)
                .frame(height: 24)
            if isFiltering {
                Text("\(matchCount) of \(viewModel.commits.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("\(matchCount) of \(viewModel.commits.count) commits shown")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private func commitContextMenu(_ commit: Commit) -> some View {
        Button("Copy Hash") {
            NSPasteboard.general.copyString(commit.hash)
        }
        Button("Copy Subject") {
            NSPasteboard.general.copyString(commit.subject)
        }
        // "abc1234 Subject" — the shape reflog, PR descriptions, and chat
        // references use.
        Button("Copy Hash and Subject") {
            NSPasteboard.general.copyString("\(commit.shortHash) \(commit.subject)")
        }
        // Built once per render: the command both feeds the action and gates
        // the item (disabled, never silently dead, in the
        // unreachable-by-construction case of a hash that isn't clean hex).
        let cherryPickCommand = CommitCommands.cherryPickCommand(forHash: commit.hash)
        Button("Copy Cherry-pick Command") {
            // `git cherry-pick <hash>` for the terminal-hybrid workflow:
            // paste-ready in any shell. Deliberately no -x: it matches the
            // app's own Cherry-pick action, which doesn't record provenance
            // either.
            if let cherryPickCommand {
                NSPasteboard.general.copyString(cherryPickCommand)
            }
        }
        .disabled(cherryPickCommand == nil)
        Divider()
        Group {
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
            if commit.isMerge {
                // A merge replays differently depending on which parent is the
                // baseline: -m 1 is "what the merge brought onto the branch it
                // landed on", -m 2 the reverse (relevant for merge-back commits).
                // One item per parent keeps the choice explicit — and covers
                // octopus merges too.
                ForEach(Array(commit.parents.enumerated()), id: \.offset) { index, parent in
                    Button("Cherry-pick Merge vs. Parent \(index + 1) (\(String(parent.prefix(7))))") {
                        viewModel.cherryPick(commit.hash, mainline: index + 1)
                    }
                }
                // Reverting keeps the canonical "undo what the merge brought onto
                // this branch" semantic: always against the first parent.
                Button("Revert Merge (vs. First Parent)") {
                    viewModel.revert(commit.hash, mainline: 1)
                }
            } else {
                Button("Cherry-pick onto Current Branch") {
                    viewModel.cherryPick(commit.hash)
                }
                Button("Revert Commit") {
                    viewModel.revert(commit.hash)
                }
            }
            Divider()
            Button("Reset Current Branch to Here…") {
                commitToReset = commit
            }
        }
        .disabled(viewModel.isBusy)
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
            TextField("Message (optional — makes an annotated tag)", text: $tagMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
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
                .disabled(tagName.trimmingCharacters(in: .whitespaces).isEmpty
                          || tagName.trimmingCharacters(in: .whitespaces).hasPrefix("-"))
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
        // Fill the fixed-height row frame (applied by the caller) so the
        // selection background is as tall as the graph strip next to it, not
        // just as tall as the text.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
