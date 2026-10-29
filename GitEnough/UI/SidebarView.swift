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
    @AppStorage("sidebarGroupingMode") private var groupingRaw = SidebarGroupingMode.none.rawValue
    @State private var filterText = ""
    @State private var listFocusRequest = UUID()
    @State private var selectedGroupHeaderID: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var groupNameFocused: Bool
    @State private var showingGroupEditor = false
    @State private var groupToEdit: ManualRepositoryGroup?
    @State private var repositoryForNewGroup: Repository?
    @State private var groupName = ""
    @State private var groupError: String?
    @State private var groupToDelete: ManualRepositoryGroup?
    @State private var groupingError: String?
    @State private var pendingGroupRevealID: String?
    @State private var searchExpansionSnapshot: SearchExpansionSnapshot?

    private struct SearchExpansionSnapshot {
        let expandedGroupID: String?
        let selectedRepoPath: String?
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var groupingMode: SidebarGroupingMode {
        SidebarGroupingMode(rawValue: groupingRaw) ?? .none
    }

    private var groups: [SidebarRepositoryGroup] {
        let grouped = SidebarGrouping.groups(for: visibleRepositories, mode: groupingMode,
                                              summaries: store.summaries,
                                              manualGroups: store.manualGroups,
                                              assignments: store.manualGroupAssignments)
        // Empty manual groups remain manageable until a filter is applied.
        if !filterText.isEmpty || sidebarFilter != .all {
            return grouped.filter { !$0.repositories.isEmpty }
        }
        return grouped
    }

    private var selectedGroupID: String? {
        groups.first { $0.repositories.contains { $0.path == windowState.selectedRepoPath } }?.id
    }

    private var sortOrder: SidebarSortOrder {
        SidebarSortOrder(rawValue: sortOrderRaw) ?? .manual
    }

    private var sidebarFilter: SidebarFilter {
        SidebarFilter(rawValue: filterRaw) ?? .all
    }

    private var searchText: Binding<String> {
        Binding(get: { filterText }, set: { value in
            if filterText.isEmpty, !value.isEmpty {
                searchExpansionSnapshot = SearchExpansionSnapshot(
                    expandedGroupID: windowState.expandedSidebarGroupID,
                    selectedRepoPath: windowState.selectedRepoPath)
            }
            filterText = value
        })
    }

    private var selection: Binding<String?> {
        Binding(
            get: { selectedGroupHeaderID ?? windowState.selectedRepoPath },
            set: { path in
                if let path, let repo = store.repositories.first(where: { $0.path == path }) {
                    selectedGroupHeaderID = nil
                    windowState.select(repo)
                    listFocusRequest = UUID()
                } else if let path, groupingMode != .none,
                          groups.contains(where: { $0.id == path }) {
                    // Headers participate in native outline selection and key
                    // navigation without changing the repository being viewed.
                    selectedGroupHeaderID = path
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
                if groupingMode == .none {
                    flatRepositoryList
                } else {
                    ForEach(groups) { group in
                        repositoryGroup(group)
                    }
                }
                if visibleRepositories.isEmpty && !store.repositories.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No repositories match")
                            .foregroundStyle(.secondary)
                        Button("Clear Filters") {
                            filterText = ""
                            filterRaw = SidebarFilter.all.rawValue
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.vertical, 8)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: searchText, placement: .sidebar, prompt: "Filter repositories")
            .searchFocused($searchFocused)
            .onChange(of: windowState.sidebarSearchRequest) { _, _ in searchFocused = true }
            .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
            .onChange(of: windowState.lastAddedRepoPath) { _, newPath in
                reveal(newPath, with: proxy)
            }
            .onAppear { reconcileExpansion(openIfCollapsed: !windowState.hasSavedSidebarGroupState) }
            .onChange(of: groupingRaw) { _, _ in
                selectedGroupHeaderID = nil
                if let pending = pendingGroupRevealID {
                    windowState.expandedSidebarGroupID = pending
                    pendingGroupRevealID = nil
                } else {
                    windowState.expandedSidebarGroupID = selectedGroupID ?? groups.first?.id
                }
            }
            .onChange(of: windowState.selectedRepoPath) { _, _ in
                selectedGroupHeaderID = nil
                if groupingMode != .none, let selectedGroupID {
                    windowState.expandedSidebarGroupID = selectedGroupID
                }
            }
            .onChange(of: groups.map(\.id)) { _, ids in
                if let selectedGroupHeaderID, !ids.contains(selectedGroupHeaderID) {
                    self.selectedGroupHeaderID = nil
                }
                reconcileExpansion()
            }
            .onChange(of: windowState.expandedSidebarGroupID) { _, id in
                if id != nil { reconcileExpansion() }
            }
            .onChange(of: filterText) { previous, current in
                guard groupingMode != .none else { return }
                if !current.isEmpty {
                    windowState.expandedSidebarGroupID = groups.first?.id
                } else if !previous.isEmpty, let snapshot = searchExpansionSnapshot {
                    searchExpansionSnapshot = nil
                    if windowState.selectedRepoPath != snapshot.selectedRepoPath {
                        windowState.expandedSidebarGroupID = selectedGroupID ?? groups.first?.id
                    } else if let previousGroup = snapshot.expandedGroupID {
                        windowState.expandedSidebarGroupID = groups.contains { $0.id == previousGroup }
                            ? previousGroup : selectedGroupID ?? groups.first?.id
                    } else {
                        windowState.expandedSidebarGroupID = nil
                    }
                } else {
                    reconcileExpansion(openIfCollapsed: true)
                }
            }
            .onChange(of: filterRaw) { _, _ in reconcileExpansion(openIfCollapsed: true) }
            .onChange(of: selectedGroupID) { previous, current in
                if groupingMode != .none, previous != nil, let current,
                   windowState.expandedSidebarGroupID == previous {
                    windowState.expandedSidebarGroupID = current
                }
            }
            .safeAreaInset(edge: .bottom) {
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
        .sheet(isPresented: $showingGroupEditor) { groupEditor }
        .confirmationDialog("Delete group “\(groupToDelete?.name ?? "")”?",
                            isPresented: Binding(get: { groupToDelete != nil },
                                                 set: { if !$0 { groupToDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: groupToDelete) { group in
            Button("Delete Group", role: .destructive) { store.deleteGroup(group) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Repositories in this group will move to Ungrouped. Their files stay in place.")
        }
        .alert("Couldn't Move Repository",
               isPresented: Binding(get: { groupingError != nil },
                                    set: { if !$0 { groupingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(groupingError ?? "") }
    }

    @ViewBuilder
    private var flatRepositoryList: some View {
        Section("Repositories") {
            if sortOrder == .manual && filterText.isEmpty && sidebarFilter == .all {
                ForEach(visibleRepositories) { repo in rowContent(repo) }
                    .onMove { offsets, destination in
                        store.moveVisible(visibleRepositories, fromOffsets: offsets, toOffset: destination)
                    }
            } else {
                ForEach(visibleRepositories) { repo in rowContent(repo) }
            }
        }
    }

    private func repositoryGroup(_ group: SidebarRepositoryGroup) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { windowState.expandedSidebarGroupID == group.id },
            set: { expanded in
                if expanded {
                    windowState.expandedSidebarGroupID = group.id
                } else if windowState.expandedSidebarGroupID == group.id {
                    windowState.expandedSidebarGroupID = nil
                }
            })) {
                ForEach(group.repositories) { repo in rowContent(repo) }
                if group.repositories.isEmpty {
                    Text("No repositories in this group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title).lineLimit(1)
                        if let subtitle = group.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text("\(group.repositories.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .help([group.title, group.subtitle].compactMap { $0 }.joined(separator: " · "))
                .nativeListRowFocus(isSelected: selectedGroupHeaderID == group.id,
                                    focusRequest: listFocusRequest)
                .contextMenu {
                    if let id = group.manualGroupID,
                       let manualGroup = store.manualGroups.first(where: { $0.id == id }) {
                        Button("Rename Group…") { editGroup(manualGroup) }
                        Button("Delete Group…", role: .destructive) { groupToDelete = manualGroup }
                    }
                }
            }
        .tag(group.id)
    }

    private func reconcileExpansion(openIfCollapsed: Bool = false) {
        guard groupingMode != .none else { return }
        if let expanded = windowState.expandedSidebarGroupID {
            if !groups.contains(where: { $0.id == expanded }) {
                windowState.expandedSidebarGroupID = selectedGroupID ?? groups.first?.id
            }
        } else if let pending = pendingGroupRevealID {
            windowState.expandedSidebarGroupID = pending
            pendingGroupRevealID = nil
        } else if openIfCollapsed {
            windowState.expandedSidebarGroupID = selectedGroupID ?? groups.first?.id
        }
    }

    private func newGroup(including repository: Repository? = nil) {
        groupToEdit = nil
        repositoryForNewGroup = repository
        groupName = ""
        groupError = nil
        showingGroupEditor = true
    }

    private func editGroup(_ group: ManualRepositoryGroup) {
        groupToEdit = group
        repositoryForNewGroup = nil
        groupName = group.name
        groupError = nil
        showingGroupEditor = true
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(groupToEdit == nil ? "New Repository Group" : "Rename Group")
                .font(.headline)
            TextField("Group name", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .focused($groupNameFocused)
                .frame(width: 320)
            if let groupError {
                Text(groupError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingGroupEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button(groupToEdit == nil ? "Create Group" : "Rename") { saveGroup() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear { groupNameFocused = true }
    }

    private func saveGroup() {
        do {
            if let groupToEdit {
                try store.renameGroup(groupToEdit, to: groupName)
            } else {
                let group = try store.createGroup(named: groupName, including: repositoryForNewGroup)
                showManualGroup(group.sidebarID)
            }
            showingGroupEditor = false
        } catch {
            groupError = error.localizedDescription
        }
    }

    private func showManualGroup(_ id: String) {
        // An explicit destination should be visible even if an earlier filter
        // would hide its repositories or a freshly created empty group.
        searchExpansionSnapshot = nil
        filterText = ""
        filterRaw = SidebarFilter.all.rawValue
        if groupingMode != .manual {
            pendingGroupRevealID = id
            groupingRaw = SidebarGroupingMode.manual.rawValue
        }
        windowState.expandedSidebarGroupID = id
    }

    private func move(_ repository: Repository, to group: ManualRepositoryGroup?) {
        do {
            try store.move(repository, toGroup: group)
            showManualGroup(group?.sidebarID ?? SidebarGrouping.ungroupedID)
        } catch {
            groupingError = error.localizedDescription
        }
    }

    private var sidebarControls: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Open Repository…") { windowState.openRepository() }
                Button("Clone Repository…") { windowState.showingAddRepository = true }
                Divider()
                Button("New Group…") { newGroup() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Add Repository")
            .help("Open, clone, or group repositories")

            Spacer()

            Menu {
                Picker("Show", selection: $filterRaw) {
                    ForEach(SidebarFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter.rawValue)
                    }
                }
                Divider()
                Picker("Group by", selection: $groupingRaw) {
                    ForEach(SidebarGroupingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Divider()
                Picker("Sort by", selection: $sortOrderRaw) {
                    ForEach(SidebarSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order.rawValue)
                    }
                }
                Divider()
                Button("New Group…") { newGroup() }
                if !store.manualGroups.isEmpty {
                    Menu("Manage Groups") {
                        ForEach(store.manualGroups) { group in
                            Menu(group.name) {
                                Button("Rename…") { editGroup(group) }
                                Button("Delete…", role: .destructive) { groupToDelete = group }
                            }
                        }
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
            .help("Filter, group, and sort repositories")
        }
        .padding(.horizontal, 14)
    }

    /// Scrolls the sidebar so a freshly added repository is on screen. Deferred
    /// one runloop turn so the List has actually inserted the row first, and
    /// clears the cue afterwards so re-adding the same repository re-reveals it.
    private func reveal(_ path: String?, with proxy: ScrollViewProxy) {
        guard let path else { return }
        if groupingMode != .none,
           let group = groups.first(where: { $0.repositories.contains { $0.path == path } }) {
            windowState.expandedSidebarGroupID = group.id
        }
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
        .nativeListRowFocus(isSelected: selectedGroupHeaderID == nil
                            && windowState.selectedRepoPath == repo.path,
                            focusRequest: listFocusRequest)
        .contextMenu {
            Button(store.isStarred(repo) ? "Unstar" : "Star") {
                store.toggleStar(repo)
            }
            Menu("Move to Group") {
                Button {
                    move(repo, to: nil)
                } label: {
                    if store.manualGroup(for: repo) == nil {
                        Label("Ungrouped", systemImage: "checkmark")
                    } else {
                        Text("Ungrouped")
                    }
                }
                ForEach(store.manualGroups) { group in
                    Button {
                        move(repo, to: group)
                    } label: {
                        if store.manualGroup(for: repo)?.id == group.id {
                            Label(group.name, systemImage: "checkmark")
                        } else {
                            Text(group.name)
                        }
                    }
                }
                Divider()
                Button("New Group…") { newGroup(including: repo) }
            }
            Divider()
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
