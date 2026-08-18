import Foundation

/// The app-wide, persistent git command history — "shell history" for every
/// repository GitEnough has driven. Each repo's `GitActivityLog` forwards its
/// lifecycle events here (wired by AppState); the store keeps a running in-memory
/// list (including currently executing commands) and appends finished commands
/// to a JSONL file under Application Support, so the history survives relaunches.
///
/// Mutation and file I/O happen on one serial queue; the view observes the
/// `@Published` snapshot on main. Persistence is best-effort diagnostics —
/// write failures are swallowed, never surfaced to the user.
final class GitActivityStore: ObservableObject {

    /// One recorded invocation plus the repo it belonged to.
    ///
    /// Persisted as one JSON object per line. When this shape changes, bump
    /// `schemaVersion` and migrate in `loadFromDiskLocked` — every line is
    /// decoded with `try?`, so without a migration an incompatible change
    /// silently discards the whole history.
    struct Item: Identifiable, Equatable, Codable {
        /// Persisted schema version — bump when the on-disk shape changes.
        static let schemaVersion = 1

        let entry: GitActivityLog.Entry
        let repoName: String
        let repoPath: String

        var id: UUID { entry.id }
    }

    /// All known items, oldest first (running commands included).
    @Published private(set) var items: [Item] = []

    private let fileURL: URL
    private let capacity: Int
    private let ioQueue = DispatchQueue(label: "gitenough.activitystore", qos: .utility)
    private var storage: [Item] = []

    /// ~/Library/Application Support/GitEnough/git-activity.jsonl
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitEnough", isDirectory: true)
            .appendingPathComponent("git-activity.jsonl")
    }

    init(fileURL: URL = GitActivityStore.defaultFileURL, capacity: Int = 1000) {
        self.fileURL = fileURL
        self.capacity = capacity
        ioQueue.async { [weak self] in self?.loadFromDiskLocked() }
    }

    /// Records a lifecycle event from a repo's activity log. Called from repo
    /// queues; hops to the store's own serial queue.
    func record(_ event: GitActivityLog.Event, repoName: String, repoPath: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            switch event {
            case .began(let entry):
                self.storage.append(Item(entry: entry, repoName: repoName, repoPath: repoPath))
                self.trim()
            case .finished(let entry):
                let item = Item(entry: entry, repoName: repoName, repoPath: repoPath)
                if let index = self.storage.lastIndex(where: { $0.id == entry.id }) {
                    self.storage[index] = item
                } else {
                    // Defensive: a finish without its begin (shouldn't happen).
                    self.storage.append(item)
                }
                self.appendToDisk(item)
                self.trim()
            }
            self.publish()
        }
    }

    /// Removes all in-memory and on-disk history (the privacy escape hatch —
    /// argv text and stderr tails persist in plaintext otherwise).
    func clear() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.storage.removeAll()
            self.uncompactedOverflow = 0
            try? FileManager.default.removeItem(at: self.fileURL)
            self.publish()
        }
    }

    // MARK: - Persistence (ioQueue only)

    /// Synchronous from the caller's perspective but serialized on ioQueue, so
    /// tests (and any future caller) can't race the initializer's queued load.
    func loadFromDisk() {
        ioQueue.sync { self.loadFromDiskLocked() }
    }

    /// Must run on ioQueue. Bad lines are skipped, only the newest `capacity`
    /// survive.
    private func loadFromDiskLocked() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded: [Item] = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Item.self, from: Data(line.utf8))
        }
        storage = loaded.suffix(capacity).map { $0 }
        publish()
    }

    private func appendToDisk(_ item: Item) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard var line = try? encoder.encode(item) else { return }
        line.append(0x0A) // \n
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Create-only when missing; never truncate an existing file — if it
        // exists but can't be opened, skip (persistence is best-effort).
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? line.write(to: fileURL, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// Keeps the newest `capacity` finished items on disk (running items are
    /// in-memory only). Rewrites the whole file — called rarely, off main.
    private func compactDisk() {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let finished = storage.filter { !$0.entry.isRunning }.suffix(capacity)
        let data = finished.compactMap { try? encoder.encode($0) }
            .reduce(Data()) { $0 + $1 + Data([0x0A]) }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic: a crash mid-rewrite must not leave a truncated history.
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Appended-since-last-compaction count. Compaction rewrites the whole
    /// file, so it runs in batches — `loadFromDiskLocked`'s suffix(capacity)
    /// keeps memory bounded while the file runs slightly over.
    private var uncompactedOverflow = 0

    /// Must run on ioQueue. Drops oldest finished items beyond capacity
    /// (running items are never dropped); compacts the file in batches.
    private func trim() {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        var dropped = 0
        while storage.count > capacity,
              let victim = storage.firstIndex(where: { !$0.entry.isRunning }) {
            storage.remove(at: victim)
            dropped += 1
        }
        uncompactedOverflow += dropped
        if uncompactedOverflow >= 50 {
            compactDisk()
            uncompactedOverflow = 0
        }
    }

    private func publish() {
        let snapshot = storage
        if Thread.isMainThread {
            items = snapshot
        } else {
            DispatchQueue.main.async { self.items = snapshot }
        }
    }

    /// Blocks until everything enqueued so far has been processed. Tests use
    /// it to make `record` calls deterministic.
    func flushForTesting() {
        ioQueue.sync { }
    }

    // MARK: - Filtering (pure)

    /// The window's search: free text over command, stderr, and repo name,
    /// optionally narrowed to one repo and/or to failed commands.
    static func filtered(_ items: [Item],
                         query: String,
                         repoPath: String?,
                         failuresOnly: Bool) -> [Item] {
        let needle = query.lowercased()
        return items.filter { item in
            if failuresOnly, item.entry.isRunning || item.entry.exitCode == 0 { return false }
            if let repoPath, item.repoPath != repoPath { return false }
            guard !needle.isEmpty else { return true }
            return item.entry.command.lowercased().contains(needle)
                || (item.entry.stderrTail?.lowercased().contains(needle) ?? false)
                || item.repoName.lowercased().contains(needle)
        }
    }
}
