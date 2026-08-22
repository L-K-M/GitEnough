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
    @State private var commitToTag: Commit?
    @State private var tagName = ""
    @State private var tagMessage = ""
    /// Set by parent-chip navigation: the row the list should scroll into
    /// view (consumed by the ScrollViewReader in historyList).
    @State private var scrollTarget: String?

    private var isFiltering: Bool { !activeFilter.isEmpty }

    /// Commits matching the filter (subject / author / hash prefix / ref
    /// names). `localizedStandardContains` is Finder-style: case- *and*
    /// diacritic-insensitive, so "muller" finds "Müller". Only searches the
    /// loaded pages — "Load older commits…" widens the searchable set.
    /// Ref-name matching (branch / remote / tag decorations) means searching
    /// "feature-x" finds the commit(s) carrying that decoration (typically
    /// the branch tip), not just the ones whose subject happens to mention it.
    private var visibleCommits: [Commit] {
        guard isFiltering else { return viewModel.commits }
        let needle = activeFilter.lowercased()
        return viewModel.commits.filter {
            // Cheapest predicate first: the plain hash-prefix check runs for
            // every commit before the localized folds (which are noticeably
            // more expensive) get a chance to.
            $0.hash.lowercased().hasPrefix(needle)
                || $0.subject.localizedStandardContains(activeFilter)
                || $0.author.localizedStandardContains(activeFilter)
                || $0.decorations.contains {
                    $0.name.localizedStandardContains(activeFilter)
                }
        }
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
        // HStack + fixed-width detail, not HSplitView: an HSplitView inside a
        // NavigationSplitView's detail column redistributes its panes when the
        // detail content swaps between placeholder and commit (selecting a
        // commit visibly resized both right-hand panels), and the fixed width
        // keeps that divider from ever drifting.
        HStack(spacing: 0) {
            historyList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            CommitDetailView(viewModel: viewModel, selectedHash: selectedHash,
                             onSelectCommit: { hash in
                                 // Parent navigation must be able to reveal
                                 // the target: a filter hiding it would leave
                                 // a selection the list can't show. (Both
                                 // fields: the debounce window can leave
                                 // filterText set while activeFilter lags.)
                                 if !filterText.isEmpty || !activeFilter.isEmpty {
                                     filterText = ""
                                     filterDebounceTask?.cancel()
                                     activeFilter = ""
                                 }
                                 // Only scroll when there IS a row to land
                                 // on — a parent beyond the loaded page still
                                 // loads its detail (git show needs no list
                                 // membership), but a scroll would silently
                                 // no-op.
                                 if viewModel.commits.contains(where: { $0.hash == hash }) {
                                     scrollTarget = hash
                                 }
                                 selectedHash = hash
                             })
                .frame(maxHeight: .infinity)
                .frame(width: 360)
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
        .onDisappear {
            filterDebounceTask?.cancel()
        }
        .onChange(of: viewModel.commits.map(\.hash)) { _, hashes in
            // Keep the selection across refreshes; drop it if the commit vanished
            // (e.g. after a reset --hard).
            if let selectedHash, !hashes.contains(selectedHash) {
                self.selectedHash = nil
            }
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
                    ScrollView {
                        VStack(spacing: 0) {
                            commitRows(visible)
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
                    // Reset the scroll offset whenever the (debounced) filter changes —
                    // otherwise a deep scroll position can land the shorter result
                    // list in blank space. Constant ("") while unfiltered.
                    .id(activeFilter)
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                // A beat for the row set to settle (a just-cleared filter
                // re-keys the ScrollView; the target row must exist first).
                // The LazyVStack materializes rows on demand, so a far-off
                // target may still be missing on the first pass — retry once
                // after layout, then give up silently (the detail pane is
                // already showing the commit either way).
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
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
        LazyVStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { row, commit in
                historyRow(row: row, commit: commit)
            }
            if isFiltering && visible.isEmpty {
                emptyFilterState
            }
        }
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private func historyRow(row: Int, commit: Commit) -> some View {
        HStack(spacing: 0) {
            // The graph only aligns with the full, unfiltered row sequence —
            // hide it while filtering.
            if !isFiltering {
                GraphStripView(layout: viewModel.layout, row: row,
                               isHeadRow: row == headRow,
                               isSelected: commit.hash == selectedHash,
                               isUnpushedRow: viewModel.unpushedHashes.contains(commit.hash),
                               clipsTail: row == viewModel.commits.count - 1)
            }
            CommitRowView(commit: commit,
                          isSelected: commit.hash == selectedHash,
                          isHead: commit.isHead)
        }
        .frame(height: GraphMetrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedHash = commit.hash
        }
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
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter by subject, author, hash, or ref", text: $filterText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if isFiltering {
                Text("\(matchCount) of \(viewModel.commits.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("\(matchCount) of \(viewModel.commits.count) commits shown")
            }
            // Visible whenever there's text to clear — including
            // whitespace-only input that doesn't (yet) activate filtering.
            if !filterText.isEmpty {
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
        // Fill the fixed-height row frame (applied by the caller) so the
        // selection background is as tall as the graph strip next to it, not
        // just as tall as the text.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
    }
}
