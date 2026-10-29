import XCTest
@testable import GitEnough

final class SidebarSummaryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        guard GitShell.shared.isAvailable else { throw XCTSkip("git is not installed") }
        suite = "GitEnough.SidebarSummaryTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitShell.shared.runChecked(["init", "-b", "main"], in: root)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suite)
        if let root { try? FileManager.default.removeItem(at: root) }
        defaults = nil
        root = nil
        super.tearDown()
    }

    func testGroupingUsesOriginThenFirstRemoteWithoutNetworkRequests() async throws {
        let client = GitClient(worktree: root)
        _ = try GitShell.shared.runChecked(["remote", "add", "upstream", "https://gitlab.com/team/upstream.git"], in: root)
        let repo = Repository(url: root)
        let fallback = await AppState.summaries(for: [repo])
        XCTAssertEqual(fallback[repo.path]?.groupingRemoteURL, "https://gitlab.com/team/upstream.git")
        _ = try GitShell.shared.runChecked(["remote", "add", "origin", "git@github.com:owner/fork.git"], in: root)
        let origin = await AppState.summaries(for: [repo])
        XCTAssertEqual(origin[repo.path]?.groupingRemoteURL, "git@github.com:owner/fork.git")
        XCTAssertEqual(try client.remotes().count, 2)
    }

    func testBackgroundSummaryWaitsForTheRepositoryOperationQueue() throws {
        let repo = Repository(url: root)
        let model = RepoViewModel(repo: repo, defaults: defaults)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        model.queue.async { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        defer { release.signal(); model.queue.sync {} }
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        Task.detached {
            started.signal()
            _ = await AppState.summaries(for: [repo])
            finished.leave()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.2), .timedOut,
                       "Summary reads must not bypass an in-flight repository operation")
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }
}
