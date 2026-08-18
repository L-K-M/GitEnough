import Foundation

/// Where a repository is hosted on a "forge" (GitHub, GitLab, Forgejo/Gitea, …),
/// parsed from a git remote URL — plus the per-forge website URL shapes that
/// GitEnough deep-links into (a PR's page, the "create a PR" compare page).
/// Pure and side-effect free so it can be exhaustively unit-tested.
///
/// Accepted remote URL forms:
///
///     https://github.com/owner/repo.git        http://host:3000/owner/repo
///     ssh://git@host:2222/owner/repo.git       git@github.com:owner/repo.git
///
/// `owner` keeps nested group segments (GitLab's group/subgroup) joined with
/// "/", and `owner`/`repo` are percent-encoded path segments, so every URL
/// built from them is valid by construction. A port is kept only for http(s)
/// remotes — an ssh port addresses the shell, not the website. Local paths and
/// URLs without an owner/repo path parse to nil.
struct ForgeRepo: Equatable {

    enum Kind: Equatable {
        case github      // github.com — REST API at api.github.com, PRs at /pull/N
        case gitlab      // gitlab.com — merge requests at /-/merge_requests/N
        case forgejo     // a host that answered the Forgejo/Gitea API (PullRequestFinder)
        case generic     // any other host — GitHub-style paths as a best guess
    }

    let kind: Kind
    /// Website origin of the forge: scheme + host (+ port for http(s) remotes).
    let origin: URL
    /// Percent-encoded path segments of the owner, "/"-joined ("group/sub").
    let owner: String
    /// Percent-encoded repository name, without a ".git" suffix.
    let repo: String

    // MARK: - Parsing

    static func parse(remoteURL: String) -> ForgeRepo? {
        let raw = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let scheme: String       // scheme of the *website* URL to build
        var host: Substring      // hostname, any user@ already dropped
        var port: Substring?
        var path: Substring

        if let marker = raw.range(of: "://") {
            let name = raw[..<marker.lowerBound].lowercased()
            // Only git/http transports; anything else (file:, ftp:, …) is no forge.
            guard ["http", "https", "ssh", "git"].contains(name) else { return nil }
            let rest = raw[marker.upperBound...]
            var authority = rest
            path = ""
            if let slash = rest.firstIndex(of: "/") {
                authority = rest[..<slash]
                path = rest[rest.index(after: slash)...]
            }
            if let at = authority.lastIndex(of: "@") {
                authority = authority[authority.index(after: at)...]
            }
            scheme = name == "http" ? "http" : "https"
            let split = Self.splitHostPort(authority)
            host = split.host
            if name == "http" || name == "https" {
                port = split.port   // a web port serves the website too — keep it
            }
            // For ssh/git transports the port addresses the daemon, not the
            // website, so it's dropped.
        } else {
            // scp-like form (git@host:owner/repo.git). Told apart from a plain
            // local path by the mandatory user@host prefix before the first
            // colon — a colon alone also occurs in ordinary paths ("C:\x").
            guard let colon = raw.firstIndex(of: ":"),
                  let at = raw[..<colon].lastIndex(of: "@"),
                  at != raw.startIndex else { return nil }
            host = raw[raw.index(after: at)..<colon]
            port = nil
            path = raw[raw.index(after: colon)...]
            scheme = "https"
        }

        // ASCII hostnames only — no IDN/punycode translation happens here, and
        // anything else (brackets, colons, spaces) can't be a forge host.
        guard !host.isEmpty,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = String(host)
        if let port, let value = Int(port), (1..<65_536).contains(value) {
            components.port = value
        }
        guard let origin = components.url else { return nil }

        // owner/[nested/]repo path segments; the repo drops a ".git" suffix.
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { Self.encodePath($0) }
        guard segments.count >= 2 else { return nil }
        var repo = segments[segments.count - 1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !repo.isEmpty else { return nil }
        let owner = segments.dropLast().joined(separator: "/")
        guard !owner.isEmpty else { return nil }

        let kind: Kind = host == "github.com" ? .github
            : host == "gitlab.com" ? .gitlab
            : .generic
        return ForgeRepo(kind: kind, origin: origin, owner: owner, repo: repo)
    }

    /// Splits "host" / "host:port" (port digits only). A trailing non-numeric
    /// ":something" is left in `host`, where the character validation above
    /// rejects it — failing the whole parse, as intended.
    private static func splitHostPort(_ authority: Substring) -> (host: Substring, port: Substring?) {
        guard let colon = authority.lastIndex(of: ":") else { return (authority, nil) }
        let candidate = authority[authority.index(after: colon)...]
        guard !candidate.isEmpty, candidate.allSatisfy(\.isNumber) else { return (authority, nil) }
        return (authority[..<colon], candidate)
    }

    // MARK: - Website URLs

    /// The repository's home page on the forge.
    var webURL: URL { page("/\(owner)/\(repo)") }

    /// The web page of one pull request (a "merge request" on GitLab).
    func pullRequestURL(number: Int) -> URL {
        switch kind {
        case .github, .generic:
            return page("/\(owner)/\(repo)/pull/\(number)")
        case .forgejo:
            return page("/\(owner)/\(repo)/pulls/\(number)")
        case .gitlab:
            return page("/\(owner)/\(repo)/-/merge_requests/\(number)")
        }
    }

    /// The forge's "create a pull request" page for merging `head` into `base`.
    /// When a PR is already open, GitHub and Forgejo show an "already has a pull
    /// request" banner on this very page — the offline fallback for private
    /// repos where the API lookup can't see anything.
    func newPullRequestURL(base: String, head: String) -> URL {
        switch kind {
        case .github, .forgejo, .generic:
            // GitHub and Forgejo/Gitea share the /compare/base...head shape;
            // expand=1 opens GitHub's PR form directly (Forgejo shows one anyway).
            return page("/\(owner)/\(repo)/compare/\(Self.encodePath(base))...\(Self.encodePath(head))",
                        query: "expand=1")
        case .gitlab:
            return page("/\(owner)/\(repo)/-/merge_requests/new",
                        query: "merge_request%5Bsource_branch%5D=\(Self.encodeQuery(head))"
                            + "&merge_request%5Btarget_branch%5D=\(Self.encodeQuery(base))")
        }
    }

    /// A copy with the kind forced to Forgejo — used once a self-hosted host has
    /// answered the Forgejo/Gitea API, so PR URLs take the /pulls/ shape.
    func assumingForgejo() -> ForgeRepo {
        ForgeRepo(kind: .forgejo, origin: origin, owner: owner, repo: repo)
    }

    // MARK: - URL assembly

    /// Appends a (pre-encoded) path and optional pre-encoded query to `origin`.
    /// Every caller passes pieces through the encode helpers below, so this
    /// can't fail; `origin` is the graceful fallback if it somehow does.
    private func page(_ path: String, query: String? = nil) -> URL {
        var text = origin.absoluteString + path
        if let query { text += "?" + query }
        return URL(string: text) ?? origin
    }

    /// Percent-encodes a path component. "/" passes through — branch names may
    /// contain it; owner/repo segments never do (they were split on "/" first).
    private static func encodePath(_ value: some StringProtocol) -> String {
        String(value).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    }

    /// Percent-encodes a query value; "&", "=" and "+" would otherwise act as
    /// query delimiters.
    private static func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
                .subtracting(CharacterSet(charactersIn: "&=+")))
            ?? ""
    }
}
