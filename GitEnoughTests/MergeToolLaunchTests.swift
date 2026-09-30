import XCTest
@testable import GitEnough

/// The `--no-prompt` half of this change had no executable coverage: the matrix
/// justifying the flag lived only in a comment above `runMergeTool`, and the
/// symptom of losing it is "press the merge button, nothing happens" — no error,
/// no hang, no red test anywhere.
///
/// It is load-bearing *because* of this PR. Before every git child got
/// `/dev/null`, dropping the flag meant a visible hang on the launching
/// terminal's tty; now it means a silent skip.
final class MergeToolLaunchTests: XCTestCase {

    /// With `mergetool.prompt = true`, `git mergetool` asks "Hit return to start
    /// merge resolution tool" before launching — and reading EOF from
    /// `/dev/null` makes it skip the file entirely. `--no-prompt` is what stops
    /// that. Measured against git 2.43 with a tool that records its own launch:
    ///
    ///     prompt=true, --no-prompt   → exit 1, tool launched
    ///     prompt=true, no flag       → exit 1, tool NEVER launched
    ///
    /// **The exit code is identical in both rows**, which is why this asserts on
    /// a marker file the tool creates rather than on `runMergeTool` throwing.
    /// A test keyed on the error would pass with the flag removed.
    func testAToolIsLaunchedEvenWhenMergetoolPromptIsOn() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-mergetool-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) throws {
            _ = try GitShell.shared.runChecked(["-C", directory.path] + args, in: nil)
        }

        _ = try GitShell.shared.runChecked(["init", "-b", "main", directory.path], in: nil)
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test User"])
        try git(["config", "commit.gpgsign", "false"])
        try "one\n".write(to: directory.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        try git(["add", "a.txt"])
        try git(["commit", "-m", "base"])
        try git(["checkout", "-b", "other"])
        try "other\n".write(to: directory.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        try git(["commit", "-am", "other"])
        try git(["checkout", "main"])
        try "main\n".write(to: directory.appendingPathComponent("a.txt"),
                           atomically: true, encoding: .utf8)
        try git(["commit", "-am", "main"])
        // Conflicts, so `runChecked` would throw — the merge is the fixture, not
        // an assertion, so it goes through `run`.
        _ = try GitShell.shared.run(["-C", directory.path, "merge", "other"], in: nil)

        let client = GitClient(worktree: directory)
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"],
                       "precondition: the fixture merge really conflicts")

        // A tool that records that it ran and resolves nothing. The marker path
        // is a UUID under the system temp directory, so single quotes are enough
        // shell quoting for it; it cannot itself contain one.
        let marker = directory.appendingPathComponent("tool-was-launched")
        try git(["config", "mergetool.faketool.cmd", "touch '\(marker.path)'"])
        try git(["config", "mergetool.prompt", "true"])

        // Off the main thread with a deadline: if a regression ever restores the
        // blocking behaviour — this flag gone *and* the null stdin with it —
        // this fails in 30 s instead of wedging CI until the job times out.
        let finished = expectation(description: "git mergetool returned")
        var thrown: Error?
        DispatchQueue.global().async {
            do { try client.runMergeTool("faketool", path: "a.txt") }
            catch { thrown = error }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the tool was never launched — the silent-skip row of the "
                      + "matrix, which is what --no-prompt exists to prevent")
        // Secondary, and deliberately not the discriminator: a tool that leaves
        // the file unmerged makes `git mergetool` exit 1, so the user gets an
        // error banner rather than a false "resolved". Both rows of the matrix
        // exit 1, so this alone would not catch a dropped flag.
        XCTAssertNotNil(thrown, "an unresolved file must surface as an error")
    }
}
