import SwiftUI
import AppKit

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
    /// Confirms aborting an in-progress merge/rebase/cherry-pick/revert —
    /// the single most destructive unguarded action in the banner.
    @State private var confirmingAbort = false
    @State private var showingForcePushConfirmation = false
    /// The exact command the open confirmation dialog is showing. Compared
    /// against a freshly resolved one when the user confirms, so a refresh
    /// between opening and confirming cannot swap the refspec underneath them.
    @State private var pendingForcePush: GitClient.PushCommand?
    /// The branch name as it read when the force-push dialog opened. Frozen
    /// alongside `pendingForcePush` because the dialog's *title* closure is the
    /// one place `presenting:` cannot reach.
    @State private var pendingForcePushBranch: String?

    /// Lowercase noun of the in-progress operation for the abort dialog's
    /// sentence text ("… before the merge started").
    private var inProgressNoun: String {
        (viewModel.mergeState.operation?.noun ?? "Operation").lowercased()
    }

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
                .disabled(!viewModel.canPull)
                .help(viewModel.mergeState.isInProgress
                      ? "Finish or abort the in-progress operation first"
                      : viewModel.remotes.isEmpty
                      ? "No remotes configured"
                      : viewModel.status.upstream == nil
                      ? "No upstream branch — publish first"
                      : pullRebase ? "Pull with rebase (⇧⌘L)" : "Pull (⇧⌘L)")

                // One control for Push and Publish: `pushCapability` decides
                // which it is, so label, tooltip and action can't drift apart.
                // The ahead count rides on the plain-push label — that number is
                // most of the reason to glance at this button. Split button:
                // clicking pushes (or publishes); the menu half holds the rarely
                // needed, confirmed force push, offered only for a plain push —
                // a branch with no upstream yet has nothing to overwrite.
                Menu {
                    Button("Force Push (with Lease)…") {
                        // Captured here, when the dialog opens, and not
                        // re-derived in the confirm action: re-deriving would
                        // read whatever the capability says at *tap* time,
                        // which is exactly the value the comparison exists to
                        // catch changing.
                        //
                        // Switched rather than guarded, and never a bare
                        // `return`: `.disabled` is evaluated when the menu
                        // renders, so a refresh landing between that and the
                        // tap can still find no command — and a destructive
                        // button that does nothing at all hides the state
                        // change behind it. Say what happened instead.
                        switch viewModel.forcePushResolution {
                        case .command(let command):
                            pendingForcePush = command
                            // Snapshotted with the command, for the same reason
                            // the command is: the title closure does not receive
                            // the `presenting:` value, so left interpolating
                            // `viewModel.status.head` it would re-render live
                            // while the refspec below stayed frozen — and the
                            // user could confirm a title naming one branch over
                            // a command pushing another. That is the drift this
                            // whole flow exists to prevent, one line up from
                            // where it was fixed.
                            pendingForcePushBranch = viewModel.status.head
                            showingForcePushConfirmation = true
                        case .refused(let reason):
                            viewModel.errorMessage = reason
                        }
                    }
                    // Gated on the command, not on the capability, so the
                    // dialog can never open without the command it will show.
                    // Two expressions of one predicate is how they drift.
                    .disabled(forcePushCommand == nil)
                } label: {
                    Label(viewModel.pushCapability.tracksAnUpstream && viewModel.status.ahead > 0
                          ? "Push (\(viewModel.status.ahead))"
                          : viewModel.pushCapability.label,
                          systemImage: "arrow.up.to.line")
                } primaryAction: {
                    viewModel.pushOrPublish()
                }
                .disabled(!viewModel.canPushOrPublish)
                // An in-progress merge/rebase isn't part of the capability's
                // repository shape, so it needs to explain itself here.
                .help(viewModel.mergeState.isInProgress
                      ? "Finish or abort the in-progress operation first"
                      : viewModel.pushCapability.help)

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
        .confirmationDialog("Abort this \(inProgressNoun)?",
                            isPresented: $confirmingAbort,
                            titleVisibility: .visible) {
            Button("Abort", role: .destructive) {
                viewModel.abortOperation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Aborting returns the repository to the state before the \(inProgressNoun) started. Any conflict resolutions you haven't committed will be lost.")
        }

        // `presenting:` rather than reading `pendingForcePush` inside the
        // closures. Both are captured from the same snapshot, so the two
        // spellings agree today — but only because SwiftUI happens to run a
        // dialog button's action before the dismissal propagates `isPresented =
        // false` to the `onChange` below. Nothing in the API contract promises
        // that order, and if it ever flipped, confirm would read a nil snapshot
        // and do nothing at all: a silent no-op on the one button whose whole
        // claim is that the command shown and the command run cannot drift
        // apart. Handing the value to the closures removes the question.
        .confirmationDialog("Force push “\(pendingForcePushBranch ?? "")”?",
                            isPresented: $showingForcePushConfirmation,
                            titleVisibility: .visible,
                            presenting: pendingForcePush) { command in
            Button("Force Push (with Lease)", role: .destructive) {
                viewModel.forcePush(confirming: command)
                pendingForcePush = nil
                pendingForcePushBranch = nil
            }
            Button("Cancel", role: .cancel) {
                pendingForcePush = nil
                pendingForcePushBranch = nil
            }
        } message: { command in
            Text(Self.forcePushWarning(for: command))
            // Monospaced, because the refspec is the one part of this dialog
            // the user has to actually read, and `local:remote` with its
            // colon is exactly what proportional type renders worst.
            //
            // Interpolated rather than concatenated: `Text(someString)` picks
            // the verbatim initializer, so building this with `+` would take
            // the sentence out of localization while leaving the dialog
            // around it in. The command itself stays verbatim, as it should.
            Text("Will run in this repository:\ngit \(GitActivityLog.displayCommand(for: command.arguments))")
                .font(.system(.footnote, design: .monospaced))
        }
        // Hygiene now rather than correctness: with `presenting:` the dialog
        // can no longer show a stale command, but dismissing by clicking
        // outside runs neither button action, and leaving a destructive
        // refspec in view state is exactly the staleness this flow exists to
        // eliminate.
        .onChange(of: showingForcePushConfirmation) { _, showing in
            if !showing {
                pendingForcePush = nil
                pendingForcePushBranch = nil
            }
        }
    }

    /// Two literals, picked by what the command about to run actually carries.
    ///
    /// The strong sentence is only true because `pushArguments` sends
    /// `--force-if-includes` alongside `--force-with-lease`. Measured against
    /// git 2.43 on one fixture — teammate pushes, our background auto-fetch
    /// pulls their commit into the tracking ref, we force push: the bare lease
    /// is *accepted* and their commit is destroyed, while the same push with
    /// `--force-if-includes` is rejected and it survives.
    ///
    /// But that flag is gated on git 2.30, and dropped when `git --version`
    /// cannot be read or parsed. On such a git the lease compares only against
    /// the tracking ref that the app's own fetch just moved, so the strong
    /// sentence would promise protection precisely where there is none — the
    /// most destructive dialog in the app, confidently wrong. So it says the
    /// weaker, true thing instead.
    ///
    /// And the weak branch says "can't confirm", not "your git is old", because
    /// those are different facts and only one of them is knowable here. Telling
    /// someone on a modern git whose banner merely failed to parse that their
    /// git is out of date hands them a remedy that cannot work, which is the
    /// same failure this whole property exists to avoid — one dialog down.
    ///
    /// Typed as `LocalizedStringKey`, and each a single literal rather than a
    /// concatenation, so `Text` takes the localizing initializer. A `String`
    /// constant here would silently make the app's most safety-critical
    /// sentence the only untranslated one on screen.
    private static func forcePushWarning(for command: GitClient.PushCommand) -> LocalizedStringKey {
        // Keyed off the argv actually about to run, not off the capability the
        // builder consulted. Those are two readings of one fact, and the
        // monospaced line directly below this sentence shows the user the
        // flags — so if they ever disagreed, the dialog would promise a
        // protection its own command visibly does not carry.
        command.refusesUnfetchedRemoteWork
            ? "This rewrites the remote branch to match your local history. It refuses if the remote has commits you haven't merged in — including ones GitEnough fetched for you in the background — so a teammate's new work can't be lost silently. Anyone who already pulled the old history will still have to recover."
            : "This rewrites the remote branch to match your local history. GitEnough can't confirm your git is 2.30 or newer, so it can only check that the remote still points where your last fetch left it: a teammate's commits that GitEnough has already fetched in the background will be overwritten without warning. Update git to 2.30 or newer — and make sure GitEnough can read its version — to be protected from that. Anyone who already pulled the old history will still have to recover."
    }

    /// The command a confirmed force push would run, as of right now.
    ///
    /// Showing it is not decoration: this is the one action in the app that can
    /// destroy someone else's work, and the whole premise of GitEnough is that
    /// it does what the command line would — so it should be willing to say
    /// which command. It also makes the refspec visible, which is exactly what a
    /// bare `git push` left to `push.default` did not have.
    ///
    /// `pendingForcePush` is the snapshot of this taken when the dialog opened;
    /// this property is what gates the menu item.
    ///
    /// Delegated rather than derived: this used to repeat the
    /// capability-to-command switch that `forcePush(confirming:)` also runs, so
    /// the enablement logic and the execution logic could diverge as
    /// `PushCapability` grew — the view's `guard case .push` silently yielding
    /// nil for a new case while the view model handled it. On the one action
    /// where they must agree, there is now one switch.
    private var forcePushCommand: GitClient.PushCommand? {
        viewModel.forcePushCommand
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
                confirmingAbort = true
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
            if let remote = viewModel.preferredRemote {
                Label(remote.displayHost, systemImage: "network")
                    .help("The remote fetch, pull, push and pull requests use: \(remote.name) — \(remote.url)")
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

/// A dismissable error strip shown at the top of the detail pane. Long git
/// output (hook failures regularly exceed the collapsed four lines, with the
/// useful part last) can be expanded into a scrollable monospaced view; the
/// full text is always one click away on the clipboard.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    @State private var isExpanded = false

    /// Expansion only pays off when the collapsed view actually truncates.
    private var isLong: Bool {
        message.count > 240 || message.filter { $0 == "\n" }.count >= 4
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if isExpanded {
                ScrollView {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } else {
                Text(message)
                    .font(.callout)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Spacer()
            if isLong {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse the output" : "Show the full output")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy the full error text")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }
}
