import Foundation

/// The folder name `git clone` would derive for a clone URL: the last path
/// component with a `.git` suffix stripped (`https://host/owner/repo.git` →
/// `repo`). Handles the scp-like SSH form (`git@github.com:owner/repo.git`),
/// where a naive split on `/` yields the whole colon-joined string instead of
/// the repository name. Pure — covered by unit tests.
struct CloneURL {

    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The suggested clone destination folder name, or nil when no sensible
    /// name can be derived (empty/whitespace-only URL, or a `.`/`..` component
    /// that would escape the chosen destination folder).
    var suggestedFolderName: String? {
        var url = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }

        // scp-like remotes carry no scheme; git recognizes them by a colon
        // before any slash (`git@host:owner/repo.git`, `host:repo`). The path
        // starts after that colon. Everything else — https://, ssh://, or a
        // plain local path — is split on slashes directly.
        if !url.contains("://"),
           let colon = url.firstIndex(of: ":"),
           url.firstIndex(of: "/").map({ colon < $0 }) ?? true {
            url = String(url[url.index(after: colon)...])
        }

        // git strips a trailing "/.git" component and names the folder after
        // what precedes it (cloning "…/repo/.git" — a bare-repo URL — lands in
        // "repo", not in an empty name).
        var components = url.components(separatedBy: "/")
        if components.last == ".git", components.count > 1 {
            components.removeLast()
        }

        guard let last = components.last else { return nil }
        // hasSuffix guarantees >= 4 characters, so dropLast(4) is safe.
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        // "." and ".." would resolve outside the chosen destination folder;
        // git refuses to guess a name for these too.
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return name
    }
}
