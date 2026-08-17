import Foundation

/// One display line of a unified diff, classified for coloring.
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
        return lines
    }
}
