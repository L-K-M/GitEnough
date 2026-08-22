import SwiftUI
import AppKit

/// The Changes tab: conflict resolution (while merging), staged/unstaged file
/// lists, the commit box with AI message generation, and the diff of the selected
/// file on the right.
struct ChangesView: View {

    @ObservedObject var viewModel: RepoViewModel

    @State private var selection: ChangeSelection?
    @State private var fileToDiscard: FileChange?
    @State private var showingStashSheet = false
    @State private var showingAmendPushedConfirmation = false

    private var conflicts: [FileChange] { viewModel.status.conflicted }
    /// Conflicted files must be visible whenever *any* sequencer operation is in
    /// progress — merges, but also rebases, cherry-picks, and reverts, whose
    /// unmerged entries otherwise vanish from the UI entirely.
    private var conflictUIActive: Bool {
        viewModel.mergeState.isInProgress || viewModel.mergeState.isResolvingConflicts
    }

    /// The subject-line soft limit: git's traditional wrap point and
    /// GitHub's truncation point.
    private static let subjectLimit = 72

    /// Length of the message's first line — the git subject. Splitting on the
    /// full newline character set keeps pasted CRLF text from inflating the
    /// count. Counting grapheme clusters (not bytes) matches how the limit
    /// reads to a human typing non-ASCII text.
    private var subjectLength: Int {
        viewModel.draftCommitMessage.components(separatedBy: .newlines).first?.count ?? 0
    }

    /// Amending a commit that the upstream already contains rewrites public
    /// history (upstream set, nothing ahead → HEAD is reachable from upstream).
    /// The predicate lives on the view model so the warning and the
    /// confirmation gate share one testable source.
    private var amendRewritesPushedCommit: Bool {
        viewModel.amendWouldRewritePushedCommit
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                fileList
                Divider()
                commitBox
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            diffPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, selection in
            viewModel.selectFile(selection?.file, staged: selection?.isStaged ?? false)
        }
        .onChange(of: viewModel.status) { _, status in
            // Keep the selection pointed at the file as it moves between the
            // staged and unstaged lists (FileChange equality includes the status
            // columns, so comparing whole values would drop the selection on
            // every stage/unstage); clear it only when the file is gone from
            // both lists (committed, discarded, resolved).
            guard let selection else { return }
            self.selection = selection.updated(for: status)
        }
        .confirmationDialog("Discard changes?",
                            isPresented: discardConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                if let file = fileToDiscard {
                    viewModel.discard([file])
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if fileToDiscard?.isUntracked == true {
                Text("“\(fileToDiscard?.lastPathComponent ?? "")” is untracked and will be moved to the Trash.")
            } else if fileToDiscard?.isRename == true {
                Text("The original path will be restored. The destination is kept as an untracked file so its contents are not destroyed; discard it again to move it to the Trash.")
            } else if fileToDiscard?.isCopy == true {
                Text("The source file will not be changed. The copied destination is kept as an untracked file; discard it again to move it to the Trash.")
            } else {
                Text("All uncommitted changes to “\(fileToDiscard?.lastPathComponent ?? "")” will be lost.")
            }
        }
        .sheet(isPresented: $showingStashSheet) {
            stashSheet
        }
        .confirmationDialog("Amend a pushed commit?",
                            isPresented: $showingAmendPushedConfirmation,
                            titleVisibility: .visible) {
            Button("Amend Anyway", role: .destructive) {
                viewModel.commit()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The last commit is already on the upstream branch. Amending rewrites public history and requires a force push.")
        }
    }

    private var discardConfirmationPresented: Binding<Bool> {
        Binding(get: { fileToDiscard != nil }, set: { if !$0 { fileToDiscard = nil } })
    }

    /// The right pane never associates a previous patch with a newly selected
    /// row. A spinner covers the content until that exact side finishes loading.
    @ViewBuilder
    private var diffPane: some View {
        if viewModel.isLoadingDiff {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffView(diff: viewModel.selectedFileDiff)
        }
    }

    // MARK: - File lists

    private var fileList: some View {
        List {
            if conflictUIActive {
                Section {
                    ForEach(conflicts) { file in
                        ConflictRow(path: file.path, viewModel: viewModel)
                    }
                } header: {
                    Label("Conflicted Files (\(conflicts.count))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(viewModel.status.staged) { file in
                    FileRow(file: file,
                            repoURL: viewModel.repo.url,
                            isSelected: selection?.file.path == file.path
                                && selection?.isStaged == true,
                            actionIcon: "minus.circle",
                            actionHelp: "Unstage") {
                        selection = ChangeSelection(file: file, isStaged: true)
                    } onAction: {
                        viewModel.unstage([file])
                    } onIgnore: {
                        // Staged files are tracked; ignore only applies to untracked.
                    } onDiscard: {
                        fileToDiscard = file
                    }
                }
            } header: {
                HStack {
                    Text("Staged Changes (\(viewModel.status.staged.count))")
                    Spacer()
                    if !viewModel.status.staged.isEmpty {
                        Button("Unstage All") { viewModel.unstage(viewModel.status.staged) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(viewModel.isBusy)
                    }
                }
            }

            Section {
                ForEach(viewModel.status.unstaged) { file in
                    FileRow(file: file,
                            repoURL: viewModel.repo.url,
                            isSelected: selection?.file.path == file.path
                                && selection?.isStaged == false,
                            actionIcon: "plus.circle",
                            actionHelp: "Stage") {
                        selection = ChangeSelection(file: file, isStaged: false)
                    } onAction: {
                        viewModel.stage([file])
                    } onIgnore: {
                        viewModel.ignore(file)
                    } onDiscard: {
                        fileToDiscard = file
                    }
                }
            } header: {
                HStack {
                    Text("Changes (\(viewModel.status.unstaged.count))")
                    Spacer()
                    if !viewModel.status.unstaged.isEmpty {
                        Button("Stage All") { viewModel.stageAll() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(viewModel.isBusy)
                    }
                }
            } footer: {
                // The stash entry point lives in the section footer so it stays
                // reachable even when everything is staged (the usual
                // "stage, then stash to switch branches" flow). It is hidden
                // only when there is nothing to stash.
                if !viewModel.status.staged.isEmpty || !viewModel.status.unstaged.isEmpty {
                    HStack {
                        Spacer()
                        Button("Stash…") { showingStashSheet = true }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(viewModel.isBusy || conflictUIActive)
                            .help(viewModel.isBusy
                                  ? "Stash is unavailable while an operation is running"
                                  : conflictUIActive
                                  ? "Stash is unavailable while a merge/rebase is in progress"
                                  : "Stash your changes and restore them later")
                    }
                }
            }
        }
        .listStyle(.inset)
        .disabled(viewModel.isBusy)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Commit box

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.draftCommitMessage)
                    .font(.body)
                    .frame(height: 76)
                    .padding(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                if viewModel.draftCommitMessage.isEmpty {
                    Text("Commit message")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }

            if let error = viewModel.messageGenerationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if amendRewritesPushedCommit {
                Label("The last commit is already pushed — amending rewrites public history.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.generateCommitMessage()
                } label: {
                    if viewModel.isGeneratingMessage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .disabled(viewModel.isGeneratingMessage || viewModel.status.staged.isEmpty)
                .help("Write the commit message with the configured LLM (Settings → AI)")

                if !viewModel.draftCommitMessage.isEmpty {
                    Text("\(subjectLength)/\(Self.subjectLimit)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(subjectLength > Self.subjectLimit ? .orange : .secondary)
                        .help("Subject line length — keep it at or under \(Self.subjectLimit) characters")
                        .accessibilityLabel("Subject line length \(subjectLength) of \(Self.subjectLimit)")
                }

                Spacer()

                Toggle("Amend", isOn: $viewModel.amendLastCommit)
                    .toggleStyle(.checkbox)
                    .help("Amend the last commit instead of creating a new one")

                Button("Commit") {
                    // The inline warning can be scrolled past — gate the
                    // action itself when the amend would rewrite a pushed
                    // commit.
                    if amendRewritesPushedCommit {
                        showingAmendPushedConfirmation = true
                    } else {
                        viewModel.commit()
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.draftCommitMessage
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (!viewModel.amendLastCommit && viewModel.status.staged.isEmpty)
                    || viewModel.isBusy)
            }
        }
        .padding(10)
    }

    // MARK: - Stash sheet

    @State private var stashMessage = ""
    @State private var stashIncludeUntracked = false

    private var stashSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Changes")
                .font(.headline)
            TextField("Stash message (optional)", text: $stashMessage)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Toggle("Include untracked files", isOn: $stashIncludeUntracked)
            HStack {
                Spacer()
                Button("Cancel") { showingStashSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Stash") {
                    viewModel.stashPush(message: stashMessage.isEmpty ? nil : stashMessage,
                                        includeUntracked: stashIncludeUntracked)
                    stashMessage = ""
                    showingStashSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
            }
        }
        .padding(20)
    }
}

/// One file row in the staged/unstaged lists: status badge, path, hover action
/// button (stage/unstage), and a context menu.
private struct FileRow: View {

    let file: FileChange
    let repoURL: URL
    let isSelected: Bool
    let actionIcon: String
    let actionHelp: String
    let onSelect: () -> Void
    let onAction: () -> Void
    let onIgnore: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            FileStatusBadge(status: file.displayStatus)
            FilePathText(path: file.path, originalPath: file.originalPath)
                .font(.callout)
            Spacer()
            Button(action: onAction) {
                Image(systemName: actionIcon)
            }
            .buttonStyle(.borderless)
            .help(actionHelp)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onAction) {
                Label(actionHelp, systemImage: actionIcon)
            }
            if file.isUntracked {
                Button("Ignore in .gitignore", action: onIgnore)
            }
            Divider()
            if FileManager.default.fileExists(
                atPath: repoURL.appendingPathComponent(file.path).path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [repoURL.appendingPathComponent(file.path)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            Button {
                NSPasteboard.general.copyString(file.path)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if FileManager.default.fileExists(
                atPath: repoURL.appendingPathComponent(file.path).path) {
                Button {
                    NSWorkspace.shared.open(repoURL.appendingPathComponent(file.path))
                } label: {
                    Label("Open in External Editor", systemImage: "arrow.up.forward.app")
                }
            }
            Divider()
            Button("Discard Changes…", role: .destructive, action: onDiscard)
        }
    }
}

/// One conflicted file with its resolution actions.
private struct ConflictRow: View {

    let path: String
    @ObservedObject var viewModel: RepoViewModel
    /// Bumped by the rescan notification so body re-reads MergeTool.installed.
    @State private var toolsGeneration = 0

    private var tools: [MergeTool] {
        _ = toolsGeneration
        return MergeTool.installed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                FileStatusBadge(status: .unmerged)
                Text(path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            HStack(spacing: 6) {
                Menu {
                    ForEach(tools) { tool in
                        Button(tool.name) {
                            viewModel.openMergeTool(tool, path: path)
                        }
                    }
                    if tools.isEmpty {
                        Text("No merge tools found")
                    }
                } label: {
                    Label("Merge Tool", systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(tools.isEmpty)
                .help("Resolve in an external merge tool")

                Button("Ours") { viewModel.resolveConflict(path: path, ours: true) }
                    .font(.caption)
                    .help("Keep our version of the file")
                Button("Theirs") { viewModel.resolveConflict(path: path, ours: false) }
                    .font(.caption)
                    .help("Take their version of the file")
                Button("Mark Resolved") { viewModel.markResolved(path: path) }
                    .font(.caption)
                    .help("Stage the file as-is (after resolving it yourself)")
            }
            .disabled(viewModel.isBusy)
        }
        .padding(.vertical, 3)
        .onReceive(NotificationCenter.default.publisher(for: MergeTool.didChangeNotification)) { _ in
            toolsGeneration += 1
        }
    }
}

private extension FileChange {
    var lastPathComponent: String {
        (path as NSString).lastPathComponent
    }
}
