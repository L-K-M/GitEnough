import Foundation

/// An open pull request on a forge, resolved for the current branch.
struct PullRequest: Equatable {
    let number: Int
    let title: String
    let url: URL
}

/// Resolves the open pull request for a branch on its forge with short,
/// unauthenticated REST calls:
///
/// - **github.com** → the GitHub API (`?head=owner:branch`),
/// - **gitlab.com** → the GitLab v4 API (`/api/v4/projects/{owner%2Frepo}/merge_requests`),
/// - **anything else** → a Forgejo/Gitea API attempt (`/api/v1/…`), then a
///   GitLab v4 attempt; a host that answers neither simply yields no result.
///
/// No credentials are involved, so this works for public repos; for private
/// repos the caller falls back to opening the forge's "create PR" page, which —
/// once the browser is signed in — shows an "already has a pull request"
/// banner. That keeps forge tokens out of GitEnough entirely.
final class PullRequestFinder {

    /// Shared instance: one ephemeral session instead of one per lookup.
    static let shared = PullRequestFinder()

    private let session: URLSession

    init(session: URLSession = PullRequestFinder.makeSession()) {
        self.session = session
    }

    /// An ephemeral session with short timeouts — the lookup is a nice-to-have
    /// before opening the browser and must never hang the button for long.
    /// Generic hosts run two probes sequentially (Forgejo, then GitLab), so the
    /// per-request budget is 5 s to keep the worst case ~10 s.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }

    // MARK: - Lookup

    /// The open PR whose head is `headBranch`, or nil when there is none / when
    /// it can't be determined (private repo, offline, unsupported forge).
    func findOpenPullRequest(for forge: ForgeRepo, headBranch: String) async -> PullRequest? {
        switch forge.kind {
        case .github:
            return await findOnGitHub(forge, headBranch: headBranch)
        case .gitlab:
            return await findOnGitLab(forge, headBranch: headBranch)
        case .forgejo:
            return await findOnForgejo(forge, headBranch: headBranch)
        case .generic:
            // Self-hosted hosts are usually Forgejo/Gitea or GitLab; two cheap
            // probes also pin the kind, so the fallback URL takes the right
            // shape even when the branch has no PR yet.
            if let found = await findOnForgejo(forge, headBranch: headBranch) {
                return found
            }
            return await findOnGitLab(forge, headBranch: headBranch)
        }
    }

    private func findOnGitHub(_ forge: ForgeRepo, headBranch: String) async -> PullRequest? {
        guard let url = Self.gitHubLookupURL(forge, headBranch: headBranch),
              let data = await get(url) else { return nil }
        return Self.parseGitHubPullRequests(data, forge: forge, headBranch: headBranch).first
    }

    private func findOnForgejo(_ forge: ForgeRepo, headBranch: String) async -> PullRequest? {
        guard let url = Self.forgejoLookupURL(forge),
              let data = await get(url) else { return nil }
        return Self.parseForgejoPullRequests(data, forge: forge, headBranch: headBranch).first
    }

    private func findOnGitLab(_ forge: ForgeRepo, headBranch: String) async -> PullRequest? {
        guard let url = Self.gitLabLookupURL(forge, headBranch: headBranch),
              let data = await get(url) else { return nil }
        return Self.parseGitLabMergeRequests(data, forge: forge, headBranch: headBranch).first
    }

    /// GET returning the body only for HTTP 200. Sends a User-Agent — the
    /// GitHub API rejects requests without one. No per-request timeout: the
    /// session's 10 s request timeout applies.
    private func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("GitEnough", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Endpoint building (pure)

    /// `https://api.github.com/repos/{owner}/{repo}/pulls?state=open&head={owner}:{branch}`
    /// — the head filter restricts the answer to PRs from this repo's branch.
    /// (When the remote is a *fork*, PRs opened against the upstream parent are
    /// not listed here; the caller then opens the fork's own compare page.)
    static func gitHubLookupURL(_ forge: ForgeRepo, headBranch: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(forge.owner)/\(forge.repo)/pulls"
            + "?state=open&head=\(forge.owner):\(encodeQuery(headBranch))")
    }

    /// `{origin}/api/v1/repos/{owner}/{repo}/pulls?state=open&limit=50` — the
    /// Forgejo/Gitea pulls endpoint; matching by head ref happens after
    /// parsing (the API has no head filter parameter). Repos with more than 50
    /// open PRs fall back to the create page — acceptable for a best-effort
    /// lookup.
    static func forgejoLookupURL(_ forge: ForgeRepo) -> URL? {
        URL(string: forge.origin.absoluteString
            + "/api/v1/repos/\(forge.owner)/\(forge.repo)/pulls?state=open&limit=50")
    }

    /// `{origin}/api/v4/projects/{owner%2Frepo}/merge_requests?state=opened&source_branch={branch}`
    /// — readable without credentials for public projects, like the rest of
    /// the lookups here. GitLab identifies a project by its full path with
    /// every "/" percent-encoded as %2F (nested groups included).
    static func gitLabLookupURL(_ forge: ForgeRepo, headBranch: String) -> URL? {
        let project = "\(forge.owner)/\(forge.repo)"
            .addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "-._~")))
        guard let project else { return nil }
        return URL(string: forge.origin.absoluteString
            + "/api/v4/projects/\(project)/merge_requests?state=opened"
            + "&source_branch=\(encodeQuery(headBranch))")
    }

    private static func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
                .subtracting(CharacterSet(charactersIn: "&=+")))
            ?? ""
    }

    // MARK: - Response parsing (pure)

    /// Parses a GitHub `GET /repos/…/pulls` array and keeps only PRs whose head
    /// ref is `headBranch` **and whose head repository is this repo** — the
    /// same fork-collision guard the Forgejo parser applies, so a dropped or
    /// ignored `?head=` filter can never surface a fork's PR. The URL is built
    /// from the forge, not from `html_url`. Empty on any malformed shape
    /// (GitHub error bodies are JSON objects).
    static func parseGitHubPullRequests(_ data: Data, forge: ForgeRepo,
                                        headBranch: String) -> [PullRequest] {
        struct Entry: Decodable {
            let number: Int
            let title: String?
            let head: Head?
            struct Head: Decodable {
                let ref: String?
                let repo: Repo?
                struct Repo: Decodable { let full_name: String? }
            }
        }
        let expected = "\(forge.owner)/\(forge.repo)".lowercased()
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            guard entry.head?.ref == headBranch,
                  entry.head?.repo?.full_name?.lowercased() == expected else { return nil }
            return PullRequest(number: entry.number, title: entry.title ?? "",
                               url: forge.pullRequestURL(number: entry.number))
        }
    }

    /// Parses a Forgejo/Gitea `GET /repos/…/pulls` array, keeping only PRs
    /// whose head ref is `headBranch` **and whose head repository is this
    /// repo** — the list includes PRs from other people's forks, whose head
    /// ref is just the fork's branch name ("main", "patch-1", …), and silently
    /// opening a stranger's PR is worse than not finding one. Empty on any
    /// malformed shape.
    static func parseForgejoPullRequests(_ data: Data, forge: ForgeRepo,
                                         headBranch: String) -> [PullRequest] {
        struct Entry: Decodable {
            let number: Int
            let title: String?
            let head: Head?
            struct Head: Decodable {
                let ref: String?
                let repo: Repo?
                struct Repo: Decodable { let full_name: String? }
            }
        }
        let expected = "\(forge.owner)/\(forge.repo)".lowercased()
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            guard entry.head?.ref == headBranch,
                  entry.head?.repo?.full_name?.lowercased() == expected else { return nil }
            return PullRequest(number: entry.number, title: entry.title ?? "",
                               url: forge.assumingForgejo().pullRequestURL(number: entry.number))
        }
    }

    /// Parses a GitLab v4 `GET /projects/…/merge_requests` array, verifying
    /// `source_branch` **and that the source project is this project** — the
    /// list includes MRs from forks targeting this repo, and the fork-collision
    /// guard mirrors the Forgejo parser's. Lenient when the project ids are
    /// absent, so an unexpected shape degrades to a branch-name match instead
    /// of dropping valid hits. The web URL uses the project-scoped `iid`,
    /// **not** the global `id`. Empty on any malformed shape.
    static func parseGitLabMergeRequests(_ data: Data, forge: ForgeRepo,
                                         headBranch: String) -> [PullRequest] {
        struct Entry: Decodable {
            let iid: Int
            let title: String?
            let source_branch: String?
            let source_project_id: Int?
            let target_project_id: Int?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            guard entry.source_branch == headBranch else { return nil }
            if let source = entry.source_project_id, let target = entry.target_project_id,
                source != target {
                return nil
            }
            return PullRequest(number: entry.iid, title: entry.title ?? "",
                               url: forge.assumingGitLab().pullRequestURL(number: entry.iid))
        }
    }
}
