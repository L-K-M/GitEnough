import XCTest
@testable import GitEnough

/// End-to-end tests: build a real repository in a temp directory (with a branch
/// and a merge) and verify the GitClient + parsers against real git output.
final class GitIntegrationTests: XCTestCase {

    private var repoURL: URL!
    private var client: GitClient!

    override func setUpWithError() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }
        repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        client = GitClient(worktree: repoURL)

        try run(["init", "-b", "main"])
        try run(["config", "user.email", "test@example.com"])
        try run(["config", "user.name", "Test User"])
        try run(["config", "commit.gpgsign", "false"])

        // main: c1 → c3; feature: c2 branched from c1; then merged back.
        try write("one\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Initial commit"])

        try run(["checkout", "-b", "feature"])
        try write("two\n", to: "b.txt")
        try run(["add", "b.txt"])
        try run(["commit", "-m", "Add b on feature"])

        try run(["checkout", "main"])
        try write("three\n", to: "c.txt")
        try run(["add", "c.txt"])
        try run(["commit", "-m", "Add c on main"])

        try run(["merge", "--no-edit", "feature"])
    }

    override func tearDownWithError() throws {
        if let repoURL {
            try? FileManager.default.removeItem(at: repoURL)
        }
    }

    private func run(_ args: [String]) throws {
        _ = try GitShell.shared.runChecked(args, in: repoURL)
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: repoURL.appendingPathComponent(name),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - Tests

    func testStatusOnCleanMergedRepo() throws {
        let status = try client.status()
        XCTAssertEqual(status.head, "main")
        XCTAssertFalse(status.isDirty)
        XCTAssertTrue(status.conflicted.isEmpty)
        XCTAssertNil(status.upstream)
    }

    func testLogContainsMergeWithTwoParentsAndHeadDecoration() throws {
        let commits = try client.log(limit: 50)
        XCTAssertEqual(commits.count, 4) // c1, c2, c3, merge
        let merge = commits[0]
        XCTAssertTrue(merge.isMerge)
        XCTAssertEqual(merge.parents.count, 2)
        XCTAssertTrue(merge.isHead)
        XCTAssertTrue(merge.decorations.contains(RefDecoration(kind: .localBranch, name: "main")))
        // The merge's parents are c3 (main side) and c2 (feature side); both are in
        // the log exactly once.
        XCTAssertEqual(Set(commits.map(\.hash)).count, 4)
    }

    func testGraphLayoutOfMergeShape() throws {
        let commits = try client.log(limit: 50)
        let layout = GraphLayout.layout(commits: commits)
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.nodes.count, 4)
        XCTAssertTrue(layout.segments.contains { $0.kind == .branchOut })
        XCTAssertTrue(layout.segments.contains { $0.kind == .joinExisting })
    }

    func testBranchesList() throws {
        let branches = try client.branches()
        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(branches.first { $0.isHead }?.name, "main")
        XCTAssertNotNil(branches.first { $0.name == "feature" })
        XCTAssertTrue(branches.allSatisfy { !$0.isRemote })
    }

    func testModifyStageUnstageFlow() throws {
        try write("one\nchanged\n", to: "a.txt")
        var status = try client.status()
        XCTAssertEqual(status.unstaged.map(\.path), ["a.txt"])
        XCTAssertTrue(status.staged.isEmpty)

        try client.stage(paths: ["a.txt"])
        status = try client.status()
        XCTAssertEqual(status.staged.map(\.path), ["a.txt"])
        XCTAssertTrue(status.unstaged.isEmpty)

        try client.unstage(paths: ["a.txt"])
        status = try client.status()
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(status.unstaged.map(\.path), ["a.txt"])

        try client.discard(paths: ["a.txt"])
        status = try client.status()
        XCTAssertFalse(status.isDirty)
    }

    func testDiffRoundTrip() throws {
        try write("one\nchanged\n", to: "a.txt")
        let diff = try client.diff(path: "a.txt", staged: false)
        // "one" is unchanged (context); only "changed" is added.
        XCTAssertFalse(diff.contains("-one"))
        XCTAssertTrue(diff.contains("+changed"))
        let lines = DiffParser.parse(diff)
        XCTAssertFalse(lines.contains(DiffLine(kind: .deletion, text: "-one")))
        XCTAssertTrue(lines.contains(DiffLine(kind: .addition, text: "+changed")))
        XCTAssertTrue(lines.contains(DiffLine(kind: .context, text: " one")))
    }

    func testUntrackedDiffUsesNoIndex() throws {
        try write("brand new\n", to: "new.txt")
        let diff = try client.diffForUntracked(path: "new.txt")
        XCTAssertTrue(diff.contains("+brand new"))
    }

    func testCommitViaStdinMessage() throws {
        try write("four\n", to: "d.txt")
        try client.stage(paths: ["d.txt"])
        try client.commit(message: "Add d\n\n- with a body line")
        let commits = try client.log(limit: 5)
        XCTAssertEqual(commits[0].subject, "Add d")
        let status = try client.status()
        XCTAssertFalse(status.isDirty)
    }

    func testCommitDetailListsFiles() throws {
        let commits = try client.log(limit: 50)
        let merge = commits[0]
        let detail = try XCTUnwrap(try client.commitDetail(merge.hash))
        XCTAssertEqual(detail.hash, merge.hash)
        // Diff against the first parent adds b.txt.
        XCTAssertTrue(detail.files.contains(CommitFile(status: .added, path: "b.txt", originalPath: nil)))
    }

    func testStashLifecycle() throws {
        try write("dirty\n", to: "a.txt")
        try client.stashPush(message: "wip", includeUntracked: false)
        var status = try client.status()
        XCTAssertFalse(status.isDirty)

        let stash = try client.stashList()
        XCTAssertEqual(stash.count, 1)
        XCTAssertEqual(stash[0].message, "wip")
        XCTAssertEqual(stash[0].branch, "main")

        try client.stashApply(index: stash[0].index, pop: true)
        status = try client.status()
        XCTAssertEqual(status.unstaged.map(\.path), ["a.txt"])
        XCTAssertTrue(try client.stashList().isEmpty)
    }

    func testStashCommitsAreExcludedFromHistory() throws {
        let before = try client.log(limit: 50)
        XCTAssertEqual(before.count, 4)

        try write("dirty\n", to: "a.txt")
        try client.stashPush(message: "wip", includeUntracked: false)
        XCTAssertFalse(try client.stashList().isEmpty)
        defer { try? run(["stash", "drop", "stash@{0}"]) }

        // Stashing must not change the visible graph. Without --exclude=refs/stash,
        // --all leaks the stash's synthetic WIP/index commits as extra lanes.
        let after = try client.log(limit: 50)
        XCTAssertEqual(after.map(\.hash), before.map(\.hash))
    }

    func testSyntheticToolRefsAreExcludedFromHistory() throws {
        // A commit reachable ONLY through filter-branch-style backup refs, bisect
        // markers, prefetch refs, notes, and rewrite bookkeeping must not leak
        // into the graph — every hidden namespace gets covered.
        try run(["checkout", "-b", "scratch"])
        try write("scratch\n", to: "scratch.txt")
        try run(["add", "scratch.txt"])
        try run(["commit", "-m", "Scratch commit"])
        let scratchHash = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "rev-parse", "HEAD"], in: nil).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try run(["checkout", "-"])  // back to where we came from (main)
        try run(["branch", "-D", "scratch"])
        let hiddenRefs = ["refs/original/refs/heads/scratch",
                          "refs/bisect/bad",
                          "refs/prefetch/remotes/origin/main",
                          "refs/notes/commits",
                          "refs/rewritten/scratch"]
        // Register cleanup *before* creation so a mid-loop throw still unwinds.
        defer {
            for ref in hiddenRefs {
                try? run(["update-ref", "-d", ref])
            }
        }
        for ref in hiddenRefs {
            try run(["update-ref", ref, scratchHash])
        }

        let commits = try client.log(limit: 50)
        XCTAssertEqual(commits.count, 4)
        XCTAssertFalse(commits.contains { $0.hash == scratchHash })
    }

    func testMergeConflictDetectionAndOursResolution() throws {
        // Create a conflicting change on a second branch.
        try run(["checkout", "-b", "conflicter"])
        try write("from conflicter\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on conflicter"])
        try run(["checkout", "main"])
        try write("from main\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on main"])

        XCTAssertThrowsError(try client.merge("conflicter"))

        let mergeHead = try client.mergeHead()
        XCTAssertNotNil(mergeHead)
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"])

        let status = try client.status()
        XCTAssertEqual(status.conflicted.map(\.path), ["a.txt"])

        try client.resolveConflict(path: "a.txt", ours: true)
        try client.mergeContinue()

        XCTAssertNil(try client.mergeHead())
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "from main\n")
    }

    func testRemoteDefaultBranch() throws {
        // No remote yet — nothing to read.
        XCTAssertNil(client.remoteDefaultBranch(remote: "origin"))

        // Establish refs/remotes/origin/HEAD exactly like clone/fetch would.
        try run(["remote", "add", "origin", "https://example.com/acme/widget.git"])
        try run(["update-ref", "refs/remotes/origin/main", "refs/heads/main"])
        try run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])

        XCTAssertEqual(client.remoteDefaultBranch(remote: "origin"), "main")
        XCTAssertNil(client.remoteDefaultBranch(remote: "upstream"))
    }

    func testValidationHelpers() throws {
        XCTAssertTrue(GitClient.isRepository(at: repoURL))
        // git reports the physical path; temporaryDirectory may sit behind the
        // /var → /private/var symlink, so compare fully resolved paths.
        XCTAssertEqual(GitClient.topLevel(of: repoURL)?.resolvingSymlinksInPath().path,
                       repoURL.resolvingSymlinksInPath().path)
        let subdir = repoURL.appendingPathComponent("sub/dir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        XCTAssertTrue(GitClient.isRepository(at: subdir))
        let nonRepo = FileManager.default.temporaryDirectory
        XCTAssertFalse(GitClient.isRepository(at: nonRepo))
    }

    // MARK: - Activity log wrappers

    func testActivityLogRecordsSuccessfulCommand() throws {
        let log = GitActivityLog()
        client.activityLog = log
        _ = try client.status()
        let entry = log.entries.last
        XCTAssertEqual(entry?.command.hasPrefix("status"), true)
        XCTAssertEqual(entry?.isRunning, false)
        XCTAssertEqual(entry?.exitCode, 0)
    }

    func testActivityLogRecordsFailureWithGitStderr() throws {
        let log = GitActivityLog()
        client.activityLog = log
        // No merge in progress → git exits non-zero with a real message.
        XCTAssertThrowsError(try client.mergeAbort())
        let entry = log.entries.last
        XCTAssertEqual(entry?.isRunning, false)
        XCTAssertNotEqual(entry?.exitCode, 0)
        // The entry must carry git's actual stderr (hook output lives there),
        // never a generic "operation couldn't be completed" description.
        XCTAssertTrue(entry?.stderrTail?.localizedCaseInsensitiveContains("merge") ?? false)
    }

    func testActivityLogRecordsCommitWithoutLeakingMessage() throws {
        let log = GitActivityLog()
        client.activityLog = log
        try write("log-test\n", to: "log.txt")
        try client.stage(paths: ["log.txt"])
        try client.commit(message: "s3cret message", amend: false)
        let entry = try XCTUnwrap(log.entries.last(where: { $0.command.hasPrefix("commit") }))
        XCTAssertEqual(entry.exitCode, 0)
        // The message travels via stdin (commit -F -): logged nowhere.
        XCTAssertFalse(log.entries.contains { $0.command.contains("s3cret") })
    }
}
