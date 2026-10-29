import SwiftUI
import AppKit

/// The Changes tab: conflict resolution (while merging), staged/unstaged file
/// lists, the commit box with AI message generation, and the diff of the selected
/// file on the right.
struct ChangesView: View {

    @ObservedObject var viewModel: RepoViewModel
    @EnvironmentObject private var windowState: RepositoryWindowState

    @State private var selection: ChangeSelection?
    @State private var listFocusRequest = UUID()
    @StateObject private var selectionModel = ChangesSelectionModel()
    @State private var messageFocusRequest = UUID()
    @StateObject private var messageUndoController = CommitMessageUndoController()
    @FocusState private var stashMessageFocused: Bool
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

    private var selectedRow: Binding<ChangeRowID?> {
        Binding(get: {
            selection.map { ChangeRowID(path: $0.file.path, isStaged: $0.isStaged) }
        }, set: { row in
            guard let row else { selection = nil; return }
            let files = row.isStaged ? viewModel.status.staged : viewModel.status.unstaged
            selection = files.first(where: { $0.path == row.path }).map {
                ChangeSelection(file: $0, isStaged: row.isStaged)
            }
            listFocusRequest = UUID()
        })
    }

    private var commands: ChangesActions {
        ChangesActions(
            canStage: !viewModel.isBusy && selection?.isStaged == false,
            canUnstage: !viewModel.isBusy && selection?.isStaged == true,
            canStageAll: !viewModel.isBusy && conflicts.isEmpty && !viewModel.status.unstaged.isEmpty,
            canUnstageAll: !viewModel.isBusy && !viewModel.status.staged.isEmpty,
            canCommit: viewModel.canCommit,
            canStash: !viewModel.isBusy && !conflictUIActive && viewModel.status.isDirty,
            canGenerate: !viewModel.isBusy && !viewModel.isGeneratingMessage && !viewModel.status.staged.isEmpty,
            canDiscard: !viewModel.isBusy && selection != nil,
            stage: { if let selection { viewModel.stage([selection.file]) } },
            unstage: { if let selection { viewModel.unstage([selection.file]) } },
            stageAll: { viewModel.stageAll() },
            unstageAll: { viewModel.unstage(viewModel.status.staged) },
            commit: requestCommit,
            stash: { showingStashSheet = true },
            generate: generateMessage,
            discard: { fileToDiscard = selection?.file },
            editMessage: { messageFocusRequest = UUID() })
    }

    private func generateMessage() {
        messageUndoController.finishEditing()
        messageFocusRequest = UUID()
        let controller = messageUndoController
        viewModel.generateCommitMessage { replacement in
            controller.applyGenerated(replacement)
        }
    }

    private func requestCommit() {
        messageUndoController.finishEditing()
        guard viewModel.canCommit else { return }
        if amendRewritesPushedCommit {
            showingAmendPushedConfirmation = true
        } else {
            viewModel.commit()
        }
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
            selectionModel.select(selection, in: viewModel)
        }
        .onReceive(viewModel.$status) { status in
            // A refreshed path can have the same status letters but new content.
            // Read its patch on every applied snapshot, using the window's selection.
            let updated = selection?.updated(for: status)
                ?? status.unstaged.first.map { ChangeSelection(file: $0, isStaged: false) }
                ?? status.staged.first.map { ChangeSelection(file: $0, isStaged: true) }
            if selection != updated {
                selection = updated
            } else {
                selectionModel.select(updated, in: viewModel)
            }
        }
        .focusedSceneObject(messageUndoController.state.isFocused ? messageUndoController : nil)
        .focusedSceneValue(\.changesActions,
                           windowState.isPresentingSheet
                           || showingStashSheet || showingAmendPushedConfirmation || fileToDiscard != nil
                           ? nil : commands)
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
        VStack(spacing: 0) {
            HStack {
                Label(selection?.file.path ?? "Changes", systemImage: "doc.text")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let selection {
                    Text(selection.isStaged ? "Staged" : "Unstaged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)
            Divider()
            if selectionModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = selectionModel.errorMessage {
                EmptyPane(systemImage: "exclamationmark.triangle", title: "Couldn't load changes", subtitle: error)
            } else if selection == nil {
                EmptyPane(systemImage: viewModel.status.isDirty ? "doc.text.magnifyingglass" : "checkmark.circle",
                          title: viewModel.status.isDirty ? "Select a file" : "Working tree clean",
                          subtitle: conflicts.isEmpty ? "Changes to this repository will appear here."
                            : "Resolve the conflicted files, then continue the operation above.")
            } else {
                DiffView(diff: selectionModel.diff)
            }
        }
    }

    // MARK: - File lists

    private var fileList: some View {
        List(selection: selectedRow) {
            // No "Conflicted Files (0)" header over zero rows: once the last
            // conflict is resolved the section has nothing left to show, and
            // the operation banner already offers Continue.
            if conflictUIActive && !conflicts.isEmpty {
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
                            isSelected: selection?.file.path == file.path && selection?.isStaged == true,
                            focusRequest: listFocusRequest,
                            actionIcon: "minus.circle",
                            actionHelp: "Unstage") {
                        viewModel.unstage([file])
                    } onIgnore: {
                        // Staged files are tracked; ignore only applies to untracked.
                    } onDiscard: {
                        fileToDiscard = file
                    }
                    .tag(ChangeRowID(path: file.path, isStaged: true))
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
                            isSelected: selection?.file.path == file.path && selection?.isStaged == false,
                            focusRequest: listFocusRequest,
                            actionIcon: "plus.circle",
                            actionHelp: "Stage") {
                        viewModel.stage([file])
                    } onIgnore: {
                        viewModel.ignore(file)
                    } onDiscard: {
                        fileToDiscard = file
                    }
                    .tag(ChangeRowID(path: file.path, isStaged: false))
                }
            } header: {
                HStack {
                    Text("Changes (\(viewModel.status.unstaged.count))")
                    Spacer()
                    if !viewModel.status.unstaged.isEmpty {
                        // Never offered while anything is unmerged: `git add -A`
                        // would stage the conflict markers as the resolution,
                        // which also empties the conflict section and enables
                        // Commit — every signal saying "resolved" at the moment
                        // the conflict is buried. GitClient refuses too; this is
                        // so the user is told before clicking rather than after.
                        Button("Stage All") { viewModel.stageAll() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(viewModel.isBusy || !conflicts.isEmpty)
                            .help(conflicts.isEmpty
                                  ? "Stage every change"
                                  : Self.stageAllBlockedHelp(conflicts))
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
        .accessibilityLabel("Changed files")
        .disabled(viewModel.isBusy)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Commit box

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CommitMessageEditor(text: $viewModel.draftCommitMessage,
                                    focusRequest: messageFocusRequest,
                                    controller: messageUndoController,
                                    onEditingBegan: { viewModel.beginCommitMessageEditing() })
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
                    generateMessage()
                } label: {
                    if viewModel.isGeneratingMessage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .disabled(!viewModel.canGenerateCommitMessage)
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
                    // Nothing to amend before the first commit; without the
                    // guard the commit dies on git's raw "You have nothing to
                    // amend" error. A stale true (e.g. after checking out an
                    // orphan branch) is actually CLEARED by the view model on
                    // every applied snapshot — masking it here would let it
                    // silently pop back on after the orphan's first commit.
                    .disabled(viewModel.status.isUnborn)
                    .help("Amend the last commit instead of creating a new one")

                Button("Commit", action: requestCommit)
                .help("Commit staged changes (⌘↩)")
                .buttonStyle(.borderedProminent)
                // The predicate itself lives on the view model, so the GTK
                // commit box cannot describe this button differently — which
                // it did, and in both directions.
                .disabled(!viewModel.canCommit)
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
                .focused($stashMessageFocused)
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
                .disabled(viewModel.isBusy || conflictUIActive || !viewModel.status.isDirty)
            }
        }
        .padding(20)
        .defaultFocus($stashMessageFocused, true)
    }
}

private struct ChangeRowID: Hashable {
    let path: String
    let isStaged: Bool
}

// Internal rather than private: `stageAllBlockedHelp` is the copy a macOS user
// actually reads — the button is disabled whenever anything is unmerged, so
// `GitClient.stageAll`'s refusal almost never reaches this front end — and it
// was the one string in this change with no test behind it.
extension ChangesView {
    /// The disabled Stage All tooltip. Says what the refusal says, in the same
    /// words for the part that matters: `conflictStagingConsequence` is shared,
    /// so the two cannot make different claims about what staging a conflict
    /// does, and `namingFiles` is shared so they cannot name the files
    /// differently either.
    static func stageAllBlockedHelp(_ conflicts: [FileChange]) -> String {
        let names = GitClient.namingFiles(conflicts.map(\.path))
        // One binding for both agreements. The noun was already pluralised and
        // the pronoun was not, so a single conflict read "Resolve 1 conflicted
        // file first (a.txt) — staging them…" — and one file is the common case.
        let singular = conflicts.count == 1
        return "Resolve \(conflicts.count) conflicted file\(singular ? "" : "s") first (\(names)). "
            + "Staging \(singular ? "it" : "them") \(GitClient.conflictStagingConsequence)."
    }
}

/// One file row in the staged/unstaged lists: status badge, path, hover action
/// button (stage/unstage), and a context menu.
private struct FileRow: View {

    let file: FileChange
    let repoURL: URL
    let isSelected: Bool
    let focusRequest: UUID
    let actionIcon: String
    let actionHelp: String
    let onAction: () -> Void
    let onIgnore: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                FileStatusBadge(status: file.displayStatus)
                FilePathText(path: file.path, originalPath: file.originalPath)
                    .font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
            .nativeListRowFocus(isSelected: isSelected, focusRequest: focusRequest)
            Button(action: onAction) {
                Image(systemName: actionIcon)
            }
            .buttonStyle(.borderless)
            .help(actionHelp)
            .accessibilityLabel("\(actionHelp) \(file.path)")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
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
