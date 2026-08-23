import Foundation

/// A repository registered in the sidebar. Plain value type; the list is persisted
/// in UserDefaults as an array of paths (no sandbox → no security-scoped bookmarks
/// needed).
struct Repository: Identifiable, Hashable, Codable {
    let path: String
    let name: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    /// The path with `~` and `.`/`..` resolved and symlinks chased, for
    /// identity comparisons. The same working copy can arrive spelled
    /// differently — NSOpenPanel returns the path as browsed, watch-folder
    /// discovery resolves symlinks, git's --show-toplevel returns the physical
    /// path — and storing one folder under two spellings breaks sidebar
    /// identity (duplicate rows whose selection/equality behaves erratically).
    var normalizedPath: String {
        Self.normalizedPath(path)
    }

    /// Path normalization for identity comparisons. `standardizingPath` alone
    /// keeps symlinks on modern macOS, so chase them explicitly — discovery
    /// already does (its URLs go through `resolvingSymlinksInPath`).
    static func normalizedPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    init(url: URL) {
        self.init(path: url.path, name: url.lastPathComponent)
    }
}

/// Lightweight per-repo info for the sidebar row (branch, dirty dot, ahead/behind).
struct RepoSummary: Equatable {
    var branch: String?
    var isDirty: Bool
    var ahead: Int
    var behind: Int
    var isValid: Bool

    static let unknown = RepoSummary(branch: nil, isDirty: false, ahead: 0, behind: 0, isValid: true)
}

extension RepoSummary {
    /// Builds the sidebar summary from a fresh `git status` snapshot. Kept in an
    /// extension so the memberwise initializer (used by `.unknown` and the
    /// "invalid repo" placeholder) stays synthesized.
    init(status: RepoStatus) {
        self.init(branch: status.head ?? status.headHash.map { String($0.prefix(7)) },
                  isDirty: status.isDirty, ahead: status.ahead, behind: status.behind,
                  isValid: true)
    }
}

/// How the sidebar orders repositories (persisted in UserDefaults).
enum SidebarSortOrder: String, CaseIterable, Identifiable {
    case manual = "Manually"
    case name = "Name"
    case recentlyOpened = "Recently Opened"

    var id: String { rawValue }
}

/// Which repositories the sidebar shows (persisted in UserDefaults). Unlike the
/// text filter, these look at live repo state, so they're "logical" filters.
/// rawValues are stable persistence keys; displayName is the UI text (free to
/// change without breaking the persisted setting).
enum SidebarFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case dirty = "dirty"
    case unpushed = "unpushed"
    case incoming = "incoming"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All Repositories"
        case .dirty: return "Uncommitted Changes"
        case .unpushed: return "Unpushed Commits"
        case .incoming: return "Incoming Commits"
        }
    }

    func matches(_ summary: RepoSummary) -> Bool {
        switch self {
        case .all: return true
        case .dirty: return summary.isDirty
        case .unpushed: return summary.ahead > 0
        case .incoming: return summary.behind > 0
        }
    }
}

/// The sidebar's list of repositories: add, remove, reorder, persist, plus the
/// "removal sticks" bookkeeping for watch-folder discovery (paths the user
/// removed are never auto-re-added).
final class RepoStore: ObservableObject {

    @Published private(set) var repositories: [Repository] = []

    /// path → summary, refreshed by AppState.
    @Published var summaries: [String: RepoSummary] = [:]

    /// path → last-opened timestamp, for the "Recently Opened" sort order.
    @Published private(set) var lastOpenedAt: [String: TimeInterval] = [:]

    /// Paths of starred repositories — pinned above the unstarred ones in every
    /// sidebar sort order.
    @Published private(set) var starredPaths: Set<String> = []

    private static let repositoriesKey = "repositories.v1"
    private static let excludedKey = "excludedRepositories.v1"
    private static let lastOpenedKey = "repoLastOpened.v1"
    private static let starredKey = "starredRepositories.v1"

    private let defaults: UserDefaults

    /// Paths the user removed — excluded from discovery until manually re-added.
    private var excludedPaths: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        excludedPaths = Set(defaults.stringArray(forKey: Self.excludedKey) ?? [])
        starredPaths = Set(defaults.stringArray(forKey: Self.starredKey) ?? [])
        if let data = defaults.data(forKey: Self.lastOpenedKey),
           let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data) {
            lastOpenedAt = decoded
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.repositoriesKey),
              let decoded = try? JSONDecoder().decode([Repository].self, from: data) else {
            return
        }
        // Repair any duplicate spellings of the same folder left behind by
        // older builds (see normalizedPath): keep the first spelling stored.
        var seen: Set<String> = []
        repositories = decoded.filter { seen.insert($0.normalizedPath).inserted }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(repositories) {
            defaults.set(data, forKey: Self.repositoriesKey)
        }
    }

    private func persistExclusions() {
        defaults.set(Array(excludedPaths), forKey: Self.excludedKey)
    }

    private func persistStars() {
        defaults.set(Array(starredPaths), forKey: Self.starredKey)
    }

    /// Removes any exclusion for `repo` (any spelling — an exclusion stored
    /// under one path spelling must not block a re-add under another).
    private func clearExclusion(for repo: Repository) {
        let before = excludedPaths.count
        excludedPaths = excludedPaths.filter {
            Repository.normalizedPath($0) != repo.normalizedPath
        }
        if excludedPaths.count != before { persistExclusions() }
    }

    /// Registers an already-validated repository (validation — the git calls —
    /// is the caller's job and must happen off the main thread; see
    /// AppState.addRepository). A manual add also cancels a previous removal
    /// (discovery may re-offer it).
    ///
    /// Manual adds insert at the top of the unstarred block rather than
    /// appending: the repository the user just added is the one they're looking
    /// for, and at the bottom of a long manually-sorted list an append reads as
    /// "it didn't show up". (Discovery keeps appending — its finds are
    /// background additions, not user actions.)
    @discardableResult
    func register(_ repo: Repository) -> Repository {
        if let existing = repositories.first(where: {
            $0.normalizedPath == repo.normalizedPath
        }) {
            clearExclusion(for: existing)
            return existing
        }
        let insertAt = repositories.firstIndex(where: { !starredPaths.contains($0.path) })
            ?? repositories.count
        repositories.insert(repo, at: insertAt)
        persist()
        clearExclusion(for: repo)
        return repo
    }
    /// Adds already-validated repository URLs found by folder discovery. Skips
    /// paths the user removed earlier (removal sticks) and existing entries.
    /// Returns how many repos were actually added.
    @discardableResult
    func addDiscovered(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let path = url.path
            let normalized = Repository.normalizedPath(path)
            let excluded = excludedPaths.contains {
                Repository.normalizedPath($0) == normalized
            }
            let existing = repositories.contains {
                $0.normalizedPath == normalized
            }
            guard !excluded, !existing else { continue }
            repositories.append(Repository(path: path, name: url.lastPathComponent))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    func remove(_ repo: Repository) {
        // All spellings of the folder go, not just the exact object passed.
        repositories.removeAll { $0.normalizedPath == repo.normalizedPath }
        summaries.removeValue(forKey: repo.path)
        excludedPaths.insert(repo.path)
        // The star goes with the repo: starredPaths must only ever contain
        // registered paths, or its count could never again be used as an index
        // basis — and a removed repo re-added later shouldn't silently re-pin.
        starredPaths.remove(repo.path)
        persistStars()
        persistExclusions()
        persist()
    }

    /// Applies a sidebar drag expressed in *visible* row coordinates. The
    /// visible list (starred pinned first, then the rest) is a permutation of
    /// `repositories`, so the move is applied there; starred-first is
    /// re-imposed afterwards, which keeps the persisted manual order aligned
    /// with what the user sees (the sidebar re-derives the grouping on every
    /// render regardless).
    func moveVisible(_ visible: [Repository], fromOffsets: IndexSet, toOffset: Int) {
        guard visible.count == repositories.count,
              Set(visible.map(\.path)) == Set(repositories.map(\.path)) else { return }
        var moved = visible
        moved.move(fromOffsets: fromOffsets, toOffset: toOffset)
        repositories = Self.starredFirst(moved, starred: starredPaths)
        persist()
    }

    // MARK: - Starring

    func isStarred(_ repo: Repository) -> Bool {
        starredPaths.contains(repo.path)
    }

    /// Stars or unstars `repo`. The stored order is left untouched — the sidebar
    /// displays starred repositories first in every sort order (see
    /// `starredFirst(_:starred:)`). Unstarring drops the pin without moving
    /// anything; the stored order shown then is whatever manual dragging (via
    /// `moveVisible`) last persisted, which may already be aligned with a
    /// previously starred view.
    func toggleStar(_ repo: Repository) {
        // Guarded like RepoViewModel.publishBranch: no current call path can
        // reach this with an unlisted repo (the sidebar stars listed rows only),
        // but the guard keeps starredPaths honest — registered paths only —
        // which remove() already maintains.
        guard let registered = repositories.first(where: {
            $0.normalizedPath == repo.normalizedPath
        }) else { return }
        // The registered spelling, not the caller's: starredPaths is matched
        // against stored rows by exact path.
        if !starredPaths.insert(registered.path).inserted {
            starredPaths.remove(registered.path)
        }
        persistStars()
    }

    /// Repositories in sidebar display order: starred ones pinned above the
    /// unstarred ones, each block keeping its incoming order. Pure, so the
    /// sidebar's grouping (the user-facing contract of starring) is testable.
    static func starredFirst(_ repos: [Repository], starred: Set<String>) -> [Repository] {
        repos.filter { starred.contains($0.path) } + repos.filter { !starred.contains($0.path) }
    }

    /// Records that `repo` was selected (feeds the "Recently Opened" sort).
    func markOpened(_ repo: Repository) {
        lastOpenedAt[repo.path] = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(lastOpenedAt) {
            defaults.set(data, forKey: Self.lastOpenedKey)
        }
    }
}
