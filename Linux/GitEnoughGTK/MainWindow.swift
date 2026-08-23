import CGtk
import Foundation
import GitEnough

/// The two-pane window: repositories on the left, the selected repository on
/// the right, repo-level actions in the header bar.
final class MainWindow {

    private let window: UnsafeMutablePointer<GtkWindow>
    private let appState = AppState()
    /// Detail panes live in a stack rather than being swapped in and out of a
    /// box. Removing a widget from a GTK container drops the container's
    /// reference — which is the only one — so the whole pane would be finalized
    /// while its Swift object and model observers were still alive, and the next
    /// refresh would poke at freed list boxes. A stack keeps every child alive
    /// and just changes which one is visible.
    private let detailStack = require(gtk_stack_new(), "stack")
    private let switcher: UnsafeMutablePointer<GtkWidget>
    private let titleLabel = UI.label("GitEnough", bold: true, xalign: 0.5)
    private let subtitleLabel = UI.label("", dim: true, xalign: 0.5)
    private let actionBox = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)

    private var sidebar: SidebarPane?
    private var observer: ModelObserver?
    /// One detail pane per repository, kept alive so switching back doesn't
    /// reload the history — the same reason AppState caches view models.
    private var detailPanes: [String: RepoDetailPane] = [:]
    private var shownPath: String?

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = cast(require(gtk_application_window_new(application), "window"))
        gtk_window_set_title(window, "GitEnough")
        gtk_window_set_default_size(window, 1180, 760)

        switcher = require(gtk_stack_switcher_new(), "stack switcher")

        let header = require(gtk_header_bar_new(), "header bar")
        let title = UI.box(GTK_ORIENTATION_VERTICAL)
        UI.append(title, titleLabel, subtitleLabel)
        gtk_header_bar_set_title_widget(opaque(header), title)
        gtk_header_bar_pack_start(opaque(header), switcher)
        gtk_header_bar_pack_end(opaque(header), actionBox)
        gtk_window_set_titlebar(window, header)

        UI.expand(detailStack)
        gtk_stack_add_named(opaque(detailStack),
                            UI.placeholder("Add a repository to get started.\n"
                                           + "Use + in the sidebar, or pass a folder "
                                           + "on the command line."),
                            "placeholder")

        let sidebar = SidebarPane(appState: appState) { [weak self] repo in
            self?.select(repo)
        }
        self.sidebar = sidebar
        gtk_widget_set_size_request(sidebar.widget, 260, -1)

        gtk_window_set_child(window, UI.paned(GTK_ORIENTATION_HORIZONTAL,
                                              start: sidebar.widget,
                                              end: detailStack,
                                              position: 280))
        buildActions()

        observer = ModelObserver(appState) { [weak self] in self?.syncSelection() }
        syncSelection()
    }

    func present() {
        gtk_window_present(window)
    }

    /// Adds each path to the sidebar and selects the first one that took.
    /// A path that isn't a repository is reported by `addRepository` the same
    /// way the Add button reports it.
    func open(paths: [String]) {
        for path in paths {
            appState.addRepository(at: URL(fileURLWithPath: path)) { [weak self] repo in
                guard let self, let repo, shownPath == nil else { return }
                select(repo)
            }
        }
    }

    // MARK: - Selection

    private func select(_ repo: Repository) {
        appState.select(repo)
        syncSelection()
    }

    /// Shows the detail pane for whatever `AppState` currently has selected —
    /// which may be a repository restored from the last session, not just one
    /// the user clicked.
    private func syncSelection() {
        guard let repo = appState.selectedRepository else {
            showPlaceholder()
            return
        }
        guard repo.path != shownPath else {
            updateTitle(for: repo)
            return
        }
        let pane: RepoDetailPane
        if let existing = detailPanes[repo.path] {
            pane = existing
        } else {
            pane = RepoDetailPane(viewModel: appState.viewModel(for: repo))
            detailPanes[repo.path] = pane
            gtk_stack_add_named(opaque(detailStack), pane.widget, repo.path)
        }
        gtk_stack_set_visible_child_name(opaque(detailStack), repo.path)
        gtk_stack_switcher_set_stack(opaque(switcher), opaque(pane.stack))
        UI.setVisible(switcher, true)
        UI.setVisible(actionBox, true)
        shownPath = repo.path
        updateTitle(for: repo)
    }

    private func showPlaceholder() {
        gtk_stack_set_visible_child_name(opaque(detailStack), "placeholder")
        UI.setVisible(switcher, false)
        UI.setVisible(actionBox, false)
        UI.setText(titleLabel, "GitEnough")
        UI.setText(subtitleLabel, "")
        shownPath = nil
    }

    private func updateTitle(for repo: Repository) {
        UI.setText(titleLabel, repo.name)
        let status = detailPanes[repo.path]?.viewModel.status
        UI.setText(subtitleLabel, status?.head.map { "on \($0)" } ?? repo.path)
    }

    // MARK: - Actions

    private func buildActions() {
        let actions: [(String, String, (RepoViewModel) -> Void)] = [
            ("Fetch", "Fetch from the remote", { $0.fetch() }),
            ("Pull", "Pull and merge", { $0.pull(rebase: false) }),
            // One entry point for both: it re-resolves the capability at click
            // time, so a branch with no upstream publishes instead of failing,
            // and detached/unborn HEAD reports why rather than doing nothing.
            ("Push", "Push the current branch, or publish it if it has no upstream",
             { $0.pushOrPublish() }),
        ]
        for (title, tooltip, action) in actions {
            let button = UI.button(title, tooltip: tooltip) { [weak self] in
                guard let self, let path = shownPath,
                      let pane = detailPanes[path] else { return }
                action(pane.viewModel)
            }
            UI.append(actionBox, button)
        }
        let pullRequest = UI.button("Pull Request",
                                    tooltip: "Open this branch's pull request in the browser") {
            [weak self] in
            guard let self, let path = shownPath, let pane = detailPanes[path] else { return }
            pane.viewModel.openPullRequest()
        }
        UI.append(actionBox, pullRequest)
    }
}
