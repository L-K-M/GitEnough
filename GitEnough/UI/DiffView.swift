import SwiftUI
import AppKit

/// Renders a unified diff as colored, monospaced, horizontally scrollable lines.
struct DiffView: View {

    let diff: String

    var body: some View {
        if diff.isEmpty {
            EmptyPane(systemImage: "doc.text.magnifyingglass",
                      title: "No diff",
                      subtitle: "Select a file to see its changes.")
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(DiffParser.parse(diff).enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
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
