import CGtk
import GitEnough

/// Local and remote branches, and the stash. Double-click a branch to check it
/// out — a remote branch gets a tracking checkout, which is what `checkout`
/// already does for a remote entry.
final class BranchesPane {

    let widget: UnsafeMutablePointer<GtkWidget>

    private let viewModel: RepoViewModel
    private let localList = UI.listBox()
    private let remoteList = UI.listBox()
    private let stashList = UI.listBox()
    private var observer: ModelObserver?

    private var local: [Branch] = []
    private var remote: [Branch] = []
    private var stash: [StashEntry] = []

    init(viewModel: RepoViewModel) {
        self.viewModel = viewModel

        let column = UI.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        UI.append(column,
                  Self.header("Local"), UI.scroller(localList, horizontal: GTK_POLICY_NEVER),
                  Self.header("Remote"), UI.scroller(remoteList, horizontal: GTK_POLICY_NEVER),
                  Self.header("Stash"), UI.scroller(stashList, horizontal: GTK_POLICY_NEVER))
        widget = column

        connect(localList, "row-activated") { [weak self] _ in self?.checkout(from: false) }
        connect(remoteList, "row-activated") { [weak self] _ in self?.checkout(from: true) }
        connect(stashList, "row-activated") { [weak self] _ in self?.applyStash() }

        observer = ModelObserver(viewModel) { [weak self] in self?.refresh() }
        refresh()
    }



    private static func header(_ title: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = UI.label(title, bold: true)
        UI.setMargin(label, 6)
        return label
    }

    private func refresh() {
        let allLocal = viewModel.branches.filter { !$0.isRemote }
        let allRemote = viewModel.branches.filter(\.isRemote)

        if local.map(\.id) != allLocal.map(\.id) || local.map(\.isHead) != allLocal.map(\.isHead) {
            local = allLocal
            UI.replaceRows(localList, with: local.map(row))
        }
        if remote.map(\.id) != allRemote.map(\.id) {
            remote = allRemote
            UI.replaceRows(remoteList, with: remote.map(row))
        }
        if stash.map(\.id) != viewModel.stash.map(\.id) {
            stash = viewModel.stash
            UI.replaceRows(stashList, with: stash.map { entry in
                let box = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, margin: 4)
                let label = UI.label(entry.message, ellipsize: true)
                UI.expand(label, vertical: false)
                UI.append(box, UI.label(entry.ref, dim: true, monospace: true), label)
                return box
            })
        }
    }

    private func row(_ branch: Branch) -> UnsafeMutablePointer<GtkWidget> {
        let box = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, margin: 4)
        let name = UI.label(branch.name, bold: branch.isHead, ellipsize: true)
        UI.expand(name, vertical: false)
        UI.append(box, name)
        var tracking: [String] = []
        if branch.ahead > 0 { tracking.append("\u{2191}\(branch.ahead)") }
        if branch.behind > 0 { tracking.append("\u{2193}\(branch.behind)") }
        if !tracking.isEmpty {
            UI.append(box, UI.label(tracking.joined(separator: " "), dim: true))
        }
        return box
    }

    private func checkout(from remoteList: Bool) {
        let list = remoteList ? self.remoteList : localList
        let branches = remoteList ? remote : local
        guard let row = gtk_list_box_get_selected_row(opaque(list)) else { return }
        let index = Int(gtk_list_box_row_get_index(row))
        guard branches.indices.contains(index) else { return }
        viewModel.checkout(branch: branches[index])
    }

    private func applyStash() {
        guard let row = gtk_list_box_get_selected_row(opaque(stashList)) else { return }
        let index = Int(gtk_list_box_row_get_index(row))
        guard stash.indices.contains(index) else { return }
        viewModel.stashApply(stash[index], pop: false)
    }
}
