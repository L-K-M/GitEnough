import Foundation

/// A repository registered in the sidebar. Plain value type; the list is persisted
/// in UserDefaults as an array of paths (no sandbox → no security-scoped bookmarks
/// needed).
struct Repository: Identifiable, Hashable, Codable {
    let path: String
    let name: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

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

    private let defaultsKey = "repositories.v1"
    private let excludedKey = "excludedRepositories.v1"
    private let lastOpenedKey = "repoLastOpened.v1"
    private let starredKey = "starredRepositories.v1"

    /// Paths the user removed — excluded from discovery until manually re-added.
    private var excludedPaths: Set<String> = []

    init() {
        load()
        excludedPaths = Set(UserDefaults.standard.stringArray(forKey: excludedKey) ?? [])
        starredPaths = Set(UserDefaults.standard.stringArray(forKey: starredKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: lastOpenedKey),
           let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data) {
            lastOpenedAt = decoded
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Repository].self, from: data) else {
            return
        }
        repositories = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(repositories) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func persistExclusions() {
        UserDefaults.standard.set(Array(excludedPaths), forKey: excludedKey)
    }

    private func persistStars() {
        UserDefaults.standard.set(Array(starredPaths), forKey: starredKey)
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
        if let existing = repositories.first(where: { $0 == repo }) {
            if excludedPaths.remove(repo.path) != nil { persistExclusions() }
            return existing
        }
        let insertAt = repositories.firstIndex(where: { !starredPaths.contains($0.path) })
            ?? repositories.count
        repositories.insert(repo, at: insertAt)
        persist()
        if excludedPaths.remove(repo.path) != nil { persistExclusions() }
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
            guard !excludedPaths.contains(path),
                  !repositories.contains(where: { $0.path == path }) else { continue }
            repositories.append(Repository(path: path, name: url.lastPathComponent))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0 == repo }
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
        if !starredPaths.insert(repo.path).inserted {
            starredPaths.remove(repo.path)
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
            UserDefaults.standard.set(data, forKey: lastOpenedKey)
        }
    }
}
