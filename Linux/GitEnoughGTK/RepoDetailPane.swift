import CGtk
import GitEnough

/// Everything to the right of the sidebar for one repository: the History,
/// Changes and Branches tabs, the repo-level actions, and the status line.
///
/// One instance per repository, cached by the window — switching back to a repo
/// should not throw away its scroll position or reload its history, which is
/// the same reason `AppState` caches view models.
final class RepoDetailPane {

    let widget: UnsafeMutablePointer<GtkWidget>
    let viewModel: RepoViewModel
    /// Handed to the header bar, which owns the tab switcher.
    let stack: UnsafeMutablePointer<GtkWidget>

    private let statusLabel = UI.label("", dim: true, ellipsize: true)
    private let errorBanner: UnsafeMutablePointer<GtkWidget>
    private let errorLabel = UI.label("", ellipsize: true)
    private let spinner: UnsafeMutablePointer<GtkWidget>
    private var observer: ModelObserver?

    init(viewModel: RepoViewModel) {
        self.viewModel = viewModel
        stack = require(gtk_stack_new(), "stack")
        spinner = require(gtk_spinner_new(), "spinner")

        let history = HistoryPane(viewModel: viewModel)
        let changes = ChangesPane(viewModel: viewModel)
        let branches = BranchesPane(viewModel: viewModel)
        let typedStack = opaque(stack)
        gtk_stack_add_titled(typedStack, changes.widget, "changes", "Changes")
        gtk_stack_add_titled(typedStack, history.widget, "history", "History")
        gtk_stack_add_titled(typedStack, branches.widget, "branches", "Branches")
        gtk_stack_set_visible_child_name(typedStack, "history")
        UI.expand(stack)
        self.panes = [history, changes, branches]

        // A dismissible error strip rather than a modal: a failed fetch must not
        // stop the user from carrying on in another tab.
        errorBanner = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, margin: 6)
        UI.expand(errorLabel, vertical: false)
        UI.addClass(errorBanner, "error")
        let dismiss = require(gtk_button_new_with_label("Dismiss"), "button")
        UI.append(errorBanner, errorLabel, dismiss)
        UI.setVisible(errorBanner, false)

        let statusBar = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        UI.setMargin(statusBar, 6)
        UI.expand(statusLabel, vertical: false)
        UI.append(statusBar, spinner, statusLabel)

        widget = UI.box(GTK_ORIENTATION_VERTICAL)
        UI.append(widget, errorBanner, stack, statusBar)

        connect(dismiss, "clicked") { [weak self] in self?.viewModel.errorMessage = nil }

        observer = ModelObserver(viewModel) { [weak self] in self?.refresh() }
        viewModel.start()
        refresh()
    }

    /// The panes are retained here; GTK owns the widgets, but the Swift objects
    /// holding their model observers need an owner too.
    private var panes: [AnyObject] = []

    private func refresh() {
        let status = viewModel.status
        var parts: [String] = []
        if let activity = viewModel.activity { parts.append(activity) }
        if let tool = viewModel.mergeToolActivity { parts.append(tool) }
        if parts.isEmpty {
            parts.append(status.head.map { "On \($0)" } ?? "Detached HEAD")
            if status.changeCount > 0 { parts.append("\(status.changeCount) changed") }
            if status.ahead > 0 { parts.append("\u{2191}\(status.ahead)") }
            if status.behind > 0 { parts.append("\u{2193}\(status.behind)") }
        }
        UI.setText(statusLabel, parts.joined(separator: "  \u{00B7}  "))

        if viewModel.isBusy {
            gtk_spinner_start(opaque(spinner))
        } else {
            gtk_spinner_stop(opaque(spinner))
        }
        UI.setVisible(spinner, viewModel.isBusy)

        if let message = viewModel.errorMessage {
            UI.setText(errorLabel, message)
            UI.setVisible(errorBanner, true)
        } else {
            UI.setVisible(errorBanner, false)
        }
    }
}
