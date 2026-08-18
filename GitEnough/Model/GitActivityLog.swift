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
    /// is deliberately NOT captured — only argv and a stderr tail. Note that
    /// free text passed as an argument (e.g. `stash push -m <message>`) IS
    /// part of argv and therefore appears in `command`.
    /// Codable so the global history store can persist finished entries.
    struct Entry: Identifiable, Equatable, Codable {
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
        /// False while the entry is still running — check `isRunning` first.
        var succeeded: Bool { exitCode == 0 }

        /// Setters are private to Entry, so the log transitions entries through
        /// this instead of poking properties directly.
        mutating func markFinished(at date: Date, exitCode: Int32?, stderrTail: String?) {
            finishedAt = date
            self.exitCode = exitCode
            self.stderrTail = stderrTail
        }
    }

    /// Lifecycle events for observers that maintain their own derived state
    /// (the global activity-history store). Fired after `onChange`, on the
    /// mutating thread, outside the lock.
    enum Event {
        case began(Entry)
        case finished(Entry)
    }

    /// Called after every begin/finish, on the mutating thread, OUTSIDE the
    /// lock (so observers can safely re-enter, e.g. read `entries`).
    var onChange: (([Entry]) -> Void)?

    /// Called once per lifecycle transition, same threading as `onChange`.
    var onEvent: ((Event) -> Void)?

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
        onEvent?(.began(entry))
        return entry.id
    }

    func finish(_ id: UUID, exitCode: Int32?, stderr: String?, at now: Date = Date()) {
        lock.lock()
        guard let index = storage.lastIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        // stderr can echo a remote URL on network errors — redact before storing.
        let redacted = stderr.map(Self.redactCredentials)
        let tail = redacted.map(Self.stderrTail)?.trimmingCharacters(in: .whitespacesAndNewlines)
        storage[index].markFinished(at: now, exitCode: exitCode,
                                    stderrTail: (tail?.isEmpty ?? true) ? nil : tail)
        let updated = storage[index]
        let snapshot = storage
        lock.unlock()
        onChange?(snapshot)
        onEvent?(.finished(updated))
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
        // Read-only probes pass `--no-optional-locks` before the subcommand;
        // strip it so the display leads with the command name (`status …`).
        argv.removeAll { $0 == "--no-optional-locks" }
        return argv.map(displayArgument).joined(separator: " ")
    }

    /// https://token@host/… or https://user:pass@host/… → https://***@host/…
    /// Both argv and stderr (network errors echo remote URLs) go through this.
    static func redactCredentials(_ string: String) -> String {
        string.replacingOccurrences(of: #"://[^/\s@]+@"#,
                                    with: "://***@",
                                    options: .regularExpression)
    }

    private static func displayArgument(_ arg: String) -> String {
        let redacted = redactCredentials(arg)
        if redacted.contains(where: { $0 == " " || $0 == "\t" }) {
            return "\"\(redacted)\""
        }
        return redacted
    }
}
