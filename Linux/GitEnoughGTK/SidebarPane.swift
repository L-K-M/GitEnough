import CGtk
import Foundation
import GitEnough

/// The repository list: every repo GitEnough knows, with its branch and a live
/// dirty / ahead-behind summary, plus the controls to add and remove one.
final class SidebarPane {

    let widget: UnsafeMutablePointer<GtkWidget>

    private let appState: AppState
    private let listBox: UnsafeMutablePointer<GtkWidget>
    private let filterEntry: UnsafeMutablePointer<GtkWidget>
    private var observers: [ModelObserver] = []
    /// The repositories currently on screen, in row order — a list box row knows
    /// only its index, so this is what turns a selection back into a repo.
    private var rows: [Repository] = []
    /// Set while rebuilding, so programmatic selection changes don't read as the
    /// user picking a different repository.
    private var isRebuilding = false
    private var onSelect: (Repository) -> Void = { _ in }

    init(appState: AppState, onSelect: @escaping (Repository) -> Void) {
        self.appState = appState
        self.onSelect = onSelect

        widget = UI.box(GTK_ORIENTATION_VERTICAL)
        filterEntry = require(gtk_search_entry_new(), "search entry")
        gtk_widget_set_margin_start(filterEntry, 6)
        gtk_widget_set_margin_end(filterEntry, 6)
        gtk_widget_set_margin_top(filterEntry, 6)
        gtk_widget_set_margin_bottom(filterEntry, 6)
        Properties.set(filterEntry, "placeholder-text", "Filter repositories")

        listBox = UI.listBox()
        UI.addClass(listBox, "navigation-sidebar")

        let toolbar = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, margin: 6)
        let add = UI.iconButton("list-add-symbolic", tooltip: "Add a repository…") {
            [weak self] in self?.presentFolderChooser()
        }
        let remove = UI.iconButton("list-remove-symbolic", tooltip: "Remove the selected repository") {
            [weak self] in self?.removeSelected()
        }
        UI.append(toolbar, add, remove)

        UI.append(widget, filterEntry, UI.scroller(listBox, horizontal: GTK_POLICY_NEVER), toolbar)

        connect(filterEntry, "search-changed") { [weak self] in self?.rebuild() }
        connect(listBox, "row-selected") { [weak self] _ in self?.selectionChanged() }

        observers.append(ModelObserver(appState.store) { [weak self] in self?.rebuild() })
        rebuild()
    }

    // MARK: - Rows

    private func rebuild() {
        let filter = currentFilter()
        rows = appState.store.repositories.filter { repo in
            filter.isEmpty || repo.name.lowercased().contains(filter)
        }
        isRebuilding = true
        UI.replaceRows(listBox, with: rows.map(makeRow))
        // Restore the selection so a summary refresh doesn't drop the user out
        // of the repository they are looking at.
        if let selected = appState.selectedRepoPath,
           let index = rows.firstIndex(where: { $0.path == selected }) {
            let row = gtk_list_box_get_row_at_index(opaque(listBox), Int32(index))
            gtk_list_box_select_row(opaque(listBox), row)
        }
        isRebuilding = false
    }

    private func currentFilter() -> String {
        guard let text = gtk_editable_get_text(opaque(filterEntry)) else { return "" }
        return String(cString: text).lowercased()
    }

    private func makeRow(_ repo: Repository) -> UnsafeMutablePointer<GtkWidget> {
        let row = UI.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        UI.setMargin(row, 8)

        let title = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        if appState.store.isStarred(repo) {
            let star = require(gtk_image_new_from_icon_name("starred-symbolic"), "icon")
            UI.append(title, star)
        }
        let name = UI.label(repo.name, bold: true, ellipsize: true)
        UI.expand(name, vertical: false)
        UI.append(title, name)

        UI.append(row, title, UI.label(subtitle(for: repo), dim: true, ellipsize: true))
        return row
    }

    /// "main · 2 changes · ↑1 ↓3" — the same summary the macOS sidebar shows.
    private func subtitle(for repo: Repository) -> String {
        guard let summary = appState.store.summaries[repo.path] else { return repo.path }
        guard summary.isValid else { return "Not a repository" }
        var parts: [String] = [summary.branch ?? "detached"]
        if summary.isDirty { parts.append("uncommitted changes") }
        if summary.ahead > 0 { parts.append("\u{2191}\(summary.ahead)") }
        if summary.behind > 0 { parts.append("\u{2193}\(summary.behind)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Actions

    private func selectionChanged() {
        guard !isRebuilding,
              let row = gtk_list_box_get_selected_row(opaque(listBox)) else { return }
        let index = Int(gtk_list_box_row_get_index(row))
        guard rows.indices.contains(index) else { return }
        onSelect(rows[index])
    }

    private func removeSelected() {
        guard let row = gtk_list_box_get_selected_row(opaque(listBox)) else { return }
        let index = Int(gtk_list_box_row_get_index(row))
        guard rows.indices.contains(index) else { return }
        appState.remove(rows[index])
    }

    /// GTK 4's folder chooser is asynchronous: the result arrives on the main
    /// loop, which is exactly where the store wants to be mutated anyway.
    private func presentFolderChooser() {
        let dialog = require(gtk_file_dialog_new(), "file dialog")
        gtk_file_dialog_set_title(dialog, "Add Repository")
        let window = gtk_widget_get_root(widget).map { cast($0, to: GtkWindow.self) }

        let box = FolderChoiceBox { [weak self] url in
            self?.appState.addRepository(at: url)
        }
        gtk_file_dialog_select_folder(dialog, window, nil, { source, result, data in
            guard let data else { return }
            let box = Unmanaged<FolderChoiceBox>.fromOpaque(data).takeRetainedValue()
            guard let source,
                  let file = gtk_file_dialog_select_folder_finish(
                      OpaquePointer(source), result, nil),
                  let path = g_file_get_path(file) else { return }
            defer { g_free(path) }
            box.chosen(URL(fileURLWithPath: String(cString: path)))
        }, Unmanaged.passRetained(box).toOpaque())
    }
}

/// Carries the "folder picked" continuation across GTK's async callback.
private final class FolderChoiceBox {
    let chosen: (URL) -> Void
    init(_ chosen: @escaping (URL) -> Void) { self.chosen = chosen }
}
