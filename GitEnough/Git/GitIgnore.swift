import Foundation

/// Pure helpers for appending literal paths to a `.gitignore` file (used by
/// `RepoViewModel.ignore`). Kept side-effect free so the unit tests can cover
/// the pattern/dedup rules exhaustively; callers own the file I/O.
public enum GitIgnore {

    /// gitignore entries are glob patterns — escape everything that would
    /// keep the line from matching the literal path:
    /// - `* ? [ ] \` are glob metacharacters;
    /// - a leading `#` would read as a comment, a leading `!` as a negation;
    /// - trailing spaces are stripped by git unless escaped.
    public static func escape(_ path: String) -> String {
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
    public static func appending(_ path: String, to existing: String) -> String {
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

    /// The bytes a caller must append to a file currently holding `existing` in
    /// order to reach `appending(path, to: existing)`. Empty when the rule is
    /// already covered.
    ///
    /// This exists so the difference is taken in **bytes**, once, here. Deriving
    /// it from Character counts is wrong in a way that is easy to miss and
    /// destructive when it happens: `appending` returns `existing` plus a tail,
    /// but the two can disagree on Character count at the join. An existing file
    /// ending in a bare CR gains the separator "\n", and CR + LF is a single
    /// grapheme cluster — so the result has one Character *fewer* at that point
    /// than `existing` does, and `updated.dropFirst(existing.count)` drops the
    /// separator along with it. The file becomes "a\r/x\n": the previous rule
    /// destroyed, the new one matching nothing, and the caller reporting success.
    /// The slicing happens on the UTF-8 *view* rather than on a materialized
    /// `Data`, so the result is a fresh zero-based `Data` rather than a slice
    /// whose `startIndex` is the byte count of `existing`. Both are equally
    /// correct to append, but a slice traps on `addition[0]` — no caller does
    /// that today, and none should have to know not to.
    public static func appendedBytes(_ path: String, to existing: String) -> Data {
        let updated = appending(path, to: existing)
        // The whole function is a byte offset into `updated`, and that offset
        // is only meaningful while `appending` returns `existing` unchanged at
        // the front. Nothing else enforces it, and a future edit there —
        // normalizing line endings, trimming trailing space, re-escaping the
        // existing text — would slice at the wrong place and hand the caller
        // garbage to append to the user's file. Debug-only, but loud.
        assert(updated.utf8.starts(with: existing.utf8),
               "appending(_:to:) must return `existing` as a byte-for-byte prefix")
        return Data(updated.utf8.dropFirst(existing.utf8.count))
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
