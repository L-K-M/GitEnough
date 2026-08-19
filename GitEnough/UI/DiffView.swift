import SwiftUI
import AppKit

/// Renders a unified diff as colored, monospaced, horizontally scrollable lines.
///
/// The parse is memoized: the view model publishes fresh snapshots every few
/// seconds while the repo is dirty, and each publish re-evaluates the parent's
/// `body` — parsing up to 4,000 diff lines on every one of those is the main
/// scroll-stutter source in the app. We parse once per diff string instead.
struct DiffView: View {

    let diff: String

    /// Memoized parse, keyed on the diff string.
    ///
    /// A reference type held in `@State`, rather than the parse result itself:
    /// SwiftUI rebuilds the `DiffView` *value* on every parent `body` pass, so
    /// anything computed in an initializer is recomputed each time and then
    /// discarded (`State(initialValue:)` loses to the already-stored state of a
    /// mounted view). One instance per view identity survives those rebuilds,
    /// and reading through it in `body` keeps the lines and `diff` consistent
    /// without the extra frame of lag a state write would introduce.
    @State private var cache = ParseCache()

    var body: some View {
        let lines = cache.lines(for: diff)
        if diff.isEmpty {
            EmptyPane(systemImage: "doc.text.magnifyingglass",
                      title: "No diff",
                      subtitle: "Select a file to see its changes.")
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    /// Holds the most recent parse. Read and written only from `body`, which
    /// SwiftUI evaluates on the main thread; being a plain class, mutating it
    /// publishes nothing and so can't invalidate the view that reads it.
    private final class ParseCache {

        private var key: String?
        private var parsed: [DiffLine] = []

        func lines(for diff: String) -> [DiffLine] {
            if key == diff { return parsed }
            let lines = DiffParser.parse(diff)
            key = diff
            parsed = lines
            return lines
        }
    }
}

private struct DiffLineView: View {

    let line: DiffLine

    var body: some View {
        lineText
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .textSelection(.enabled)
    }

    /// The line as one (possibly concatenated) Text. Emphasized words — the
    /// intraline changes computed by the parser — render bold + underlined.
    private var lineText: Text {
        let content = line.text.isEmpty ? " " : line.text
        let ranges = line.emphasizedRanges.sorted { $0.lowerBound < $1.lowerBound }
        guard !ranges.isEmpty else { return Text(content) }
        var pieces: [Text] = []
        var cursor = content.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                pieces.append(Text(content[cursor..<range.lowerBound]))
            }
            pieces.append(Text(content[range]).bold().underline())
            cursor = range.upperBound
        }
        if cursor < content.endIndex {
            pieces.append(Text(content[cursor...]))
        }
        return pieces.reduce(Text(""), +)
    }

    private var foreground: Color {
        switch line.kind {
        case .fileHeader: return .primary
        case .hunk: return Color(nsColor: .systemIndigo)
        case .addition: return Color(nsColor: .systemGreen)
        case .deletion: return Color(nsColor: .systemRed)
        case .context: return .secondary
        case .meta: return Color(nsColor: .systemGray)
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return Color(nsColor: .systemGreen).opacity(0.10)
        case .deletion: return Color(nsColor: .systemRed).opacity(0.10)
        case .hunk: return Color(nsColor: .systemIndigo).opacity(0.08)
        default: return .clear
        }
    }
}
