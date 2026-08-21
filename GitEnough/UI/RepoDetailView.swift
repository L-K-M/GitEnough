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
    @State private var showingActivityLog = false

    private var localBranches: [Branch] {
        viewModel.branches.filter { !$0.isRemote }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.mergeState.isInProgress {
                operationBanner
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
            // Re-key the tab content per repository: @State (history selection +
            // filter, changes selection, …) must not survive a repo switch. It
            // used to: the old selected commit hash lingered into the new repo's
            // HistoryView, and when the hash existed in both repos the detail
            // pane spun forever — selectCommit was never re-run for the new view
            // model. A remount also resets scroll to the top (HEAD), which is
            // where you want to land on a fresh repo anyway.
            .id(repo.path)
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
                if viewModel.isBusy || viewModel.mergeToolActivity != nil
                    || viewModel.isResolvingPullRequest {
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
                    Label(viewModel.status.behind > 0
                          ? "Pull (\(viewModel.status.behind))" : "Pull",
                          systemImage: "arrow.down.to.line")
                }
                .disabled(viewModel.isBusy || viewModel.remotes.isEmpty
                          || viewModel.status.upstream == nil
                          || viewModel.mergeState.isInProgress)
                .help(viewModel.mergeState.isInProgress
                      ? "Finish or abort the in-progress operation first"
                      : pullRebase ? "Pull with rebase (⇧⌘L)" : "Pull (⇧⌘L)")

                if viewModel.status.upstream == nil && !viewModel.remotes.isEmpty {
                    Button {
                        viewModel.publishBranch()
                    } label: {
                        Label("Publish", systemImage: "arrow.up.to.line")
                    }
                    .disabled(viewModel.isBusy || viewModel.remotes.isEmpty
                              || viewModel.mergeState.isInProgress)
                    .help(viewModel.mergeState.isInProgress
                          ? "Finish or abort the in-progress operation first"
                          : "Push and set upstream to \(viewModel.publishRemoteName)")
                } else {
                    Button {
                        viewModel.push()
                    } label: {
                        Label(viewModel.status.ahead > 0
                              ? "Push (\(viewModel.status.ahead))" : "Push",
                              systemImage: "arrow.up.to.line")
                    }
                    .disabled(viewModel.isBusy || viewModel.remotes.isEmpty
                              || viewModel.mergeState.isInProgress)
                    .help(viewModel.mergeState.isInProgress
                          ? "Finish or abort the in-progress operation first" : "Push (⇧⌘P)")
                }

                Button {
                    viewModel.openPullRequest()
                } label: {
                    Label(viewModel.isResolvingPullRequest ? "Opening…" : "Pull Request",
                          systemImage: "arrow.triangle.pull")
                }
                .disabled(viewModel.isBusy || viewModel.isResolvingPullRequest
                          || viewModel.remotes.isEmpty || viewModel.status.head == nil)
                .help("Open the current branch's pull request on the forge website (GitHub, Forgejo/Gitea, GitLab), or the page to create one (⌥⌘P)")
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

    // MARK: - Operation banner (merge / rebase / cherry-pick / revert)

    private var operationBanner: some View {
        let state = viewModel.mergeState
        let noun = state.operation?.noun ?? "Operation"
        let title = state.operationLabel ?? "\(noun) in progress"
        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                let conflicts = state.conflictedFiles.count
                Text(conflicts == 0
                     ? "No conflicts — you can continue."
                     : "\(conflicts) conflicted file\(conflicts == 1 ? "" : "s") to resolve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !state.conflictedFiles.isEmpty,
               appState.selectedTab != .changes {
                Button("Resolve Conflicts") {
                    appState.selectedTab = .changes
                }
            }
            Button("Abort \(noun)") {
                viewModel.abortOperation()
            }
            .disabled(viewModel.isBusy)
            if state.conflictedFiles.isEmpty {
                Button(state.operation == .merge ? "Commit Merge" : "Continue \(noun)") {
                    viewModel.continueOperation()
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
            // What is actually running right now — the difference between "slow
            // fetch" and "pre-commit hook executing the test suite for 3 min".
            // Rarely more than one (merge tool overlapping a queue op).
            ForEach(viewModel.runningActivityEntries) { running in
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                    Text("git \(running.command)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .leading)
                    Text(running.startedAt, style: .timer)
                        .monospacedDigit()
                }
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
            if !viewModel.activityEntries.isEmpty {
                Button {
                    showingActivityLog.toggle()
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.borderless)
                .help("Recent git activity")
                .popover(isPresented: $showingActivityLog, arrowEdge: .bottom) {
                    ActivityLogView(entries: viewModel.activityEntries)
                }
            }
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
