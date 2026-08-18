import AppKit
import SwiftUI

/// The "shell history" window: every git command GitEnough has run for every
/// repository — searchable, filterable, persistent across launches. Selecting
/// an entry shows the full command, timing, exit code, and the stderr tail
/// (where hook output lives), with a Copy button for re-running it yourself.
struct ActivityHistoryView: View {

    @ObservedObject var store: GitActivityStore

    @State private var query = ""
    @State private var failuresOnly = false
    @State private var repoFilter: String? // nil = all repositories
    @State private var selection: UUID?
    @State private var confirmingClear = false

    private var filtered: [GitActivityStore.Item] {
        GitActivityStore.filtered(store.items, query: query,
                                  repoPath: repoFilter, failuresOnly: failuresOnly)
    }

    /// Repo filters are built from what actually appears in the history.
    private var knownRepos: [(name: String, path: String)] {
        var seen: [String: String] = [:] // path → name
        for item in store.items { seen[item.repoPath] = item.repoName }
        return seen.sorted { $0.value < $1.value }.map { (name: $0.value, path: $0.key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(
                    "No matching commands",
                    systemImage: "terminal",
                    description: Text(store.items.isEmpty
                        ? "Git commands run by GitEnough will appear here."
                        : "Try a different search or filter."))
            } else {
                List(filtered.reversed(), selection: $selection) { item in
                    row(for: item).tag(item.id)
                }
                .listStyle(.plain)
            }
            if let selected = selection,
               let item = store.items.first(where: { $0.id == selected }) {
                Divider()
                detail(for: item)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter commands, output, or repos…", text: $query)
                .textFieldStyle(.plain)
            Picker("Repository", selection: $repoFilter) {
                Text("All Repositories").tag(String?.none)
                ForEach(knownRepos, id: \.path) { repo in
                    Text(repo.name).tag(String?.some(repo.path))
                }
            }
            .fixedSize()
            Toggle("Failures only", isOn: $failuresOnly)
                .toggleStyle(.checkbox)
            Button("Clear History…") {
                confirmingClear = true
            }
            .disabled(store.items.isEmpty)
            .confirmationDialog(
                "Delete the recorded git activity for every repository? This cannot be undone.",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    selection = nil
                    store.clear()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Rows

    private func row(for item: GitActivityStore.Item) -> some View {
        HStack(spacing: 8) {
            statusIcon(for: item.entry)
            Text("git \(item.entry.command)")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.repoName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            Text(item.entry.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            durationLabel(for: item.entry)
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
            Text(entry.startedAt, style: .timer)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else if let finished = entry.finishedAt {
            Text(ActivityLogView.formatDuration(finished.timeIntervalSince(entry.startedAt)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func detailSubtitle(for item: GitActivityStore.Item) -> String {
        var text = "\(item.repoPath) — started "
            + item.entry.startedAt.formatted(date: .abbreviated, time: .standard)
        if item.entry.isRunning {
            text += " — still running"
        } else {
            text += " — exit code \(item.entry.exitCode ?? -1)"
        }
        return text
    }

    // MARK: - Detail

    private func detail(for item: GitActivityStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("git \(item.entry.command)")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("git \(item.entry.command)", forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .help("Copy the command to the clipboard")
            }
            Text(detailSubtitle(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let stderr = item.entry.stderrTail {
                ScrollView {
                    Text(stderr)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
    }
}
