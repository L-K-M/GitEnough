import XCTest
@testable import GitEnough

/// The persistent, app-wide command history: event recording, JSONL
/// persistence across "relaunches", capacity compaction, and the window's
/// search/filter logic.
final class GitActivityStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughStoreTests-\(UUID().uuidString)")
            .appendingPathComponent("git-activity.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeStore(capacity: Int = 1000) -> GitActivityStore {
        GitActivityStore(fileURL: fileURL, capacity: capacity)
    }

    private func entry(_ command: String, exitCode: Int32? = 0) -> GitActivityLog.Entry {
        var entry = GitActivityLog.Entry(id: UUID(), command: command,
                                         startedAt: Date(), finishedAt: nil,
                                         exitCode: nil, stderrTail: nil)
        if let exitCode {
            entry.markFinished(at: Date().addingTimeInterval(0.5),
                               exitCode: exitCode,
                               stderrTail: exitCode == 0 ? nil : "boom")
        }
        return entry
    }

    /// Waits until the store's ioQueue has processed everything enqueued so
    /// far, then lets the main runloop deliver the published snapshot.
    private func drain(_ store: GitActivityStore) {
        store.flushForTesting()
        let done = expectation(description: "publish delivered")
        // Main queue is FIFO: this runs after any publish already enqueued
        // by the flush above, so `items` is current when wait() returns.
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: - Recording

    func testRecordBeganThenFinishedProducesOneFinishedItem() throws {
        let store = makeStore()
        let running = entry("fetch --prune", exitCode: nil)
        store.record(.began(running), repoName: "Repo", repoPath: "/tmp/repo")
        var finished = running
        finished.markFinished(at: Date(), exitCode: 0, stderrTail: nil)
        store.record(.finished(finished), repoName: "Repo", repoPath: "/tmp/repo")
        drain(store)
        let items = store.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.entry.isRunning, false)
        XCTAssertEqual(items.first?.entry.exitCode, 0)
        XCTAssertEqual(items.first?.repoName, "Repo")
    }

    // MARK: - Persistence

    func testFinishedItemsSurviveARelaunch() throws {
        let store = makeStore()
        store.record(.finished(entry("push")), repoName: "A", repoPath: "/a")
        store.record(.finished(entry("commit -F -")), repoName: "B", repoPath: "/b")
        drain(store)

        // A "relaunch": a new store over the same file loads what was written.
        let reloaded = makeStore()
        reloaded.loadFromDisk()
        XCTAssertEqual(reloaded.items.map(\.entry.command), ["push", "commit -F -"])
        XCTAssertEqual(reloaded.items.map(\.repoName), ["A", "B"])
    }

    func testStructuredArgumentsSurviveARelaunch() throws {
        let store = makeStore()
        let recorded = GitActivityLog.Entry(
            id: UUID(), command: "stash push -m \"wip: fix it\"",
            startedAt: Date(), finishedAt: Date(), exitCode: 0, stderrTail: nil,
            arguments: ["stash", "push", "-m", "wip: fix it"])
        store.record(.finished(recorded), repoName: "A", repoPath: "/a")
        drain(store)

        let reloaded = makeStore()
        reloaded.loadFromDisk()
        XCTAssertEqual(reloaded.items.first?.entry.arguments,
                       ["stash", "push", "-m", "wip: fix it"])
    }

    func testRunningItemsAreNotPersisted() throws {
        let store = makeStore()
        store.record(.began(entry("stuck-command", exitCode: nil)),
                       repoName: "A", repoPath: "/a")
        store.record(.finished(entry("done-command")), repoName: "A", repoPath: "/a")
        drain(store)
        let reloaded = makeStore()
        reloaded.loadFromDisk()
        XCTAssertEqual(reloaded.items.map(\.entry.command), ["done-command"])
    }

    func testCapacityKeepsNewestInMemoryAndOnReload() throws {
        let store = makeStore(capacity: 3)
        for i in 0..<5 {
            store.record(.finished(entry("cmd\(i)")), repoName: "A", repoPath: "/a")
        }
        drain(store)
        XCTAssertEqual(store.items.map(\.entry.command), ["cmd2", "cmd3", "cmd4"])
        let reloaded = makeStore(capacity: 3)
        reloaded.loadFromDisk()
        XCTAssertEqual(reloaded.items.map(\.entry.command), ["cmd2", "cmd3", "cmd4"])
    }

    func testClearEmptiesMemoryAndDisk() throws {
        let store = makeStore()
        store.record(.finished(entry("push")), repoName: "A", repoPath: "/a")
        drain(store)
        XCTAssertEqual(store.items.count, 1)
        store.clear()
        drain(store)
        XCTAssertTrue(store.items.isEmpty)
        let reloaded = makeStore()
        reloaded.loadFromDisk()
        XCTAssertTrue(reloaded.items.isEmpty)
    }

    // MARK: - On-disk permissions

    /// The history holds every git argv the app has run plus the stderr tail of
    /// every failure. It must not be readable by other accounts on the machine,
    /// and it has three chances to become so: creation, append, and the atomic
    /// compaction — whose rename makes a *new* inode and is the one that
    /// regresses.
    func testHistoryFileIsOwnerOnlyThroughCreationAppendAndCompaction() throws {
        // capacity 1 so every record after the first drops one item; the store
        // compacts once 50 have been dropped.
        let store = makeStore(capacity: 1)

        store.record(.finished(entry("status")), repoName: "Repo", repoPath: "/tmp/repo")
        drain(store)
        XCTAssertEqual(try mode(of: fileURL), 0o600, "mode at creation")
        XCTAssertEqual(try mode(of: fileURL.deletingLastPathComponent()), 0o700,
                       "the directory holding it — an atomic rewrite's temp file "
                       + "lives here and carries no mode of its own")

        store.record(.finished(entry("fetch")), repoName: "Repo", repoPath: "/tmp/repo")
        drain(store)
        XCTAssertEqual(try mode(of: fileURL), 0o600, "mode after an append")

        for index in 0..<60 {
            store.record(.finished(entry("log \(index)")),
                         repoName: "Repo", repoPath: "/tmp/repo")
        }
        drain(store)
        XCTAssertEqual(try mode(of: fileURL), 0o600, "mode after compaction")
    }

    /// A mode the user set by hand must *survive* compaction, not merely stay
    /// below the floor — the rename replaces the inode, so the mode has to be
    /// read before the rewrite and restored after it. Asserted as equality on
    /// purpose: `<= 0o600` would pass for an implementation that silently
    /// re-opened a frozen file for writing.
    func testCompactionPreservesAManuallyTightenedMode() throws {
        let store = makeStore(capacity: 1)
        store.record(.finished(entry("status")), repoName: "Repo", repoPath: "/tmp/repo")
        drain(store)
        try FileManager.default.setAttributes([.posixPermissions: 0o400],
                                              ofItemAtPath: fileURL.path)

        for index in 0..<60 {
            store.record(.finished(entry("log \(index)")),
                         repoName: "Repo", repoPath: "/tmp/repo")
        }
        drain(store)
        XCTAssertEqual(try mode(of: fileURL), 0o400,
                       "compaction must neither widen nor round up a frozen file")
    }

    /// An upgrade has to heal what an older build left behind.
    ///
    /// Nothing else would: the create branch never runs again for an existing
    /// file, and compaction only fires once fifty entries have been evicted —
    /// so the users with the longest history would keep a world-readable one
    /// the longest. `createDirectory`'s attributes are no help either; they
    /// apply only when it actually creates the directory.
    func testRecordingTightensAHistoryLeftLooseByAnOlderBuild() throws {
        let store = makeStore()
        store.record(.finished(entry("status")), repoName: "Repo", repoPath: "/tmp/repo")
        drain(store)

        // Put the file and its directory back the way an older build left them.
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: fileURL.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fileURL.deletingLastPathComponent().path)

        store.record(.finished(entry("fetch")), repoName: "Repo", repoPath: "/tmp/repo")
        drain(store)

        XCTAssertEqual(try mode(of: fileURL), 0o600, "the file heals on the next append")
        XCTAssertEqual(try mode(of: fileURL.deletingLastPathComponent()), 0o700,
                       "and so does the directory that covers the compaction temp file")
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    // MARK: - Filtering

    private var sampleItems: [GitActivityStore.Item] {
        [
            .init(entry: entry("push"), repoName: "Alpha", repoPath: "/repos/alpha"),
            .init(entry: entry("commit -F -", exitCode: 1), repoName: "Beta", repoPath: "/repos/beta"),
            .init(entry: entry("fetch --prune"), repoName: "Alpha", repoPath: "/repos/alpha"),
        ]
    }

    func testFilterByFreeTextMatchesCommandStderrAndRepo() {
        XCTAssertEqual(GitActivityStore.filtered(sampleItems, query: "push",
                                                 repoPath: nil, failuresOnly: false).count, 1)
        // stderr of the failed commit is "boom"
        XCTAssertEqual(GitActivityStore.filtered(sampleItems, query: "boom",
                                                 repoPath: nil, failuresOnly: false).count, 1)
        XCTAssertEqual(GitActivityStore.filtered(sampleItems, query: "alpha",
                                                 repoPath: nil, failuresOnly: false).count, 2)
    }

    func testFilterByRepoAndFailuresOnly() {
        XCTAssertEqual(GitActivityStore.filtered(sampleItems, query: "",
                                                 repoPath: "/repos/alpha",
                                                 failuresOnly: false).count, 2)
        let failures = GitActivityStore.filtered(sampleItems, query: "",
                                                 repoPath: nil, failuresOnly: true)
        XCTAssertEqual(failures.map(\.entry.command), ["commit -F -"])
    }
}
