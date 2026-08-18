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

/// How the sidebar orders repositories (persisted in UserDefaults).
enum SidebarSortOrder: String, CaseIterable, Identifiable {
    case manual = "Manually"
    case name = "Name"
    case recentlyOpened = "Recently Opened"

    var id: String { rawValue }
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

    private let defaultsKey = "repositories.v1"
    private let excludedKey = "excludedRepositories.v1"
    private let lastOpenedKey = "repoLastOpened.v1"

    /// Paths the user removed — excluded from discovery until manually re-added.
    private var excludedPaths: Set<String> = []

    init() {
        load()
        excludedPaths = Set(UserDefaults.standard.stringArray(forKey: excludedKey) ?? [])
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

    /// Adds the repo containing `url` (any depth inside a worktree resolves to the
    /// worktree root). Returns the repo, or nil when the folder isn't a git repo.
    /// A manual add also cancels a previous removal (discovery may re-offer it).
    @discardableResult
    func add(url: URL) -> Repository? {
        guard GitClient.isRepository(at: url),
              let topLevel = GitClient.topLevel(of: url) else { return nil }
        let repo = Repository(url: topLevel)
        if !repositories.contains(repo) {
            repositories.append(repo)
            persist()
        }
        if excludedPaths.remove(topLevel.path) != nil {
            persistExclusions()
        }
        return repositories.first { $0 == repo }
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
        persistExclusions()
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        repositories.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    /// Records that `repo` was selected (feeds the "Recently Opened" sort).
    func markOpened(_ repo: Repository) {
        lastOpenedAt[repo.path] = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(lastOpenedAt) {
            UserDefaults.standard.set(data, forKey: lastOpenedKey)
        }
    }
}
