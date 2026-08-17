import Foundation

/// A repository registered in the sidebar. Plain value type; the list is persisted
/// in UserDefaults as an array of paths (no sandbox → no security-scoped bookmarks
/// needed).
struct Repository: Identifiable, Hashable, Codable {
    let path: String
    let name: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    init(url: URL) {
        self.path = url.path
        self.name = url.lastPathComponent
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

/// The sidebar's list of repositories: add, remove, reorder, persist.
final class RepoStore: ObservableObject {

    @Published private(set) var repositories: [Repository] = []

    /// path → summary, refreshed by AppState.
    @Published var summaries: [String: RepoSummary] = [:]

    private let defaultsKey = "repositories.v1"

    init() {
        load()
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

    /// Adds the repo containing `url` (any depth inside a worktree resolves to the
    /// worktree root). Returns the repo, or nil when the folder isn't a git repo.
    @discardableResult
    func add(url: URL) -> Repository? {
        guard GitClient.isRepository(at: url),
              let topLevel = GitClient.topLevel(of: url) else { return nil }
        let repo = Repository(url: topLevel)
        if !repositories.contains(repo) {
            repositories.append(repo)
            persist()
        }
        return repositories.first { $0 == repo }
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0 == repo }
        summaries.removeValue(forKey: repo.path)
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        repositories.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }
}
