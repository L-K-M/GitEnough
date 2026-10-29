import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The left pane: the list of registered repositories with a live summary row
/// (current branch, dirty marker, ahead/behind) and drag-and-drop import.
struct SidebarView: View {

    @EnvironmentObject var windowState: RepositoryWindowState
    @EnvironmentObject var store: RepoStore
    @AppStorage("sidebarSortOrder") private var sortOrderRaw = SidebarSortOrder.manual.rawValue
    @AppStorage("sidebarFilter") private var filterRaw = SidebarFilter.all.rawValue
    @State private var filterText = ""
    @State private var listFocusRequest = UUID()
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sortOrder: SidebarSortOrder {
        SidebarSortOrder(rawValue: sortOrderRaw) ?? .manual
    }

    private var sidebarFilter: SidebarFilter {
        SidebarFilter(rawValue: filterRaw) ?? .all
    }

    private var selection: Binding<String?> {
        Binding(
            get: { windowState.selectedRepoPath },
            set: { path in
                if let path, let repo = store.repositories.first(where: { $0.path == path }) {
                    windowState.select(repo)
                    listFocusRequest = UUID()
                } else if path == nil, let current = windowState.selectedRepoPath,
                          !store.repositories.contains(where: { $0.path == current }) {
                    // The selected repo is gone for good (removed) — clear the
                    // dangling selection. A transient nil (the List briefly
                    // losing the selected row mid re-render) is NOT cleared:
                    // this List has no deselect gesture, and letting it through
                    // wiped the selection and — with a logical filter active —
                    // the clicked repo's row along with it.
                    windowState.selectedRepoPath = nil
                }
            }
        )
    }

    /// Repositories after the logical filter, the filter text, the sort order,
    /// and the starred-first grouping are applied.
    private var visibleRepositories: [Repository] {
        var repos = store.repositories
        if sidebarFilter != .all {
            // Summaries load asynchronously; a repo whose state hasn't loaded yet
            // stays visible rather than flashing an empty sidebar on launch (the
            // filter is persisted, so this hits every cold start). The open
            // repository also always stays listed: a freshly cloned repo is
            // clean (nothing ahead, behind, or uncommitted) and would otherwise
            // vanish from the sidebar while its history shows in the detail pane.
            repos = repos.filter { repo in
                repo.path == windowState.selectedRepoPath || matchesLogicalFilter(repo)
            }
        }
        if !filterText.isEmpty {
            // Name always matches; the path only when the query looks like a path
            // — otherwise a shared parent folder (~/Documents/GitHub/…) makes every
            // plain word match everything, while "work/api" still disambiguates
            // same-named repos.
            let needle = filterText.lowercased()
            repos = repos.filter {
                $0.name.lowercased().contains(needle)
                    || (needle.contains("/") && $0.path.lowercased().contains(needle))
            }
        }
        switch sortOrder {
        case .manual:
            break
        case .name:
            repos.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .recentlyOpened:
            // Stable tie-break by name so never-opened repos don't shuffle.
            repos.sort {
                let lhs = store.lastOpenedAt[$0.path] ?? 0
                let rhs = store.lastOpenedAt[$1.path] ?? 0
                if lhs != rhs { return lhs > rhs }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        // Starred repos pin above the unstarred ones in every sort order. The
        // partition is stable, so each block keeps the order chosen above.
        return RepoStore.starredFirst(repos, starred: store.starredPaths)
    }

    /// How many registered repositories the logical filter currently hides
    /// (surfaced in the always-visible bottom bar, so an unexpectedly short
    /// list is explainable — and clickable). Suppressed while a text query is
    /// active — the search field itself explains that narrowing.
    private var hiddenByFilterCount: Int {
        guard sidebarFilter != .all, filterText.isEmpty else { return 0 }
        return store.repositories.filter { repo in
            repo.path != windowState.selectedRepoPath && !matchesLogicalFilter(repo)
        }.count
    }

    private func matchesLogicalFilter(_ repo: Repository) -> Bool {
        guard let summary = store.summaries[repo.path] else { return true }
        return sidebarFilter.matches(summary)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                Section {
                    if sortOrder == .manual && filterText.isEmpty && sidebarFilter == .all {
                        ForEach(visibleRepositories) { repo in
                            rowContent(repo)
                        }
                        .onMove { offsets, destination in
                            store.moveVisible(visibleRepositories,
                                              fromOffsets: offsets, toOffset: destination)
                        }
                    } else {
                        ForEach(visibleRepositories) { repo in
                            rowContent(repo)
                        }
                    }
                } header: {
                    Text("Repositories")
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $filterText, placement: .sidebar, prompt: "Filter repositories")
            .searchFocused($searchFocused)
            .onChange(of: windowState.sidebarSearchRequest) { _, _ in searchFocused = true }
            .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
            .onChange(of: windowState.lastAddedRepoPath) { _, newPath in
                reveal(newPath, with: proxy)
            }
            .safeAreaInset(edge: .bottom) {
                if !store.repositories.isEmpty {
                    VStack(spacing: 6) {
                        sidebarControls
                        // Always-visible counterpart to the old list footer: a
                        // repo that "vanished" is usually just filter-hidden,
                        // and a hint below the fold of a long list explains
                        // nothing. One click resets to the unfiltered list.
                        if hiddenByFilterCount > 0 {
                            Button("\(hiddenByFilterCount) hidden by the “\(sidebarFilter.displayName)” filter — show all") {
                                filterRaw = SidebarFilter.all.rawValue
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        Text("Drop a repository folder here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
    }

    private var sidebarControls: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Open Repository…") { windowState.openRepository() }
                Button("Clone Repository…") { windowState.showingAddRepository = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Add Repository")
            .help("Open or clone a repository")

            Spacer()

            Menu {
                Picker("Show", selection: $filterRaw) {
                    ForEach(SidebarFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter.rawValue)
                    }
                }
                Divider()
                Picker("Sort by", selection: $sortOrderRaw) {
                    ForEach(SidebarSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order.rawValue)
                    }
                }
            } label: {
                Label("Repository Options", systemImage: sidebarFilter == .all
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter and sort repositories")
        }
        .padding(.horizontal, 14)
    }

    /// Scrolls the sidebar so a freshly added repository is on screen. Deferred
    /// one runloop turn so the List has actually inserted the row first, and
    /// clears the cue afterwards so re-adding the same repository re-reveals it.
    private func reveal(_ path: String?, with proxy: ScrollViewProxy) {
        guard let path else { return }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(path, anchor: .center) }
            windowState.lastAddedRepoPath = nil
        }
    }

    @ViewBuilder
    private func rowContent(_ repo: Repository) -> some View {
        SidebarRow(repo: repo,
                   summary: store.summaries[repo.path] ?? .unknown,
                   isStarred: store.isStarred(repo)) {
            store.toggleStar(repo)
        }
        .tag(repo.path)
        .nativeListRowFocus(isSelected: windowState.selectedRepoPath == repo.path, focusRequest: listFocusRequest)
        .contextMenu {
            Button(store.isStarred(repo) ? "Unstar" : "Star") {
                store.toggleStar(repo)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.copyString(repo.path)
            }
            Divider()
            Button("Remove from GitEnough") {
                windowState.remove(repo)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    windowState.addDroppedRepository(at: url)
                }
            }
        }
        return accepted
    }
}

/// One repository row: name, path, branch + dirty/sync state, star toggle.
private struct SidebarRow: View {

    let repo: Repository
    let summary: RepoSummary
    let isStarred: Bool
    let toggleStar: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(repo.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !summary.isValid {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .help("This folder is missing or no longer a git repository.")
                }
                Spacer()
                // Hidden unless starred or hovered (opacity, not if/else, so the
                // row's layout never shifts as the star appears).
                Button(action: toggleStar) {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(isStarred ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .opacity(isStarred || isHovering ? 1 : 0)
                .allowsHitTesting(isStarred || isHovering)
                // Visibility is a hover-reveal mouse affordance; accessibility
                // must not depend on pointer hover — the toggle stays in the
                // VoiceOver tree on every row, with a spoken label.
                .accessibilityLabel(isStarred ? "Unstar \(repo.name)" : "Star \(repo.name)")
                .help(isStarred ? "Unstar this repository" : "Star this repository (pinned to the top)")
                if summary.isDirty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .help("Uncommitted changes")
                }
            }
            Text(abbreviatingHome(repo.path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                if let branch = summary.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if summary.ahead > 0 {
                    Label("\(summary.ahead)", systemImage: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if summary.behind > 0 {
                    Label("\(summary.behind)", systemImage: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
    }

    private func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
