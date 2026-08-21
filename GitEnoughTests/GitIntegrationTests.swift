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

    func testDiscardRemovesStagedChanges() throws {
        try write("one\ndiscarded\n", to: "a.txt")
        try client.stage(paths: ["a.txt"])
        var status = try client.status()
        XCTAssertEqual(status.staged.map(\.path), ["a.txt"])
        XCTAssertTrue(status.unstaged.isEmpty)

        // Discarding from the Staged section must drop the staged content too —
        // a bare `checkout --` would only restore the worktree from the index.
        try client.discard(paths: ["a.txt"])
        status = try client.status()
        XCTAssertFalse(status.isDirty)
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "one\n")
    }

    func testDiscardStagedNewFileKeepsItAsUntracked() throws {
        // A staged *new* file has no HEAD state to restore. Discarding it must
        // not destroy the content — it becomes untracked again (Trash is one
        // deliberate step away from there).
        try write("brand new\n", to: "staged-new.txt")
        try client.stage(paths: ["staged-new.txt"])
        try client.discard(paths: ["staged-new.txt"])
        let status = try client.status()
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(status.unstaged.map(\.path), ["staged-new.txt"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("staged-new.txt").path))
    }

    func testDiscardStagedDeletionRestoresTheFile() throws {
        try run(["rm", "-q", "a.txt"])
        var status = try client.status()
        XCTAssertEqual(status.staged.map(\.path), ["a.txt"])

        try client.discard(paths: ["a.txt"])
        status = try client.status()
        XCTAssertFalse(status.isDirty)
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "one\n")
    }

    func testDiscardOnUnbornHEADKeepsEditedStagedFile() throws {
        // A brand-new repo without commits: discard can only unstage, and must
        // cope with a file that was edited *after* staging (rm --cached needs
        // -f for that) — while never touching the worktree file.
        let unbornURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unbornURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unbornURL) }
        _ = try GitShell.shared.runChecked(["init", "-b", "main"], in: unbornURL)
        let unborn = GitClient(worktree: unbornURL)

        let file = unbornURL.appendingPathComponent("new.txt")
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        try unborn.stage(paths: ["new.txt"])
        try "edited after staging\n".write(to: file, atomically: true, encoding: .utf8)

        try unborn.discard(paths: ["new.txt"])
        let status = try unborn.status()
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(status.unstaged.map(\.path), ["new.txt"])
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content, "edited after staging\n")
    }

    func testDiscardRemovesBothStagedAndUnstagedEdits() throws {
        try write("one\nstaged\n", to: "a.txt")
        try client.stage(paths: ["a.txt"])
        try write("one\nstaged\nunstaged\n", to: "a.txt")

        try client.discard(paths: ["a.txt"])
        let status = try client.status()
        XCTAssertFalse(status.isDirty)
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "one\n")
    }

    func testDiscardMixedBatchOfStagedNewAndTrackedModified() throws {
        // One call, two kinds of paths: the tracked file is restored to HEAD,
        // the staged-new file survives as untracked (the ls-files split).
        try write("one\nchanged\n", to: "a.txt")
        try client.stage(paths: ["a.txt"])
        try write("new\n", to: "b-new.txt")
        try client.stage(paths: ["b-new.txt"])

        try client.discard(paths: ["a.txt", "b-new.txt"])
        let status = try client.status()
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(status.unstaged.map(\.path), ["b-new.txt"])
        let restored = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(restored, "one\n")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("b-new.txt").path))
    }

    func testDiscardTreatsGlobCharactersInFilenamesLiterally() throws {
        try write("star\n", to: "a*.txt")
        try write("plain\n", to: "abc.txt")
        try client.stage(paths: ["a*.txt", "abc.txt"])
        try client.commit(message: "Add oddly named files")

        try write("star changed\n", to: "a*.txt")
        try write("plain changed\n", to: "abc.txt")
        try client.discard(paths: ["a*.txt"])

        // Only the literal file is reverted; the glob sibling keeps its edit.
        let reverted = try String(contentsOf: repoURL.appendingPathComponent("a*.txt"), encoding: .utf8)
        XCTAssertEqual(reverted, "star\n")
        let untouched = try String(contentsOf: repoURL.appendingPathComponent("abc.txt"), encoding: .utf8)
        XCTAssertEqual(untouched, "plain changed\n")
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

    func testUntrackedDirectoryDiffListsContents() throws {
        // status --untracked-files=normal collapses a fully-untracked directory
        // to a single "dir/" entry; diffing it with --no-index against /dev/null
        // fails ("Could not access 'dir/null'"), so directories get a listing.
        try FileManager.default.createDirectory(
            at: repoURL.appendingPathComponent("newdir/sub"), withIntermediateDirectories: true)
        try write("one\n", to: "newdir/one.txt")
        try write("two\n", to: "newdir/two.txt")
        // Nested untracked directories are recursed into, and ignore rules are
        // honored so the listing matches what status considers untracked.
        try write("three\n", to: "newdir/sub/three.txt")
        try write("*.log\n", to: "newdir/.gitignore")
        try write("log\n", to: "newdir/ignored.log")

        let status = try client.status()
        XCTAssertTrue(status.unstaged.contains { $0.path == "newdir/" && $0.isUntracked })

        let listing = try client.diffForUntracked(path: "newdir/")
        XCTAssertTrue(listing.contains("newdir/one.txt"))
        XCTAssertTrue(listing.contains("newdir/two.txt"))
        XCTAssertTrue(listing.contains("newdir/sub/three.txt"))
        XCTAssertFalse(listing.contains("ignored.log"))

        // Staging the directory works through the collapsed path, too.
        try client.stage(paths: ["newdir/"])
        XCTAssertEqual(try client.status().staged.count, 4)
    }

    func testUntrackedDirectoryListingIsCapped() throws {
        let directory = repoURL.appendingPathComponent("huge")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<210 {
            try write("x\n", to: "huge/f\(String(format: "%03d", index)).txt")
        }
        let listing = try client.diffForUntracked(path: "huge/")
        XCTAssertTrue(listing.contains("… and 10 more"))
        XCTAssertTrue(listing.contains("huge/f000.txt"))
        XCTAssertFalse(listing.contains("huge/f209.txt"))
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

    func testPublishSetsUpstreamOnCustomRemote() throws {
        // A local bare repo as the remote, under a non-default name: "origin"-
        // hardcoded publishing would fail here with "origin does not appear to
        // be a git repository".
        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try run(["init", "--bare", remoteURL.path])
        try run(["remote", "add", "work", remoteURL.path])

        try client.push(setUpstream: true, remote: "work")

        let main = try XCTUnwrap(client.branches().first { $0.name == "main" },
                                 "expected default branch 'main'")
        XCTAssertEqual(main.upstream, "work/main")
    }

    func testCreateTagLightweightAndAnnotated() throws {
        let head = try XCTUnwrap(try client.log(limit: 1).first?.hash)
        try client.createTag(name: "v1.0", message: nil, at: head)
        try client.createTag(name: "v2.0-beta", message: "Second release", at: head)
        let after = try XCTUnwrap(try client.log(limit: 1).first)
        let tags = after.decorations.filter { $0.kind == .tag }.map(\.name)
        XCTAssertTrue(tags.contains("v1.0"))
        XCTAssertTrue(tags.contains("v2.0-beta"))
        // Invalid refnames surface as git errors, not silent success.
        XCTAssertThrowsError(try client.createTag(name: "not a tag", message: nil, at: head))
        // Existing tags must not be silently moved (no implicit -f).
        XCTAssertThrowsError(try client.createTag(name: "v1.0", message: nil, at: head))
        // Leading-dash names are rejected before git can parse them as options.
        XCTAssertThrowsError(try client.createTag(name: "-f", message: nil, at: head))
        // The annotated tag actually carries its message.
        let annotation = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "for-each-ref", "refs/tags/v2.0-beta",
             "--format=%(contents:subject)"], in: nil)
        XCTAssertEqual(annotation.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Second release")
        // And the lightweight one has no annotation object.
        let lightweight = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "for-each-ref", "refs/tags/v1.0", "--format=%(objecttype)"], in: nil)
        XCTAssertEqual(lightweight.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "commit")
    }

    func testGitIgnoreEscapedPatternMatchesLiterally() throws {
        // A filename full of glob metacharacters must be ignored *literally*.
        try write("data\n", to: "report[1].txt")
        let updated = GitIgnore.appending("report[1].txt", to: "")
        try updated.write(to: repoURL.appendingPathComponent(".gitignore"),
                          atomically: true, encoding: .utf8)
        // check-ignore exits 0 (and echoes the path) when the path is ignored.
        let result = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "check-ignore", "report[1].txt"], in: nil)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "report[1].txt")
    }

    func testIsIgnoredDetectsBroaderExistingPatterns() throws {
        try write("*.log\nbuild/\n", to: ".gitignore")
        XCTAssertTrue(client.isIgnored(path: "error.log"))
        XCTAssertTrue(client.isIgnored(path: "build/output.bin"))
        XCTAssertFalse(client.isIgnored(path: "notes.txt"))
    }

    // MARK: - Rebase / cherry-pick conflicts

    /// Creates a branch whose next commit on a.txt conflicts with main's next
    /// commit, leaving both branches in place.
    private func makeConflictingBranch(_ name: String) throws {
        try run(["checkout", "-b", name])
        try write("from \(name)\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on \(name)"])
        try run(["checkout", "main"])
        try write("from main\n", to: "a.txt")
        try run(["add", "a.txt"])
        try run(["commit", "-m", "Change a on main"])
    }

    func testRebaseConflictDetectionResolutionAndContinue() throws {
        try makeConflictingBranch("conflicter")
        XCTAssertNil(client.inProgressOperation())

        // Rebasing main onto conflicter conflicts on a.txt. During a rebase git
        // writes rebase-merge/ but NOT MERGE_HEAD — exactly the state that
        // merge-only detection used to miss.
        XCTAssertThrowsError(try run(["rebase", "conflicter"]))
        XCTAssertEqual(client.inProgressOperation(), .rebase)
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"])
        XCTAssertFalse(try client.status().conflicted.isEmpty)
        XCTAssertEqual(client.operationLabel(for: .rebase), "Rebasing main")

        // Ours during a rebase is the new base (conflicter); theirs is main's
        // commit being replayed.
        try client.resolveConflict(path: "a.txt", ours: true)
        try client.rebaseContinue()

        XCTAssertNil(client.inProgressOperation())
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "from conflicter\n")
        XCTAssertFalse(try client.status().isDirty)
    }

    func testRebaseAbortRestoresState() throws {
        try makeConflictingBranch("conflicter")
        XCTAssertThrowsError(try run(["rebase", "conflicter"]))
        XCTAssertEqual(client.inProgressOperation(), .rebase)

        try client.rebaseAbort()

        XCTAssertNil(client.inProgressOperation())
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "from main\n")
        XCTAssertFalse(try client.status().isDirty)
    }

    func testCherryPickConflictDetectionAndAbort() throws {
        try makeConflictingBranch("picker")
        let hash = try GitShell.shared.runChecked(["rev-parse", "picker"], in: repoURL).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertThrowsError(try client.cherryPick(hash))
        XCTAssertEqual(client.inProgressOperation(), .cherryPick)
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"])

        try client.cherryPickAbort()

        XCTAssertNil(client.inProgressOperation())
        let content = try String(contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "from main\n")
        XCTAssertFalse(try client.status().isDirty)
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
