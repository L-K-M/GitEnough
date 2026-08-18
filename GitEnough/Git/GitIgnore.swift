import Foundation

/// Pure helpers for appending literal paths to a `.gitignore` file (used by
/// `RepoViewModel.ignore`). Kept side-effect free so the unit tests can cover
/// the pattern/dedup rules exhaustively; callers own the file I/O.
enum GitIgnore {

    /// gitignore entries are glob patterns — escape the metacharacters so a
    /// file literally named "report[1].txt" matches itself, not "report1.txt".
    static func escape(_ path: String) -> String {
        path.map { "\\*?[]".contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    /// The .gitignore content after ignoring `path` (the entry is anchored to
    /// the repo root with a leading slash). Returns the input unchanged when
    /// an equivalent entry already exists.
    static func appending(_ path: String, to existing: String) -> String {
        let escaped = escape(path)
        let lines = existing.components(separatedBy: .newlines)
            // gitignore itself ignores unescaped trailing whitespace and CR.
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
        let candidates = [path, "/" + path, escaped, "/" + escaped]
        guard !candidates.contains(where: { lines.contains($0) }) else { return existing }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + "/" + escaped + "\n"
    }
}
