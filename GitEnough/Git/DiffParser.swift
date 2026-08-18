import Foundation

/// One display line of a unified diff, classified for coloring. For paired
/// deletion/addition lines, `emphasizedRanges` marks the changed words within the
/// line (GitHub-style intraline highlighting); empty when nothing is emphasized.
struct DiffLine: Equatable {
    enum Kind: Equatable {
        case fileHeader   // diff --git, index, ---/+++ paths
        case hunk         // @@ … @@
        case addition
        case deletion
        case context
        case meta         // new file mode, Binary files …, \ No newline
    }

    let kind: Kind
    let text: String
    var emphasizedRanges: [Range<String.Index>] = []
}

enum DiffParser {

    /// Classifies unified-diff output into display lines. Very large diffs are
    /// capped to keep the UI responsive; a synthetic note line marks the cutoff.
    static func parse(_ diff: String, maxLines: Int = 4000) -> [DiffLine] {
        var lines: [DiffLine] = []
        lines.reserveCapacity(min(diff.count / 40, maxLines + 1))
        var count = 0
        for rawLine in diff.components(separatedBy: "\n") {
            if count >= maxLines {
                lines.append(DiffLine(kind: .meta, text: "… diff truncated after \(maxLines) lines …"))
                break
            }
            count += 1
            let kind: DiffLine.Kind
            if rawLine.hasPrefix("diff --git") || rawLine.hasPrefix("index ")
                || rawLine.hasPrefix("---") || rawLine.hasPrefix("+++")
                || rawLine.hasPrefix("old mode") || rawLine.hasPrefix("new mode")
                || rawLine.hasPrefix("similarity index") || rawLine.hasPrefix("rename from")
                || rawLine.hasPrefix("rename to") || rawLine.hasPrefix("copy from")
                || rawLine.hasPrefix("copy to") {
                kind = .fileHeader
            } else if rawLine.hasPrefix("@@") {
                kind = .hunk
            } else if rawLine.hasPrefix("+") {
                kind = .addition
            } else if rawLine.hasPrefix("-") {
                kind = .deletion
            } else if rawLine.hasPrefix("new file mode") || rawLine.hasPrefix("deleted file mode")
                        || rawLine.hasPrefix("Binary files") || rawLine.hasPrefix("GIT binary patch")
                        || rawLine.hasPrefix("\\") || rawLine.hasPrefix("Submodule") {
                kind = .meta
            } else {
                kind = .context
            }
            lines.append(DiffLine(kind: kind, text: rawLine))
        }
        return emphasizeIntralineChanges(lines)
    }

    // MARK: - Intraline (word-level) emphasis

    /// For each run of deletions directly followed by a run of additions (git's
    /// standard shape for a changed block), the k-th deletion is paired with the
    /// k-th addition and the changed words in each pair are emphasized. A
    /// trim-the-ends heuristic on whitespace-delimited tokens: identical leading
    /// and trailing words are left plain, the middle is emphasized. Imperfect for
    /// reordered text — like every diff UI short of a full diff algorithm — but
    /// right for the common edited-word case, and it never emphasizes the +/-
    /// prefix column.
    private static func emphasizeIntralineChanges(_ lines: [DiffLine]) -> [DiffLine] {
        var result = lines
        var index = 0
        while index < result.count {
            guard result[index].kind == .deletion else {
                index += 1
                continue
            }
            var deletions: [Int] = []
            while index < result.count, result[index].kind == .deletion {
                deletions.append(index)
                index += 1
            }
            var additions: [Int] = []
            while index < result.count, result[index].kind == .addition {
                additions.append(index)
                index += 1
            }
            guard !additions.isEmpty else { continue }
            for pair in 0..<min(deletions.count, additions.count) {
                let (oldRanges, newRanges) = changedWordRanges(
                    old: result[deletions[pair]].text,
                    new: result[additions[pair]].text)
                result[deletions[pair]].emphasizedRanges = oldRanges
                result[additions[pair]].emphasizedRanges = newRanges
            }
        }
        return result
    }

    /// Ranges of the changed words in a paired -/+ line, or empty arrays when the
    /// lines' word content is identical. Ranges cover the *whole* line including
    /// the +/- prefix, but the prefix is skipped for comparison and never lands
    /// inside a returned range (it always trims away as the common prefix).
    private static func changedWordRanges(old: String, new: String)
        -> ([Range<String.Index>], [Range<String.Index>]) {
        // Substrings share the parent string's indices, so token ranges map
        // straight back onto the original line.
        let oldTokens = wordTokens(of: old.dropFirst())   // drop the '-' prefix
        let newTokens = wordTokens(of: new.dropFirst())    // drop the '+' prefix

        var start = 0
        while start < oldTokens.count, start < newTokens.count,
              oldTokens[start].text == newTokens[start].text {
            start += 1
        }
        var oldEnd = oldTokens.count
        var newEnd = newTokens.count
        while oldEnd > start, newEnd > start,
              oldTokens[oldEnd - 1].text == newTokens[newEnd - 1].text {
            oldEnd -= 1
            newEnd -= 1
        }
        guard oldEnd > start || newEnd > start else { return ([], []) }

        func span(of tokens: [(text: Substring, range: Range<String.Index>)],
                  from: Int, to: Int) -> [Range<String.Index>] {
            guard from < to else { return [] }
            return [tokens[from].range.lowerBound..<tokens[to - 1].range.upperBound]
        }
        return (span(of: oldTokens, from: start, to: oldEnd),
                span(of: newTokens, from: start, to: newEnd))
    }

    /// Maximal runs of non-whitespace, and runs of whitespace, each as one token.
    /// Takes the content substring (the line minus its +/- prefix), whose indices
    /// map straight back onto the original line.
    private static func wordTokens(of line: Substring)
        -> [(text: Substring, range: Range<String.Index>)] {
        var tokens: [(text: Substring, range: Range<String.Index>)] = []
        var index = line.startIndex
        while index < line.endIndex {
            let tokenIsWhitespace = line[index].isWhitespace
            var end = line.index(after: index)
            while end < line.endIndex, line[end].isWhitespace == tokenIsWhitespace {
                end = line.index(after: end)
            }
            tokens.append((line[index..<end], index..<end))
            index = end
        }
        return tokens
    }
}
