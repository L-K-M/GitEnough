import Foundation
import SwiftUI

/// Popover listing a repo's recent git invocations (newest first): what ran,
/// how long it took, whether it failed, and — for failures — the stderr tail
/// where hook output and git's own diagnostics live. The currently running
/// command gets a spinner and a live-updating elapsed timer, so a stuck hook
/// (e.g. a pre-commit running the full test suite) is immediately visible
/// instead of looking like a dead spinner.
struct ActivityLogView: View {
    /// Chronological order (oldest first), as stored by GitActivityLog.
    let entries: [GitActivityLog.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent git activity")
                .font(.headline)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 6)
            if entries.isEmpty {
                Text("No git commands yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries.reversed()) { entry in
                    row(for: entry)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 480, height: 340)
    }

    private func row(for entry: GitActivityLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                statusIcon(for: entry)
                Text("git \(entry.command)")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                durationLabel(for: entry)
            }
            if let stderr = entry.stderrTail, entry.exitCode != 0 {
                DisclosureGroup("Output") {
                    Text(stderr)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(for entry: GitActivityLog.Entry) -> some View {
        if entry.isRunning {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        } else if entry.succeeded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func durationLabel(for entry: GitActivityLog.Entry) -> some View {
        if entry.isRunning {
            // Counts up once per second while the entry stays on screen.
            Text(entry.startedAt, style: .timer)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else if let finished = entry.finishedAt {
            Text(Self.formatDuration(finished.timeIntervalSince(entry.startedAt)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes)m \(rest)s"
    }
}
