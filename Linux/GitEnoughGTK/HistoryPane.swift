import CGtk
import Foundation
import GitEnough

/// The history graph: `git log --all` as coloured lanes beside the commits,
/// with a detail pane for the selected commit.
final class HistoryPane {

    let widget: UnsafeMutablePointer<GtkWidget>

    private let viewModel: RepoViewModel
    private let listBox: UnsafeMutablePointer<GtkWidget>
    private let detailFiles: UnsafeMutablePointer<GtkWidget>
    private let detailSubject: UnsafeMutablePointer<GtkWidget>
    private let detailMeta: UnsafeMutablePointer<GtkWidget>
    private let diffView = DiffView()
    private var observer: ModelObserver?

    private var shownCommits: [Commit] = []
    private var shownFiles: [CommitFile] = []
    private var isRebuilding = false
    /// Signature of the state the list was last built from, so a publish that
    /// didn't touch the history (a status poll, say) doesn't rebuild it and
    /// throw away the user's selection and scroll position.
    private var builtSignature: String = ""

    init(viewModel: RepoViewModel) {
        self.viewModel = viewModel

        listBox = UI.listBox()
        // Two labels rather than one with a newline: an ellipsizing label is in
        // single-line mode, which renders the newline as a visible glyph.
        detailSubject = UI.label("", bold: true, ellipsize: true, selectable: true)
        detailMeta = UI.label("", dim: true, ellipsize: true, selectable: true)
        let header = UI.box(GTK_ORIENTATION_VERTICAL, spacing: 2, margin: 8)
        UI.append(header, detailSubject, detailMeta)
        detailFiles = UI.listBox()

        let detail = UI.box(GTK_ORIENTATION_VERTICAL)
        UI.append(detail, header,
                  UI.paned(GTK_ORIENTATION_HORIZONTAL,
                           start: UI.scroller(detailFiles, horizontal: GTK_POLICY_NEVER), end: diffView.widget,
                           position: 260))

        widget = UI.paned(GTK_ORIENTATION_VERTICAL,
                          start: UI.scroller(listBox, horizontal: GTK_POLICY_NEVER),
                          end: detail, position: 380)

        connect(listBox, "row-selected") { [weak self] _ in self?.commitSelected() }
        connect(detailFiles, "row-selected") { [weak self] _ in self?.fileSelected() }
        Theme.onChange { [weak self] in self?.rebuild(force: true) }

        observer = ModelObserver(viewModel) { [weak self] in self?.rebuild() }
        rebuild()
    }

    // MARK: - Commit list

    private func rebuild(force: Bool = false) {
        let signature = historySignature()
        if signature != builtSignature || force {
            builtSignature = signature
            rebuildCommitRows()
        }
        updateDetail()
    }

    /// Cheap identity for "the history as displayed": the loaded commits, the
    /// lane layout they were laid out into, and which one is selected.
    private func historySignature() -> String {
        let head = viewModel.commits.first?.hash ?? "-"
        let tail = viewModel.commits.last?.hash ?? "-"
        return [head, tail, "\(viewModel.commits.count)",
                "\(viewModel.layout.columnCount)",
                "\(viewModel.canLoadMoreHistory)"].joined(separator: "/")
    }

    private func rebuildCommitRows() {
        shownCommits = viewModel.commits
        let isDark = Theme.isDark
        var rows = shownCommits.enumerated().map { index, commit in
            commitRow(commit, row: index, isDark: isDark)
        }
        if viewModel.canLoadMoreHistory {
            rows.append(loadMoreRow())
        }
        isRebuilding = true
        UI.replaceRows(listBox, with: rows)
        isRebuilding = false
    }

    private func commitRow(_ commit: Commit, row: Int,
                           isDark: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let box = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_size_request(box, -1, Int32(GraphMetrics.rowHeight))

        UI.append(box, GraphStrip.make(layout: viewModel.layout, row: row,
                                       isHeadRow: commit.isHead,
                                       isUnpushed: viewModel.unpushedHashes.contains(commit.hash),
                                       isDark: isDark))

        for decoration in commit.decorations {
            let chip = UI.label(decoration.name, dim: true)
            UI.addClass(chip, "caption")
            UI.addClass(chip, decoration.kind == .head ? "accent" : "dim-label")
            gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
            UI.append(box, chip)
        }

        let subject = UI.label(commit.subject, ellipsize: true)
        UI.expand(subject, vertical: false)
        gtk_widget_set_valign(subject, GTK_ALIGN_CENTER)
        UI.append(box, subject)

        let meta = UI.label("\(commit.author)  \(commit.shortHash)", dim: true)
        gtk_widget_set_valign(meta, GTK_ALIGN_CENTER)
        UI.append(box, meta)

        // Horizontal padding only: a vertical margin would open a gap between
        // one row's strip and the next, and the lanes are meant to read as
        // continuous lines running the height of the list.
        gtk_widget_set_margin_start(box, 6)
        gtk_widget_set_margin_end(box, 6)
        return box
    }

    private func loadMoreRow() -> UnsafeMutablePointer<GtkWidget> {
        let box = UI.box(GTK_ORIENTATION_HORIZONTAL, margin: 6)
        let label = UI.label("Load more history…", dim: true, xalign: 0.5)
        UI.expand(label, vertical: false)
        UI.append(box, label)
        return box
    }

    // MARK: - Selection

    private func commitSelected() {
        guard !isRebuilding,
              let row = gtk_list_box_get_selected_row(opaque(listBox)) else { return }
        let index = Int(gtk_list_box_row_get_index(row))
        if index == shownCommits.count {
            viewModel.loadMoreHistory()
            return
        }
        guard shownCommits.indices.contains(index) else { return }
        viewModel.selectCommit(shownCommits[index].hash)
    }

    private func fileSelected() {
        guard !isRebuilding,
              let detail = viewModel.selectedCommitDetail,
              let row = gtk_list_box_get_selected_row(opaque(detailFiles)) else { return }
        let index = Int(gtk_list_box_row_get_index(row))
        guard shownFiles.indices.contains(index) else { return }
        viewModel.selectCommitFile(hash: detail.hash, path: shownFiles[index].path)
    }

    // MARK: - Detail

    private func updateDetail() {
        guard let detail = viewModel.selectedCommitDetail else {
            UI.setText(detailSubject, "Select a commit")
            UI.setText(detailMeta, "")
            shownFiles = []
            isRebuilding = true
            UI.replaceRows(detailFiles, with: [])
            isRebuilding = false
            diffView.show("")
            return
        }

        let when = detail.date.map { Self.dateFormatter.string(from: $0) } ?? ""
        UI.setText(detailSubject, detail.subject)
        UI.setText(detailMeta,
                   "\(detail.author) <\(detail.email)>  \(when)  "
                   + String(detail.hash.prefix(7)))

        if shownFiles.map(\.path) != detail.files.map(\.path) {
            shownFiles = detail.files
            isRebuilding = true
            UI.replaceRows(detailFiles, with: shownFiles.map { file in
                let row = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, margin: 4)
                UI.append(row, UI.label(file.status.rawValue, dim: true, monospace: true))
                let path = UI.label(file.path, ellipsize: true)
                UI.expand(path, vertical: false)
                UI.append(row, path)
                return row
            })
            isRebuilding = false
        }
        diffView.show(viewModel.selectedCommitFileDiff)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
