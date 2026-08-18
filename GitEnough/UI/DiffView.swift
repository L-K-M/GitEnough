import SwiftUI
import AppKit

/// Renders a unified diff as colored, monospaced, horizontally scrollable lines.
///
/// The parse is memoized in view state: the view model publishes fresh
/// snapshots every few seconds while the repo is dirty, and each publish
/// rebuilds this view — parsing up to 4,000 diff lines inline in `body` on
/// every one of those evaluations is the main scroll-stutter source in the
/// app. We parse once per diff string instead.
struct DiffView: View {

    let diff: String

    @State private var parsedLines: [DiffLine]
    @State private var parsedDiff: String

    init(diff: String) {
        self.diff = diff
        _parsedDiff = State(initialValue: diff)
        _parsedLines = State(initialValue: DiffParser.parse(diff))
    }

    var body: some View {
        Group {
            if diff.isEmpty {
                EmptyPane(systemImage: "doc.text.magnifyingglass",
                          title: "No diff",
                          subtitle: "Select a file to see its changes.")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, line in
                            DiffLineView(line: line)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onChange(of: diff) { _, newDiff in
            // Only re-parse when the diff actually changed, not on every
            // unrelated snapshot publish.
            guard newDiff != parsedDiff else { return }
            parsedDiff = newDiff
            parsedLines = DiffParser.parse(newDiff)
        }
    }
}

private struct DiffLineView: View {

    let line: DiffLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .textSelection(.enabled)
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
