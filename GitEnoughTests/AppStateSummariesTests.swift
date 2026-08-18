import XCTest
@testable import GitEnough

/// Tests for the windowed-concurrent sidebar summary computation.
final class AppStateSummariesTests: XCTestCase {

    func testSummariesCoverValidAndMissingRepos() async throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }

        // A real repo (reusing the integration-test setup shape, minimal).
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughSummaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        _ = try GitShell.shared.runChecked(
            ["init", "-b", "main"], in: repoURL)
        _ = try GitShell.shared.runChecked(
            ["config", "user.email", "test@example.com"], in: repoURL)
        _ = try GitShell.shared.runChecked(
            ["config", "user.name", "Test User"], in: repoURL)
        try "one\n".write(to: repoURL.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        _ = try GitShell.shared.runChecked(["add", "a.txt"], in: repoURL)
        _ = try GitShell.shared.runChecked(["commit", "-m", "Initial commit"], in: repoURL)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughSummaries-missing-\(UUID().uuidString)")

        let repos = [
            Repository(path: repoURL.path, name: repoURL.lastPathComponent),
            Repository(path: missing.path, name: "missing"),
        ]

        let summaries = await AppState.summaries(for: repos, maxConcurrent: 1)

        XCTAssertEqual(summaries.count, 2)
        let valid = try XCTUnwrap(summaries[repoURL.path])
        XCTAssertEqual(valid.branch, "main")
        XCTAssertTrue(valid.isValid)
        XCTAssertFalse(valid.isDirty)

        let invalid = try XCTUnwrap(summaries[missing.path])
        XCTAssertFalse(invalid.isValid)
        XCTAssertNil(invalid.branch)
    }
}
