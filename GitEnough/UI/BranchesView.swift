import SwiftUI
import AppKit

/// The Branches tab: local branches, remote branches, and the stash — with
/// checkout / merge / delete / apply / drop actions.
struct BranchesView: View {

    @ObservedObject var viewModel: RepoViewModel
    @EnvironmentObject var windowState: RepositoryWindowState

    @State private var branchToDelete: Branch?
    @State private var remoteBranchToDelete: Branch?
    @State private var branchToMerge: Branch?
    @State private var stashToDrop: StashEntry?
    @State private var branchToRename: Branch?
    @State private var renameText = ""
    @State private var selection: BranchRowID?
    @State private var listFocusRequest = UUID()
    @FocusState private var renameFocused: Bool

    private var localBranches: [Branch] { viewModel.branches.filter { !$0.isRemote } }
    private var remoteBranches: [Branch] { viewModel.branches.filter { $0.isRemote } }

    private var selectedRow: Binding<BranchRowID?> {
        Binding(get: { selection }, set: { row in
            selection = row
            if row != nil { listFocusRequest = UUID() }
        })
    }

    private var selectedBranch: Branch? {
        guard case .branch(let ref) = selection else { return nil }
        return viewModel.branches.first { $0.refName == ref }
    }

    private var selectedStash: StashEntry? {
        guard case .stash(let index) = selection else { return nil }
        return viewModel.stash.first { $0.index == index }
    }

    private var canCheckout: Bool {
        guard let branch = selectedBranch, !branch.isHead,
              !viewModel.isBusy, !viewModel.mergeState.isInProgress else { return false }
        guard branch.isRemote else { return true }
        guard let local = branch.localNameForRemote else { return false }
        return !localBranches.contains { $0.name == local }
    }

    private var commands: BranchActions {
        BranchActions(
            canCheckout: canCheckout,
            canRename: !viewModel.isBusy && selectedBranch?.isRemote == false,
            canMerge: !viewModel.isBusy && !viewModel.mergeState.isInProgress
                && selectedBranch != nil && selectedBranch?.isHead == false,
            canDelete: !viewModel.isBusy && selectedBranch != nil && selectedBranch?.isHead == false,
            canUseStash: !viewModel.isBusy && !viewModel.mergeState.isInProgress && selectedStash != nil,
            checkout: { if let branch = selectedBranch { viewModel.checkout(branch: branch) } },
            rename: requestRename,
            merge: { branchToMerge = selectedBranch },
            delete: requestDelete,
            applyStash: { if let stash = selectedStash { viewModel.stashApply(stash, pop: false) } },
            popStash: { if let stash = selectedStash { viewModel.stashApply(stash, pop: true) } },
            dropStash: { stashToDrop = selectedStash })
    }

    private func requestRename() {
        guard let branch = selectedBranch, !branch.isRemote else { return }
        renameText = branch.name
        branchToRename = branch
    }

    private func requestDelete() {
        guard let branch = selectedBranch, !branch.isHead else { return }
        if branch.isRemote {
            remoteBranchToDelete = branch
        } else {
            branchToDelete = branch
        }
    }

    var body: some View {
        List(selection: selectedRow) {
            Section {
                ForEach(localBranches) { branch in
                    LocalBranchRow(branch: branch)
                        .tag(BranchRowID.branch(branch.refName))
                        .nativeListRowFocus(isSelected: selection == .branch(branch.refName), focusRequest: listFocusRequest)
                        .contextMenu {
                            if !branch.isHead {
                                Button("Check Out") { viewModel.checkout(branch: branch) }
                                    .disabled(viewModel.isBusy || viewModel.mergeState.isInProgress)
                                Button("Merge into Current Branch…") { branchToMerge = branch }
                                    .disabled(viewModel.isBusy || viewModel.mergeState.isInProgress)
                            }
                            Button("Rename…") {
                                renameText = branch.name
                                branchToRename = branch
                            }
                            Button("Copy Name") { NSPasteboard.general.copyString(branch.name) }
                            if !branch.isHead {
                                Divider()
                                Button("Delete…", role: .destructive) { branchToDelete = branch }
                            }
                        }
                        .onTapGesture(count: 2) {
                            guard !branch.isHead, !viewModel.isBusy,
                                  !viewModel.mergeState.isInProgress else { return }
                            viewModel.checkout(branch: branch)
                        }
                }
            } header: {
                HStack {
                    Text("Local Branches (\(localBranches.count))")
                    Spacer()
                    // Branch creation lives here too, not only in the toolbar
                    // and ⇧⌘B — the tab where branch operations actually happen
                    // should offer the most common one.
                    Button("New Branch…") { windowState.showingNewBranch = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            Section {
                if remoteBranches.isEmpty {
                    // Say why the section is empty instead of just being empty:
                    // the two causes have different remedies.
                    Text(viewModel.remotes.isEmpty
                         ? "This repository has no remotes — add one in the terminal (git remote add), then Fetch."
                         : "No remote branches yet — Fetch to load them, or Publish the current branch to create one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remoteBranches) { branch in
                        HStack(spacing: 6) {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(branch.name)
                                .font(.callout)
                            Spacer()
                            BranchRecencyText(date: branch.lastCommitDate)
                        }
                        .padding(.vertical, 2)
                        .tag(BranchRowID.branch(branch.refName))
                        .nativeListRowFocus(isSelected: selection == .branch(branch.refName), focusRequest: listFocusRequest)
                        .contextMenu {
                            if let local = branch.localNameForRemote,
                               !localBranches.contains(where: { $0.name == local }) {
                                Button("Check Out as \(local)") { viewModel.checkout(branch: branch) }
                                    .disabled(viewModel.isBusy || viewModel.mergeState.isInProgress)
                            }
                            Button("Merge into Current Branch…") { branchToMerge = branch }
                                .disabled(viewModel.isBusy || viewModel.mergeState.isInProgress)
                            Button("Copy Name") { NSPasteboard.general.copyString(branch.name) }
                            Divider()
                            Button("Delete Remote Branch…", role: .destructive) {
                                remoteBranchToDelete = branch
                            }
                        }
                    }
                }
            } header: {
                Text("Remote Branches (\(remoteBranches.count))")
            }

            Section {
                if viewModel.stash.isEmpty {
                    Text("No stashed changes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(viewModel.stash) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.message.isEmpty ? "Stash @{\(entry.index)}" : entry.message)
                                .font(.callout)
                                .lineLimit(1)
                            if !entry.branch.isEmpty {
                                Text("on \(entry.branch)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .tag(BranchRowID.stash(entry.index))
                    .nativeListRowFocus(isSelected: selection == .stash(entry.index), focusRequest: listFocusRequest)
                    .contextMenu {
                        Button("Apply") { viewModel.stashApply(entry, pop: false) }
                            .disabled(viewModel.isBusy || viewModel.mergeState.isInProgress)
                        Button("Pop") { viewModel.stashApply(entry, pop: true) }
                            .disabled(viewModel.isBusy || viewModel.mergeState.isInProgress)
                        Divider()
                        Button("Drop…", role: .destructive) { stashToDrop = entry }
                            .disabled(viewModel.isBusy || viewModel.mergeState.isInProgress)
                    }
                }
            } header: {
                Text("Stash (\(viewModel.stash.count))")
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("Branches and stashes")
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
        .disabled(viewModel.isBusy)
        .focusedSceneValue(\.branchActions,
                           windowState.isPresentingSheet
                           || branchToDelete != nil || remoteBranchToDelete != nil || branchToMerge != nil
                           || stashToDrop != nil || branchToRename != nil ? nil : commands)
        .onAppear { restoreSelection() }
        .onChange(of: viewModel.branches.map(\.refName)) { _, _ in restoreSelection() }
        .onChange(of: viewModel.stash) { _, _ in
            // Stash indices move after a pop/drop; don't retarget an old selection.
            if case .stash = selection { selection = nil }
            stashToDrop = nil
        }
        .confirmationDialog("Delete branch “\(branchToDelete?.name ?? "")”?",
                            isPresented: deleteConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let branch = branchToDelete {
                    viewModel.deleteBranch(branch, force: false)
                }
            }
            Button("Force Delete (unmerged commits)", role: .destructive) {
                if let branch = branchToDelete {
                    viewModel.deleteBranch(branch, force: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Merge “\(branchToMerge?.name ?? "")” into the current branch?",
                            isPresented: mergeConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Merge") {
                if let branch = branchToMerge {
                    viewModel.merge(branch: branch)
                }
            }
            Button("Merge (No Fast-Forward)") {
                if let branch = branchToMerge {
                    viewModel.merge(branch: branch, noFastForward: true)
                }
            }
            Button("Squash Merge (Stage Only)") {
                if let branch = branchToMerge {
                    viewModel.merge(branch: branch, squash: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“No fast-forward” always records a merge commit. “Squash” stages the combined changes without committing — you write the commit yourself in the Changes tab.")
        }
        .confirmationDialog("Delete remote branch “\(remoteBranchToDelete?.name ?? "")”?",
                            isPresented: deleteRemoteConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Delete on Remote", role: .destructive) {
                if let branch = remoteBranchToDelete {
                    viewModel.deleteRemoteBranch(branch)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the branch on the remote for everyone. Local branches tracking it keep their commits.")
        }
        .confirmationDialog("Drop this stash entry?",
                            isPresented: dropConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Drop", role: .destructive) {
                if let entry = stashToDrop {
                    viewModel.stashDrop(entry)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(stashToDrop?.message ?? "")” will be lost.")
        }
        .sheet(item: $branchToRename) { branch in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename “\(branch.name)”")
                    .font(.headline)
                TextField("New name", text: $renameText)
                    .focused($renameFocused)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { branchToRename = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Rename") {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, name != branch.name {
                            viewModel.renameBranch(branch, to: name)
                        }
                        branchToRename = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty
                        || renameText.trimmingCharacters(in: .whitespaces) == branch.name)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .defaultFocus($renameFocused, true)
        }
    }

    private func restoreSelection() {
        if let selectedBranch, viewModel.branches.contains(where: { $0.refName == selectedBranch.refName }) {
            return
        }
        if selectedStash != nil { return }
        selection = (viewModel.branches.first(where: \.isHead) ?? localBranches.first)
            .map { .branch($0.refName) }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            if let branch = selectedBranch {
                Label(branch.name, systemImage: branch.isRemote ? "network" : "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Check Out") { commands.checkout() }
                    .disabled(!commands.canCheckout)
                Button("Merge…") { commands.merge() }
                    .disabled(!commands.canMerge)
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Rename…", action: requestRename).disabled(!commands.canRename)
                    Button("Copy Name") { NSPasteboard.general.copyString(branch.name) }
                    Divider()
                    Button("Delete…", role: .destructive, action: requestDelete)
                        .disabled(!commands.canDelete)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else if let entry = selectedStash {
                Label(entry.ref, systemImage: "tray")
                Spacer()
                Button("Apply") { commands.applyStash() }
                    .disabled(!commands.canUseStash)
                Button("Pop") { commands.popStash() }
                    .disabled(!commands.canUseStash)
                Button("Drop…", role: .destructive) { commands.dropStash() }
                    .disabled(!commands.canUseStash)
            } else {
                Text("Select a branch or stash to see its actions.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(get: { branchToDelete != nil }, set: { if !$0 { branchToDelete = nil } })
    }

    private var deleteRemoteConfirmationPresented: Binding<Bool> {
        Binding(get: { remoteBranchToDelete != nil }, set: { if !$0 { remoteBranchToDelete = nil } })
    }

    private var mergeConfirmationPresented: Binding<Bool> {
        Binding(get: { branchToMerge != nil }, set: { if !$0 { branchToMerge = nil } })
    }

    private var dropConfirmationPresented: Binding<Bool> {
        Binding(get: { stashToDrop != nil }, set: { if !$0 { stashToDrop = nil } })
    }
}

private enum BranchRowID: Hashable {
    case branch(String)
    case stash(Int)
}

/// A local branch row: name (with checkmark for HEAD), upstream, ahead/behind.
private struct LocalBranchRow: View {

    let branch: Branch

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(branch.isHead ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(branch.name)
                .font(.callout)
                .fontWeight(branch.isHead ? .semibold : .regular)
            if let upstream = branch.upstream {
                Text("→ \(upstream)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if branch.upstreamGone {
                Label("upstream gone", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("“\(branch.upstream ?? "")” no longer exists on the remote — pull will fail until the branch is pushed again (re-creating it) or its upstream is unset.")
            }
            Spacer()
            if branch.ahead > 0 {
                Label("\(branch.ahead)", systemImage: "arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if branch.behind > 0 {
                Label("\(branch.behind)", systemImage: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            BranchRecencyText(date: branch.lastCommitDate)
        }
        .padding(.vertical, 2)
    }
}

/// When a branch was last committed to, right-aligned in branch rows: the
/// "which branches are alive?" signal next to ahead/behind. Hidden (not a
/// placeholder dash) when the caller's for-each-ref format omitted the date.
private struct BranchRecencyText: View {

    let date: Date?

    var body: some View {
        if let date {
            RelativeDateText(date: date)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(minWidth: 90, alignment: .trailing)
                .lineLimit(1)
        }
    }
}
