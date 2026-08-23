import Foundation

/// Pure helpers for appending literal paths to a `.gitignore` file (used by
/// `RepoViewModel.ignore`). Kept side-effect free so the unit tests can cover
/// the pattern/dedup rules exhaustively; callers own the file I/O.
enum GitIgnore {

    /// gitignore entries are glob patterns — escape everything that would
    /// keep the line from matching the literal path:
    /// - `* ? [ ] \` are glob metacharacters;
    /// - a leading `#` would read as a comment, a leading `!` as a negation;
    /// - trailing spaces are stripped by git unless escaped.
    static func escape(_ path: String) -> String {
        let trailingWhitespaceStart = path.lastIndex(where: { $0 != " " && $0 != "\t" })
            .map { path.index(after: $0) } ?? path.startIndex
        var escaped = ""
        escaped.reserveCapacity(path.count)

        for index in path.indices {
            let character = path[index]
            let isLeadingMarker = index == path.startIndex
                && (character == "#" || character == "!")
            let isTrailingWhitespace = index >= trailingWhitespaceStart
                && (character == " " || character == "\t")
            if isLeadingMarker || isTrailingWhitespace || "\\*?[]".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// The .gitignore content after ignoring `path` (the entry is anchored to
    /// the repo root with a leading slash). Returns the input unchanged when
    /// an equivalent entry already exists.
    static func appending(_ path: String, to existing: String) -> String {
        let escaped = escape(path)
        // Only the escaped pattern is guaranteed to mean this literal path.
        // For a plain path `escaped == path`, while raw glob metacharacters or
        // trailing whitespace have different gitignore semantics and must not
        // suppress the literal rule.
        let candidates = [escaped, "/" + escaped]
        let duplicates = existing.components(separatedBy: .newlines)
            .map(strippingTrailingUnescapedWhitespace)
            // Comment and negation lines can never ignore a path, so they
            // must not suppress the append (a file may literally be named
            // "#notes.md" or "!keep.txt").
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("!") }
            .contains { candidates.contains($0) }
        guard !duplicates else { return existing }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + "/" + escaped + "\n"
    }

    /// git ignores unescaped trailing whitespace in patterns (and nothing
    /// else) — mirror exactly that for the duplicate comparison, so a line
    /// like " /build" (leading space is significant) can't false-positive,
    /// and an escaped trailing space ("foo\ ") survives the trim.
    private static func strippingTrailingUnescapedWhitespace(_ line: String) -> String {
        var result = line
        while result.count > 1, result.hasSuffix(" ") || result.hasSuffix("\t") {
            if result.hasSuffix("\\ ") || result.hasSuffix("\\\t") { break }
            result = String(result.dropLast())
        }
        return result
    }
}
