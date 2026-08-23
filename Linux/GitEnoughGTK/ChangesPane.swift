import CGtk
import GitEnough

/// Staged and unstaged files, the diff of whichever is selected, and the commit
/// box. The Changes tab is where the everyday loop lives, so it is the one pane
/// that both reads and writes the repository.
final class ChangesPane {

    let widget: UnsafeMutablePointer<GtkWidget>

    private let viewModel: RepoViewModel
    private let unstagedList = UI.listBox()
    private let stagedList = UI.listBox()
    private let unstagedHeader = UI.label("Unstaged", bold: true)
    private let stagedHeader = UI.label("Staged", bold: true)
    private let messageView: UnsafeMutablePointer<GtkWidget>
    private let messageBuffer: UnsafeMutablePointer<GtkTextBuffer>
    private let commitButton: UnsafeMutablePointer<GtkWidget>
    private let amendToggle: UnsafeMutablePointer<GtkWidget>
    private let generateButton: UnsafeMutablePointer<GtkWidget>
    private let diffView = DiffView()
    private var observer: ModelObserver?

    private var unstaged: [FileChange] = []
    private var staged: [FileChange] = []
    private var isRebuilding = false
    /// True while the model is writing the commit box, so echoing that back as
    /// a user edit can't fight the caret.
    private var isSyncingMessage = false

    init(viewModel: RepoViewModel) {
        self.viewModel = viewModel

        messageView = require(gtk_text_view_new(), "text view")
        let view = cast(messageView, to: GtkTextView.self)
        gtk_text_view_set_wrap_mode(view, GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(view, 6)
        gtk_text_view_set_top_margin(view, 6)
        messageBuffer = require(gtk_text_view_get_buffer(view), "text buffer")

        // Actions are wired after every stored property exists: Swift won't let
        // a closure capture self until initialization is complete, and these
        // buttons all act on the view model.
        commitButton = require(gtk_button_new_with_label("Commit"), "button")
        UI.addClass(commitButton, "suggested-action")
        generateButton = require(gtk_button_new_with_label("\u{2728} Generate"), "button")
        gtk_widget_set_tooltip_text(generateButton,
                                    "Write a commit message from the staged diff")
        amendToggle = require(gtk_check_button_new_with_label("Amend last commit"),
                              "check button")
        let stageAll = require(gtk_button_new_with_label("Stage All"), "button")

        let lists = UI.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        UI.setMargin(unstagedHeader, 6)
        UI.setMargin(stagedHeader, 6)
        UI.setMargin(stageAll, 6)
        UI.append(lists, unstagedHeader, UI.scroller(unstagedList, horizontal: GTK_POLICY_NEVER),
                  stageAll, stagedHeader, UI.scroller(stagedList, horizontal: GTK_POLICY_NEVER))
        UI.expand(lists)

        let messageScroller = UI.scroller(messageView)
        gtk_widget_set_size_request(messageScroller, -1, 90)
        UI.expand(messageScroller, vertical: false)
        let buttons = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        UI.expand(amendToggle, vertical: false)
        UI.append(buttons, amendToggle, generateButton, commitButton)
        let commitBox = UI.box(GTK_ORIENTATION_VERTICAL, spacing: 6, margin: 6)
        UI.append(commitBox, messageScroller, buttons)

        let left = UI.box(GTK_ORIENTATION_VERTICAL)
        UI.append(left, lists, commitBox)

        widget = UI.paned(GTK_ORIENTATION_HORIZONTAL,
                          start: left, end: diffView.widget, position: 340)

        connect(commitButton, "clicked") { [weak self] in self?.commit() }
        connect(generateButton, "clicked") { [weak self] in
            self?.viewModel.generateCommitMessage()
        }
        connect(stageAll, "clicked") { [weak self] in self?.viewModel.stageAll() }
        connect(unstagedList, "row-activated") { [weak self] _ in self?.stageActivated() }
        connect(stagedList, "row-activated") { [weak self] _ in self?.unstageActivated() }
        connect(unstagedList, "row-selected") { [weak self] _ in self?.showDiff(staged: false) }
        connect(stagedList, "row-selected") { [weak self] _ in self?.showDiff(staged: true) }
        connect(messageBuffer, "changed") { [weak self] in self?.messageEdited() }
        connect(amendToggle, "toggled") { [weak self] in
            guard let self else { return }
            viewModel.amendLastCommit =
                gtk_check_button_get_active(cast(amendToggle, to: GtkCheckButton.self)) != 0
        }

        observer = ModelObserver(viewModel) { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: - Refresh

    private func refresh() {
        let status = viewModel.status
        if unstaged.map(rowKey) != status.unstaged.map(rowKey) {
            unstaged = status.unstaged
            isRebuilding = true
            UI.replaceRows(unstagedList, with: unstaged.map { row($0, staged: false) })
            isRebuilding = false
        }
        if staged.map(rowKey) != status.staged.map(rowKey) {
            staged = status.staged
            isRebuilding = true
            UI.replaceRows(stagedList, with: staged.map { row($0, staged: true) })
            isRebuilding = false
        }
        UI.setText(unstagedHeader, "Unstaged (\(unstaged.count))")
        UI.setText(stagedHeader, "Staged (\(staged.count))")

        if !isSyncingMessage, currentMessage() != viewModel.draftCommitMessage {
            isSyncingMessage = true
            gtk_text_buffer_set_text(messageBuffer, viewModel.draftCommitMessage, -1)
            isSyncingMessage = false
        }
        gtk_widget_set_sensitive(commitButton,
                                 viewModel.status.staged.isEmpty ? 0 : 1)
        gtk_widget_set_sensitive(generateButton, viewModel.isGeneratingMessage ? 0 : 1)
        diffView.show(viewModel.selectedFileDiff)
    }

    private func rowKey(_ change: FileChange) -> String {
        change.path + change.displayStatus.rawValue
    }

    private func row(_ change: FileChange, staged: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let box = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, margin: 4)
        UI.append(box, UI.label(change.displayStatus.rawValue, dim: true, monospace: true))
        let path = UI.label(change.path, ellipsize: true)
        UI.expand(path, vertical: false)
        UI.append(box, path)
        // Double-click stages or unstages; the button says which way it goes.
        let action = UI.button(staged ? "Unstage" : "Stage") { [weak self] in
            guard let self else { return }
            staged ? viewModel.unstage([change]) : viewModel.stage([change])
        }
        gtk_widget_set_valign(action, GTK_ALIGN_CENTER)
        UI.append(box, action)
        return box
    }

    // MARK: - Actions

    private func stageActivated() {
        guard let change = selection(in: unstagedList, from: unstaged) else { return }
        viewModel.stage([change])
    }

    private func unstageActivated() {
        guard let change = selection(in: stagedList, from: staged) else { return }
        viewModel.unstage([change])
    }

    private func showDiff(staged: Bool) {
        guard !isRebuilding else { return }
        let list = staged ? stagedList : unstagedList
        guard let change = selection(in: list, from: staged ? self.staged : unstaged) else {
            return
        }
        viewModel.selectFile(change, staged: staged)
    }

    private func selection(in list: UnsafeMutablePointer<GtkWidget>,
                           from changes: [FileChange]) -> FileChange? {
        guard let row = gtk_list_box_get_selected_row(opaque(list)) else { return nil }
        let index = Int(gtk_list_box_row_get_index(row))
        return changes.indices.contains(index) ? changes[index] : nil
    }

    private func commit() {
        viewModel.draftCommitMessage = currentMessage()
        viewModel.commit()
    }

    // MARK: - Commit message

    private func messageEdited() {
        guard !isSyncingMessage else { return }
        viewModel.draftCommitMessage = currentMessage()
    }

    private func currentMessage() -> String {
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(messageBuffer, &start, &end)
        guard let text = gtk_text_buffer_get_text(messageBuffer, &start, &end, 0) else {
            return ""
        }
        defer { g_free(text) }
        return String(cString: text)
    }
}
