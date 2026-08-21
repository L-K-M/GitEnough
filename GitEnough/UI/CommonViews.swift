import SwiftUI
import AppKit

/// One place for the clear-then-write pasteboard dance every Copy action does.
/// Main-actor like every other AppKit touchpoint in the views. setString's
/// Bool is discarded deliberately: a string write to a private pasteboard
/// can't meaningfully fail, and CommonViewsTests pins the contract.
extension NSPasteboard {
    @MainActor
    func copyString(_ text: String) {
        clearContents()
        _ = setString(text, forType: .string)
    }
}

/// A small ref chip for the history list: branch heads, remote branches, tags, HEAD.
struct RefChip: View {

    let decoration: RefDecoration

    private var label: String {
        switch decoration.kind {
        case .head: return "HEAD"
        case .localBranch, .remoteBranch, .tag: return decoration.name
        }
    }

    private var icon: String? {
        switch decoration.kind {
        case .head: return nil
        case .localBranch: return "arrow.triangle.branch"
        case .remoteBranch: return "network"
        case .tag: return "tag"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(label)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(background)
        .foregroundStyle(foreground)
        .clipShape(Capsule())
    }

    private var background: Color {
        switch decoration.kind {
        case .head: return Color.accentColor.opacity(0.25)
        case .localBranch: return Color.accentColor.opacity(0.15)
        case .remoteBranch: return Color.secondary.opacity(0.15)
        case .tag: return Color.yellow.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch decoration.kind {
        case .head: return .accentColor
        case .localBranch: return .accentColor
        case .remoteBranch: return .secondary
        case .tag: return .orange
        }
    }
}

/// The one/two-letter status badge on a changed-file row (A, M, D, R, ?).
struct FileStatusBadge: View {

    let status: FileChange.Status

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .frame(width: 16)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .added, .untracked: return .green
        case .modified, .typeChanged: return .orange
        case .deleted: return .red
        case .renamed, .copied: return .blue
        case .unmerged: return .purple
        }
    }
}

/// A timestamp rendered relative ("17 minutes ago"), with the absolute date as tooltip.
struct RelativeDateText: View {

    let date: Date?

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        if let date {
            Text(Self.formatter.localizedString(for: date, relativeTo: Date()))
                .help(date.formatted(date: .long, time: .shortened))
        } else {
            Text("—")
        }
    }
}

/// Centered placeholder for empty panes.
struct EmptyPane: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
