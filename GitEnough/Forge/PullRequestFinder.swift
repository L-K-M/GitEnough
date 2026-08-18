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
/// - **anything else** → a Forgejo/Gitea API attempt (`/api/v1/…`); a host that
///   doesn't answer it simply yields no result.
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
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
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
        case .forgejo, .generic:
            // Self-hosted hosts are usually Forgejo/Gitea — trying its API is
            // both the probe and the lookup in one request.
            return await findOnForgejo(forge, headBranch: headBranch)
        case .gitlab:
            return nil // no unauthenticated lookup; callers open the MR page
        }
    }

    private func findOnGitHub(_ forge: ForgeRepo, headBranch: String) async -> PullRequest? {
        guard let url = Self.gitHubLookupURL(forge, headBranch: headBranch),
              let data = await get(url) else { return nil }
        return Self.parseGitHubPullRequests(data, forge: forge).first
    }

    private func findOnForgejo(_ forge: ForgeRepo, headBranch: String) async -> PullRequest? {
        guard let url = Self.forgejoLookupURL(forge),
              let data = await get(url) else { return nil }
        return Self.parseForgejoPullRequests(data, forge: forge, headBranch: headBranch).first
    }

    /// GET returning the body only for HTTP 200. Sends a User-Agent — the
    /// GitHub API rejects requests without one.
    private func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("GitEnough", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Endpoint building (pure)

    /// `https://api.github.com/repos/{owner}/{repo}/pulls?state=open&head={owner}:{branch}`
    /// — the head filter restricts the answer to PRs from this repo's branch.
    static func gitHubLookupURL(_ forge: ForgeRepo, headBranch: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(forge.owner)/\(forge.repo)/pulls"
            + "?state=open&head=\(forge.owner):\(encodeQuery(headBranch))")
    }

    /// `{origin}/api/v1/repos/{owner}/{repo}/pulls?state=open&limit=50` — the
    /// Forgejo/Gitea pulls endpoint; matching by head ref happens after
    /// parsing (the API has no head filter parameter).
    static func forgejoLookupURL(_ forge: ForgeRepo) -> URL? {
        URL(string: forge.origin.absoluteString
            + "/api/v1/repos/\(forge.owner)/\(forge.repo)/pulls?state=open&limit=50")
    }

    private static func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
                .subtracting(CharacterSet(charactersIn: "&=+")))
            ?? ""
    }

    // MARK: - Response parsing (pure)

    /// Parses a GitHub `GET /repos/…/pulls` array (only `number` and `title`
    /// are needed — the URL is built from the forge, not from `html_url`).
    /// Empty on any malformed shape (GitHub error bodies are JSON objects).
    static func parseGitHubPullRequests(_ data: Data, forge: ForgeRepo) -> [PullRequest] {
        struct Entry: Decodable {
            let number: Int
            let title: String?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.map {
            PullRequest(number: $0.number, title: $0.title ?? "",
                        url: forge.pullRequestURL(number: $0.number))
        }
    }

    /// Parses a Forgejo/Gitea `GET /repos/…/pulls` array, keeping only PRs
    /// whose head ref is `headBranch`. Empty on any malformed shape.
    static func parseForgejoPullRequests(_ data: Data, forge: ForgeRepo,
                                         headBranch: String) -> [PullRequest] {
        struct Entry: Decodable {
            let number: Int
            let title: String?
            let head: Head?
            struct Head: Decodable { let ref: String? }
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            guard entry.head?.ref == headBranch else { return nil }
            return PullRequest(number: entry.number, title: entry.title ?? "",
                               url: forge.assumingForgejo().pullRequestURL(number: entry.number))
        }
    }
}
