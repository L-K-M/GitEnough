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

    func testRebaseInProgressDetectionAndAbort() throws {
        try run(["checkout", "-b", "rebaser"])
        try write("from rebaser\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on rebaser"])
        try run(["checkout", "main"])
        try write("from main\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on main"])
        try run(["checkout", "rebaser"])

        XCTAssertFalse(client.rebaseInProgress())
        XCTAssertThrowsError(try GitShell.shared.runChecked(["rebase", "main"], in: repoURL))

        XCTAssertTrue(client.rebaseInProgress())
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"])

        try client.rebaseAbort()
        XCTAssertFalse(client.rebaseInProgress())
        let status = try client.status()
        XCTAssertEqual(status.head, "rebaser")
        // The abort rewound the replay: a.txt is back to the branch's version.
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "from rebaser\n")
    }

    func testRebaseContinueAfterResolvingConflicts() throws {
        try run(["checkout", "-b", "rebaser"])
        try write("from rebaser\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on rebaser"])
        try run(["checkout", "main"])
        try write("from main\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on main"])
        try run(["checkout", "rebaser"])
        XCTAssertThrowsError(try GitShell.shared.runChecked(["rebase", "main"], in: repoURL))
        XCTAssertTrue(client.rebaseInProgress())

        // Continuing with open conflicts must fail — resolve first.
        XCTAssertThrowsError(try client.rebaseContinue())
        XCTAssertTrue(client.rebaseInProgress())

        // During a rebase, "theirs" is the commit being replayed.
        try client.resolveConflict(path: "a.txt", ours: false)
        try client.rebaseContinue()

        XCTAssertFalse(client.rebaseInProgress())
        let commits = try client.log(limit: 10)
        XCTAssertEqual(commits.first?.subject, "Change a on rebaser")
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "from rebaser\n")
    }

    func testRebaseSkipDropsTheReplayedCommit() throws {
        try run(["checkout", "-b", "rebaser"])
        try write("from rebaser\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on rebaser"])
        try run(["checkout", "main"])
        try write("from main\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on main"])
        try run(["checkout", "rebaser"])
        XCTAssertThrowsError(try GitShell.shared.runChecked(["rebase", "main"], in: repoURL))
        XCTAssertTrue(client.rebaseInProgress())

        // Skip works even with the conflict unresolved: the replayed commit is
        // dropped and the (single-commit) rebase completes.
        try client.rebaseSkip()
        XCTAssertFalse(client.rebaseInProgress())
        let commits = try client.log(limit: 10)
        XCTAssertEqual(commits.first?.subject, "Change a on main")
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "from main\n")
    }

    func testRebaseApplyBackendIsDetected() throws {
        // The apply backend stores state in rebase-apply (without the
        // rebase-apply/applying marker that would mean `git am`).
        try run(["checkout", "-b", "rebaser"])
        try write("from rebaser\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on rebaser"])
        try run(["checkout", "main"])
        try write("from main\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on main"])
        try run(["checkout", "rebaser"])

        XCTAssertThrowsError(try GitShell.shared.runChecked(
            ["-c", "rebase.backend=apply", "rebase", "main"], in: repoURL))
        XCTAssertTrue(client.rebaseInProgress())

        try client.rebaseAbort()
        XCTAssertFalse(client.rebaseInProgress())
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
}
