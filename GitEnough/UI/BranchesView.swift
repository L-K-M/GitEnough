import SwiftUI
import AppKit

/// The Branches tab: local branches, remote branches, and the stash — with
/// checkout / merge / delete / apply / drop actions.
struct BranchesView: View {

    @ObservedObject var viewModel: RepoViewModel

    @State private var branchToDelete: Branch?
    @State private var branchToMerge: Branch?
    @State private var stashToDrop: StashEntry?
    @State private var branchToRename: Branch?
    @State private var renameText = ""

    private var localBranches: [Branch] { viewModel.branches.filter { !$0.isRemote } }
    private var remoteBranches: [Branch] { viewModel.branches.filter { $0.isRemote } }

    var body: some View {
        List {
            Section {
                ForEach(localBranches) { branch in
                    LocalBranchRow(branch: branch)
                        .contextMenu {
                            if !branch.isHead {
                                Button("Check Out") { viewModel.checkout(branch: branch) }
                                Button("Merge into Current Branch…") { branchToMerge = branch }
                            }
                            Button("Rename…") {
                                renameText = branch.name
                                branchToRename = branch
                            }
                            Button("Copy Name") { copyToPasteboard(branch.name) }
                            if !branch.isHead {
                                Divider()
                                Button("Delete…", role: .destructive) { branchToDelete = branch }
                            }
                        }
                        .onTapGesture(count: 2) {
                            if !branch.isHead { viewModel.checkout(branch: branch) }
                        }
                }
            } header: {
                Text("Local Branches (\(localBranches.count))")
            }

            Section {
                ForEach(remoteBranches) { branch in
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(branch.name)
                            .font(.callout)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        if let local = branch.localNameForRemote,
                           !localBranches.contains(where: { $0.name == local }) {
                            Button("Check Out as \(local)") { viewModel.checkout(branch: branch) }
                        }
                        Button("Merge into Current Branch…") { branchToMerge = branch }
                        Button("Copy Name") { copyToPasteboard(branch.name) }
                    }
                }
            } header: {
                Text("Remote Branches (\(remoteBranches.count))")
            }

            Section {
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
                    .contextMenu {
                        Button("Apply") { viewModel.stashApply(entry, pop: false) }
                        Button("Pop") { viewModel.stashApply(entry, pop: true) }
                        Divider()
                        Button("Drop…", role: .destructive) { stashToDrop = entry }
                    }
                }
            } header: {
                Text("Stash (\(viewModel.stash.count))")
            }
        }
        .listStyle(.inset)
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
            Button("Cancel", role: .cancel) {}
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
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(get: { branchToDelete != nil }, set: { if !$0 { branchToDelete = nil } })
    }

    private var mergeConfirmationPresented: Binding<Bool> {
        Binding(get: { branchToMerge != nil }, set: { if !$0 { branchToMerge = nil } })
    }

    private var dropConfirmationPresented: Binding<Bool> {
        Binding(get: { stashToDrop != nil }, set: { if !$0 { stashToDrop = nil } })
    }
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
        }
        .padding(.vertical, 2)
    }
}
