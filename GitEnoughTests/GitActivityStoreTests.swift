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
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { done.fulfill() }
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

    func testCapacityKeepsNewestAndCompactsFile() throws {
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
