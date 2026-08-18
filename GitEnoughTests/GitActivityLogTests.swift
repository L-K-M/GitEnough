import XCTest
@testable import GitEnough

/// The activity log is what turns "the spinner is stuck" into "ah, the
/// pre-commit hook has been running npm for three minutes" — so its begin/
/// finish pairing, eviction policy, stderr tail, and command redaction are
/// pinned down here.
final class GitActivityLogTests: XCTestCase {

    // MARK: - begin / finish

    func testBeginProducesRunningEntry() {
        let log = GitActivityLog()
        log.begin(command: "fetch --prune --all")
        let entry = log.entries.first
        XCTAssertEqual(entry?.command, "fetch --prune --all")
        XCTAssertEqual(entry?.isRunning, true)
        XCTAssertNil(entry?.exitCode)
    }

    func testFinishSetsExitCodeAndStopsRunning() {
        let log = GitActivityLog()
        let id = log.begin(command: "push")
        log.finish(id, exitCode: 0, stderr: "")
        let entry = log.entries.first
        XCTAssertEqual(entry?.isRunning, false)
        XCTAssertEqual(entry?.succeeded, true)
        XCTAssertEqual(entry?.exitCode, 0)
    }

    func testFinishRecordsStderrTailForFailures() {
        let log = GitActivityLog()
        let id = log.begin(command: "commit -F -")
        log.finish(id, exitCode: 1, stderr: "husky - pre-commit script failed\n")
        XCTAssertEqual(log.entries.first?.stderrTail, "husky - pre-commit script failed")
    }

    func testBlankStderrIsNotStored() {
        let log = GitActivityLog()
        let id = log.begin(command: "status")
        log.finish(id, exitCode: 0, stderr: "  \n")
        XCTAssertNil(log.entries.first?.stderrTail)
    }

    func testStderrIsTruncatedToTail() {
        let log = GitActivityLog()
        let id = log.begin(command: "commit -F -")
        let huge = String(repeating: "x", count: 5000)
        log.finish(id, exitCode: 1, stderr: huge)
        XCTAssertEqual(log.entries.first?.stderrTail?.count, 4000)
    }

    func testFinishUnknownIDIsIgnored() {
        let log = GitActivityLog()
        log.begin(command: "status")
        log.finish(UUID(), exitCode: 1, stderr: "nope")
        XCTAssertEqual(log.entries.first?.isRunning, true)
    }

    // MARK: - Capacity

    func testOldestFinishedEntriesAreEvictedBeyondCapacity() {
        let log = GitActivityLog(capacity: 3)
        for i in 0..<5 {
            let id = log.begin(command: "cmd\(i)")
            log.finish(id, exitCode: 0, stderr: nil)
        }
        XCTAssertEqual(log.entries.map(\.command), ["cmd2", "cmd3", "cmd4"])
    }

    func testRunningEntriesAreNeverEvicted() {
        let log = GitActivityLog(capacity: 2)
        log.begin(command: "stuck-hook")          // stays running
        for i in 0..<4 {
            let id = log.begin(command: "cmd\(i)")
            log.finish(id, exitCode: 0, stderr: nil)
        }
        XCTAssertTrue(log.entries.contains { $0.command == "stuck-hook" && $0.isRunning })
    }

    // MARK: - onChange

    func testOnChangeFiresWithSnapshots() {
        let log = GitActivityLog()
        var snapshots: [[GitActivityLog.Entry]] = []
        log.onChange = { snapshots.append($0) }
        let id = log.begin(command: "fetch")
        log.finish(id, exitCode: 0, stderr: nil)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.first?.first?.isRunning, true)
        XCTAssertEqual(snapshots.last?.first?.isRunning, false)
    }

    // MARK: - displayCommand

    func testDisplayCommandStripsLeadingWorktreeSwitch() {
        XCTAssertEqual(
            GitActivityLog.displayCommand(for: ["-C", "/Users/x/repo", "fetch", "--prune"]),
            "fetch --prune")
    }

    func testDisplayCommandQuotesArgumentsWithSpaces() {
        XCTAssertEqual(
            GitActivityLog.displayCommand(for: ["stash", "push", "-m", "wip: fix it"]),
            "stash push -m \"wip: fix it\"")
    }

    func testDisplayCommandRedactsURLCredentials() {
        XCTAssertEqual(
            GitActivityLog.displayCommand(for: ["clone", "https://token123@github.com/a/b.git"]),
            "clone https://***@github.com/a/b.git")
        XCTAssertEqual(
            GitActivityLog.displayCommand(for: ["clone", "https://user:p%40ss@gitlab.com/a/b.git"]),
            "clone https://***@gitlab.com/a/b.git")
    }

    func testDisplayCommandLeavesPlainArgumentsAlone() {
        XCTAssertEqual(
            GitActivityLog.displayCommand(for: ["checkout", "main"]),
            "checkout main")
    }
}
