#if !SWIFT_PACKAGE && canImport(AppKit)
import XCTest
@testable import GitEnough

final class HistorySelectionModelTests: XCTestCase {
    private func makeRepository() throws -> (URL, String, String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughHistorySelection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let shell = GitShell.shared
        _ = try shell.run(["init", "-b", "main"], in: url)
        _ = try shell.run(["config", "user.name", "History Selection Test"], in: url)
        _ = try shell.run(["config", "user.email", "history@example.invalid"], in: url)
        let file = url.appendingPathComponent("notes.txt")
        try "First version\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try shell.run(["add", "notes.txt"], in: url)
        _ = try shell.run(["-c", "commit.gpgsign=false", "commit", "-m", "First"], in: url)
        let first = try shell.run(["rev-parse", "HEAD"], in: url).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try "Second version\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try shell.run(["add", "notes.txt"], in: url)
        _ = try shell.run(["-c", "commit.gpgsign=false", "commit", "-m", "Second"], in: url)
        let second = try shell.run(["rev-parse", "HEAD"], in: url).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, first, second)
    }

    @MainActor
    private func drain(_ viewModel: RepoViewModel) {
        let done = expectation(description: "repository reads complete")
        viewModel.queue.async {
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testTwoWindowsKeepIndependentCommitDetailsAndDiffs() throws {
        let (url, first, second) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = RepoViewModel(repo: Repository(url: url))
        let left = HistorySelectionModel()
        let right = HistorySelectionModel()

        left.selectCommit(first, in: viewModel)
        right.selectCommit(second, in: viewModel)
        drain(viewModel)
        XCTAssertEqual(left.detail?.hash, first)
        XCTAssertEqual(right.detail?.hash, second)

        left.selectFile("notes.txt", hash: first, in: viewModel)
        right.selectFile("notes.txt", hash: second, in: viewModel)
        drain(viewModel)
        XCTAssertTrue(left.fileDiff.contains("+First version"))
        XCTAssertFalse(left.fileDiff.contains("+Second version"))
        XCTAssertTrue(right.fileDiff.contains("+Second version"))
    }

    @MainActor
    func testDeselectInvalidatesPendingDetailAndDiffReads() throws {
        let (url, first, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = RepoViewModel(repo: Repository(url: url))
        let selection = HistorySelectionModel()

        selection.selectCommit(first, in: viewModel)
        selection.selectFile("notes.txt", hash: first, in: viewModel)
        selection.selectCommit(nil, in: viewModel)
        drain(viewModel)
        XCTAssertNil(selection.detail)
        XCTAssertNil(selection.errorMessage)
        XCTAssertEqual(selection.fileDiff, "")
        XCTAssertFalse(selection.isLoading)
        XCTAssertFalse(selection.isLoadingFileDiff)
    }

    @MainActor
    func testRapidSelectionSkipsObsoleteQueuedDetailAndDiffReads() throws {
        let (url, first, second) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = RepoViewModel(repo: Repository(url: url))
        let blocked = expectation(description: "Earlier repository work holds the queue")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        viewModel.queue.async {
            blocked.fulfill()
            release.wait()
        }
        wait(for: [blocked], timeout: 5)

        let selection = HistorySelectionModel()
        selection.selectCommit(first, in: viewModel)
        selection.selectCommit(second, in: viewModel)
        selection.selectFile("notes.txt", hash: first, in: viewModel)
        selection.selectFile("notes.txt", hash: second, in: viewModel)
        release.signal()
        drain(viewModel)

        XCTAssertEqual(selection.detail?.hash, second)
        XCTAssertTrue(selection.fileDiff.contains("+Second version"))
        XCTAssertFalse(viewModel.activityLog.entries.contains {
            $0.arguments?.contains(first) == true
        }, "Obsolete inspection reads must not delay new work on the repository queue")
    }

    @MainActor
    func testFailedReadReportsAnErrorAndStopsLoading() throws {
        let (url, _, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = RepoViewModel(repo: Repository(url: url))
        let selection = HistorySelectionModel()

        selection.selectCommit(String(repeating: "0", count: 40), in: viewModel)
        drain(viewModel)
        XCTAssertNil(selection.detail)
        XCTAssertNotNil(selection.errorMessage)
        XCTAssertFalse(selection.isLoading)
    }
}
#endif
