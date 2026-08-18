import Foundation

/// A rolling, thread-safe log of recent git invocations for one repository —
/// the answer to "the spinner is spinning, but WHAT is it doing?". Every
/// GitClient call for the repo records a begin/finish pair here; the status
/// bar shows the currently running command with a live timer, and a popover
/// lists recent commands with durations and (on failure) their stderr, which
/// is where hook output like a stuck `npm run lint` shows up.
///
/// All mutations funnel through a lock because reads (e.g. the merge-tool
/// runner) can happen off the repo's serial queue. `onChange` fires after
/// every mutation with a consistent snapshot; observers typically hop to main.
final class GitActivityLog {

    /// One git invocation. Stdin content (commit messages via `commit -F -`)
    /// is deliberately NOT captured — only argv and a stderr tail.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        /// The command as displayed, e.g. `commit -F -` or `fetch --prune --all`
        /// (the leading `-C <worktree>` is stripped; the repo is implied).
        let command: String
        let startedAt: Date
        private(set) var finishedAt: Date?
        private(set) var exitCode: Int32?
        /// Last chunk of stderr — hook diagnostics and git's error messages.
        private(set) var stderrTail: String?

        var isRunning: Bool { finishedAt == nil }
        var succeeded: Bool { exitCode == 0 }
    }

    /// Called after every begin/finish, on the mutating thread, OUTSIDE the
    /// lock (so observers can safely re-enter, e.g. read `entries`).
    var onChange: (([Entry]) -> Void)?

    private let capacity: Int
    private let lock = NSLock()
    private var storage: [Entry] = []

    init(capacity: Int = 100) {
        self.capacity = capacity
    }

    /// Current entries in chronological order (oldest first).
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func begin(command: String, at now: Date = Date()) -> UUID {
        let entry = Entry(id: UUID(), command: command, startedAt: now,
                          finishedAt: nil, exitCode: nil, stderrTail: nil)
        lock.lock()
        storage.append(entry)
        trimLocked()
        let snapshot = storage
        lock.unlock()
        onChange?(snapshot)
        return entry.id
    }

    func finish(_ id: UUID, exitCode: Int32?, stderr: String?, at now: Date = Date()) {
        lock.lock()
        guard let index = storage.lastIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        storage[index].finishedAt = now
        storage[index].exitCode = exitCode
        let tail = stderr.map(Self.stderrTail)?.trimmingCharacters(in: .whitespacesAndNewlines)
        storage[index].stderrTail = (tail?.isEmpty ?? true) ? nil : tail
        let snapshot = storage
        lock.unlock()
        onChange?(snapshot)
    }

    /// Must be called with the lock held. Drops oldest finished entries;
    /// running entries are never evicted, wherever they sit (they're the
    /// whole point — a stuck command must stay visible).
    private func trimLocked() {
        while storage.count > capacity,
              let victim = storage.firstIndex(where: { !$0.isRunning }) {
            storage.remove(at: victim)
        }
    }

    private static func stderrTail(_ stderr: String) -> String {
        stderr.count <= 4000 ? stderr : String(stderr.suffix(4000))
    }

    // MARK: - Command formatting

    /// Renders an argv array for display: strips the leading `-C <worktree>`
    /// every GitClient call starts with, redacts credentials embedded in URLs,
    /// and quotes arguments containing whitespace.
    static func displayCommand(for args: [String]) -> String {
        var argv = args
        if argv.count >= 2, argv[0] == "-C" {
            argv.removeFirst(2)
        }
        return argv.map(displayArgument).joined(separator: " ")
    }

    private static func displayArgument(_ arg: String) -> String {
        // https://token@host/… or https://user:pass@host/… → https://***@host/…
        let redacted = arg.replacingOccurrences(of: #"://[^/\s@]+@"#,
                                                with: "://***@",
                                                options: .regularExpression)
        if redacted.contains(where: { $0 == " " || $0 == "\t" }) {
            return "\"\(redacted)\""
        }
        return redacted
    }
}
