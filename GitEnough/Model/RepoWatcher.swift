import Foundation

/// Cheap change detection for a repository: polls the mtimes of the handful of
/// `.git` files that change whenever HEAD, the index, refs, or the merge state
/// move. When the signature changes, it fires `onChange` so the view model can
/// refresh — no FSEvents, no full `git status` on every tick.
final class RepoWatcher {

    private let gitDir: URL
    private let worktree: URL
    private let onEvent: () -> Void
    private var timer: DispatchSourceTimer?
    private var lastSignature: String = ""

    /// - Parameter interval: poll interval in seconds.
    init(gitDir: URL, worktree: URL, queue: DispatchQueue, interval: TimeInterval = 2.5,
         onEvent: @escaping () -> Void) {
        self.gitDir = gitDir
        self.worktree = worktree
        self.onEvent = onEvent
        lastSignature = Self.signature(gitDir: gitDir, worktree: worktree)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }

    private func tick() {
        let signature = Self.signature(gitDir: gitDir, worktree: worktree)
        if signature != lastSignature {
            lastSignature = signature
            onEvent()
        }
    }

    /// Re-baselines the signature so a change the app itself just made (and
    /// already snapshotted) doesn't trip the watcher into a redundant second
    /// full refresh one poll later: `RepoViewModel.perform` ends with a fresh
    /// snapshot, and its git commands dirty exactly the files this watcher
    /// polls. Must be called on the timer's queue (the repo's serial queue),
    /// so it serializes with ticks.
    func restamp() {
        lastSignature = Self.signature(gitDir: gitDir, worktree: worktree)
    }

    /// Modification times of the git-dir files that signal "something changed".
    /// Includes the worktree root's mtime (catches top-level adds/removes; deeper
    /// edits are picked up by the view model's activation refresh).
    private static func signature(gitDir: URL, worktree: URL) -> String {
        let watched = [
            "HEAD", "index", "packed-refs", "FETCH_HEAD", "MERGE_HEAD", "ORIG_HEAD",
            "COMMIT_EDITMSG", "refs", "refs/heads", "refs/tags", "refs/remotes",
            "logs/HEAD",
        ]
        var parts: [String] = []
        for relative in watched {
            let url = gitDir.appendingPathComponent(relative)
            if let mtime = modificationTime(of: url) {
                parts.append("\(relative)=\(mtime)")
            }
        }
        if let mtime = modificationTime(of: worktree) {
            parts.append("worktree=\(mtime)")
        }
        return parts.joined(separator: "|")
    }

    private static func modificationTime(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return nil }
        return Int(date.timeIntervalSince1970 * 1000)
    }
}
