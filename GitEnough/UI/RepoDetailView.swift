import SwiftUI

/// The right pane: everything about the selected repository. Hosts the toolbar
/// (branch picker, fetch/pull/push), the three tabs, a merge-in-progress banner,
/// an error banner, and a bottom status bar.
struct RepoDetailView: View {

    let repo: Repository
    @ObservedObject var viewModel: RepoViewModel
    @EnvironmentObject var appState: AppState
    @AppStorage("pullRebase") private var pullRebase = false

    @State private var newBranchName = ""
    @State private var checkoutNewBranch = true

    private var localBranches: [Branch] {
        viewModel.branches.filter { !$0.isRemote }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.mergeState.isMerging {
                mergeBanner
            }
            if let error = viewModel.errorMessage {
                ErrorBanner(message: error) {
                    viewModel.errorMessage = nil
                }
            }

            Group {
                switch appState.selectedTab {
                case .history:
                    HistoryView(viewModel: viewModel)
                case .changes:
                    ChangesView(viewModel: viewModel)
                case .branches:
                    BranchesView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            statusBar
        }
        .navigationTitle(repo.name)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                branchPicker
                    .padding(.leading, 6)
                Button {
                    newBranchName = ""
                    appState.showingNewBranch = true
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .help("New branch (⇧⌘B)")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $appState.selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isBusy || viewModel.mergeToolActivity != nil {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 8)
                }
                Button {
                    viewModel.fetch()
                } label: {
                    Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.isBusy || viewModel.remotes.isEmpty)
                .help("Fetch all remotes (⌥⌘F)")

                Button {
                    viewModel.pull(rebase: pullRebase)
                } label: {
                    Label("Pull", systemImage: "arrow.down.to.line")
                }
                .disabled(viewModel.isBusy || viewModel.remotes.isEmpty || viewModel.status.upstream == nil)
                .help(pullRebase ? "Pull with rebase (⇧⌘L)" : "Pull (⇧⌘L)")

                if viewModel.status.upstream == nil && !viewModel.remotes.isEmpty {
                    Button {
                        viewModel.publishBranch()
                    } label: {
                        Label("Publish", systemImage: "arrow.up.to.line")
                    }
                    .disabled(viewModel.isBusy)
                    .help("Push and set upstream to origin")
                } else {
                    Button {
                        viewModel.push()
                    } label: {
                        Label("Push", systemImage: "arrow.up.to.line")
                    }
                    .disabled(viewModel.isBusy || viewModel.remotes.isEmpty)
                    .help("Push (⇧⌘P)")
                }
            }
        }
        .sheet(isPresented: $appState.showingNewBranch) {
            newBranchSheet
        }
    }

    // MARK: - Toolbar pieces

    private var branchPicker: some View {
        Menu {
            ForEach(localBranches) { branch in
                Button {
                    viewModel.checkout(branch: branch)
                } label: {
                    if branch.isHead {
                        Label(branch.name, systemImage: "checkmark")
                    } else {
                        Text(branch.name)
                    }
                }
                .disabled(branch.isHead || viewModel.isBusy)
            }
            if localBranches.isEmpty {
                Text("No branches yet")
            }
        } label: {
            Label(viewModel.status.head ?? "Detached HEAD",
                  systemImage: "arrow.triangle.branch")
                .font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Current branch — click to switch")
    }

    // MARK: - Merge banner

    private var mergeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.mergeState.mergingRef ?? "Merge in progress")
                    .font(.callout)
                    .fontWeight(.semibold)
                let conflicts = viewModel.mergeState.conflictedFiles.count
                Text(conflicts == 0
                     ? "No conflicts — you can commit the merge."
                     : "\(conflicts) conflicted file\(conflicts == 1 ? "" : "s") to resolve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !viewModel.mergeState.conflictedFiles.isEmpty,
               appState.selectedTab != .changes {
                Button("Resolve Conflicts") {
                    appState.selectedTab = .changes
                }
            }
            Button("Abort Merge") {
                viewModel.mergeAbort()
            }
            .disabled(viewModel.isBusy)
            if viewModel.mergeState.conflictedFiles.isEmpty {
                Button("Commit Merge") {
                    viewModel.mergeContinue()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let activity = viewModel.mergeToolActivity ?? viewModel.activity {
                Label(activity, systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            if let remote = viewModel.remotes.first {
                Label(remote.displayHost, systemImage: "network")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if viewModel.status.ahead > 0 {
                Label("ahead \(viewModel.status.ahead)", systemImage: "arrow.up")
            }
            if viewModel.status.behind > 0 {
                Label("behind \(viewModel.status.behind)", systemImage: "arrow.down")
            }
            if !viewModel.stash.isEmpty {
                Label("\(viewModel.stash.count) stashed", systemImage: "tray")
            }
            Text(viewModel.status.isDirty
                 ? "\(viewModel.status.changeCount) uncommitted change\(viewModel.status.changeCount == 1 ? "" : "s")"
                 : "Working tree clean")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - New branch sheet

    private var newBranchSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Branch")
                .font(.title2)
                .fontWeight(.semibold)
            TextField("Branch name", text: $newBranchName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Text("Based on \(viewModel.status.head ?? "the current commit")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Check out after creating", isOn: $checkoutNewBranch)
            HStack {
                Spacer()
                Button("Cancel") {
                    appState.showingNewBranch = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create Branch") {
                    viewModel.createBranch(named: newBranchName.trimmingCharacters(in: .whitespaces),
                                           checkout: checkoutNewBranch)
                    appState.showingNewBranch = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

/// A dismissable error strip shown at the top of the detail pane.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }
}
