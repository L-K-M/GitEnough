import SwiftUI
import AppKit

/// The Changes tab: conflict resolution (while merging), staged/unstaged file
/// lists, the commit box with AI message generation, and the diff of the selected
/// file on the right.
struct ChangesView: View {

    @ObservedObject var viewModel: RepoViewModel

    @State private var selectedFile: FileChange?
    @State private var selectionIsStaged = false
    @State private var fileToDiscard: FileChange?
    @State private var showingStashSheet = false

    private var conflicts: [FileChange] { viewModel.status.conflicted }
    private var mergeInProgress: Bool { viewModel.mergeState.isMerging }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                fileList
                Divider()
                commitBox
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            DiffView(diff: viewModel.selectedFileDiff)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selectedFile) { _, file in
            viewModel.selectFile(file, staged: selectionIsStaged)
        }
        .onChange(of: viewModel.status) { _, status in
            // Drop the selection if the file vanished from the lists (committed,
            // discarded, resolved).
            if let file = selectedFile,
               !status.staged.contains(file) && !status.unstaged.contains(file) {
                selectedFile = nil
            }
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
            } else {
                Text("All uncommitted changes to “\(fileToDiscard?.lastPathComponent ?? "")” will be lost.")
            }
        }
        .sheet(isPresented: $showingStashSheet) {
            stashSheet
        }
    }

    private var discardConfirmationPresented: Binding<Bool> {
        Binding(get: { fileToDiscard != nil }, set: { if !$0 { fileToDiscard = nil } })
    }

    // MARK: - File lists

    private var fileList: some View {
        List {
            if mergeInProgress {
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
                            isSelected: selectedFile == file && selectionIsStaged,
                            actionIcon: "minus.circle",
                            actionHelp: "Unstage") {
                        selectedFile = file
                        selectionIsStaged = true
                    } onAction: {
                        viewModel.unstage([file])
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
                    }
                }
            }

            Section {
                ForEach(viewModel.status.unstaged) { file in
                    FileRow(file: file,
                            repoURL: viewModel.repo.url,
                            isSelected: selectedFile == file && !selectionIsStaged,
                            actionIcon: "plus.circle",
                            actionHelp: "Stage") {
                        selectedFile = file
                        selectionIsStaged = false
                    } onAction: {
                        viewModel.stage([file])
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
                        Button("Stash…") { showingStashSheet = true }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.inset)
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

                Spacer()

                Toggle("Amend", isOn: $viewModel.amendLastCommit)
                    .toggleStyle(.checkbox)
                    .help("Amend the last commit instead of creating a new one")

                Button("Commit") {
                    viewModel.commit()
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
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            FileStatusBadge(status: file.displayStatus)
            Text(file.path)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
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
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [repoURL.appendingPathComponent(file.path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
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
    @State private var tools: [MergeTool] = MergeTool.detectInstalled()

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
        }
        .padding(.vertical, 3)
    }
}

private extension FileChange {
    var lastPathComponent: String {
        (path as NSString).lastPathComponent
    }
}
