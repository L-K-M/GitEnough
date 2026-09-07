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
        XCTAssertEqual(branches.first { $0.isHead }?.refName, "refs/heads/main")
        XCTAssertNotNil(branches.first { $0.name == "feature" })
        XCTAssertTrue(branches.allSatisfy { !$0.isRemote })
    }

    func testBranchAndTagWithSameNameStillChecksOutBranch() throws {
        try run(["branch", "same"])
        try run(["tag", "same"])
        let branch = try XCTUnwrap(client.branches().first { $0.name == "same" })
        XCTAssertEqual(branch.refName, "refs/heads/same")

        try client.checkout(branch: branch.name)

        XCTAssertEqual(try client.status().head, "same")
        XCTAssertFalse(try client.status().isDetached)
    }

    func testRemoteBranchAndTagCollisionKeepsCanonicalRemoteRef() throws {
        try run(["remote", "add", "origin", "https://example.com/acme/widget.git"])
        try run(["update-ref", "refs/remotes/origin/same", "refs/heads/main"])
        try run(["tag", "origin/same"])
        let branch = try XCTUnwrap(
            client.branches().first { $0.refName == "refs/remotes/origin/same" })

        try client.checkoutTracking(remoteBranch: branch.refName,
                                    localName: "tracked-collision")

        XCTAssertEqual(try client.status().head, "tracked-collision")
    }

    func testBranchesCarryLastCommitDate() throws {
        let branches = try client.branches()
        // Both branches were committed to moments ago in setUp. Recency only,
        // not cross-branch ordering: git's committer date is second-granular and
        // a fast CI runner finishes the whole fixture inside one second.
        for branch in branches {
            let date = try XCTUnwrap(branch.lastCommitDate,
                                     "\(branch.name) should carry its tip's committer date")
            XCTAssertEqual(date.timeIntervalSinceNow, 0, accuracy: 120)
        }
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

    func testUnstageStagedRenameIncludesOriginalPath() throws {
        try run(["mv", "a.txt", "renamed.txt"])
        var status = try client.status()
        let rename = try XCTUnwrap(status.staged.first { $0.stagedStatus == .renamed })
        XCTAssertEqual(rename.path, "renamed.txt")
        XCTAssertEqual(rename.originalPath, "a.txt")

        try client.unstage(paths: rename.affectedPaths)

        status = try client.status()
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(Set(status.unstaged.map(\.path)), ["a.txt", "renamed.txt"])
    }

    func testDiscardStagedRenameRestoresSourceAndPreservesDestination() throws {
        try run(["mv", "a.txt", "renamed.txt"])
        let rename = try XCTUnwrap(
            try client.status().staged.first { $0.stagedStatus == .renamed })

        try client.discard(paths: rename.affectedPaths)

        let status = try client.status()
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(status.unstaged.map(\.path), ["renamed.txt"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("renamed.txt").path))
        let original = try String(
            contentsOf: repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        let destination = try String(
            contentsOf: repoURL.appendingPathComponent("renamed.txt"), encoding: .utf8)
        XCTAssertEqual(original, "one\n")
        XCTAssertEqual(destination, "one\n")
    }

    func testDiscardStagedCopyPreservesModifiedSource() throws {
        try run(["config", "status.renames", "copies"])
        try write("one\n", to: "copied.txt")
        try write("changed source\n", to: "a.txt")
        try client.stage(paths: ["a.txt", "copied.txt"])

        let copy = try XCTUnwrap(
            try client.status().staged.first { $0.stagedStatus == .copied })
        XCTAssertEqual(copy.originalPath, "a.txt")
        XCTAssertEqual(copy.affectedPaths, ["copied.txt"])

        try client.discard(paths: copy.affectedPaths)

        let status = try client.status()
        XCTAssertTrue(status.staged.contains {
            $0.path == "a.txt" && $0.stagedStatus == .modified
        })
        XCTAssertTrue(status.unstaged.contains {
            $0.path == "copied.txt" && $0.isUntracked
        })
        XCTAssertEqual(
            try String(contentsOf: repoURL.appendingPathComponent("a.txt"),
                       encoding: .utf8),
            "changed source\n")
        XCTAssertEqual(
            try String(contentsOf: repoURL.appendingPathComponent("copied.txt"),
                       encoding: .utf8),
            "one\n")
    }

    func testStageAndUnstageCopyDoNotTouchSourceState() throws {
        try run(["config", "status.renames", "copies"])
        try write("one\n", to: "copied.txt")
        try write("staged source\n", to: "a.txt")
        try client.stage(paths: ["a.txt", "copied.txt"])

        var copy = try XCTUnwrap(
            try client.status().staged.first { $0.stagedStatus == .copied })
        try client.unstage(paths: copy.affectedPaths)

        var status = try client.status()
        XCTAssertTrue(status.staged.contains {
            $0.path == "a.txt" && $0.stagedStatus == .modified
        })
        XCTAssertTrue(status.unstaged.contains {
            $0.path == "copied.txt" && $0.isUntracked
        })

        // Re-stage the copy, then give its independently staged source another
        // worktree edit. Staging the copy row must not absorb that source edit.
        try client.stage(paths: ["copied.txt"])
        try write("unstaged source\n", to: "a.txt")
        status = try client.status()
        copy = try XCTUnwrap(status.staged.first { $0.stagedStatus == .copied })
        XCTAssertEqual(copy.affectedPaths, ["copied.txt"])

        try client.stage(paths: copy.affectedPaths)

        status = try client.status()
        let source = try XCTUnwrap(status.staged.first { $0.path == "a.txt" })
        XCTAssertEqual(source.stagedStatus, .modified)
        XCTAssertEqual(source.unstagedStatus, .modified)
        XCTAssertEqual(
            try String(contentsOf: repoURL.appendingPathComponent("a.txt"),
                       encoding: .utf8),
            "unstaged source\n")
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

    func testPathTakingCommandsTreatGitPathspecSyntaxLiterally() throws {
        let pairs = [
            (target: "star*.txt", decoy: "star-hit.txt"),
            (target: "question?.txt", decoy: "question1.txt"),
            (target: "bracket[1].txt", decoy: "bracket1.txt"),
            (target: ":(glob)magic*.txt", decoy: "magic-hit.txt"),
        ]

        for (index, pair) in pairs.enumerated() {
            try write("base target \(index)\n", to: pair.target)
            try write("base decoy \(index)\n", to: pair.decoy)
        }
        try run(["add", "-A"])
        try run(["commit", "-m", "Add pathspec fixtures"])

        for (index, pair) in pairs.enumerated() {
            try write("changed target \(index)\n", to: pair.target)
            try write("changed decoy \(index)\n", to: pair.decoy)
        }

        let targets = pairs.map { $0.target }
        let decoys = pairs.map { $0.decoy }
        try client.stage(paths: targets)

        var status = try client.status()
        XCTAssertEqual(Set(status.staged.map(\.path)), Set(targets))
        XCTAssertEqual(Set(status.unstaged.map(\.path)), Set(decoys))
        for (index, pair) in pairs.enumerated() {
            let patch = try client.diff(path: pair.target, staged: true)
            XCTAssertTrue(patch.contains("+changed target \(index)"), pair.target)
            XCTAssertFalse(patch.contains("+changed decoy \(index)"), pair.target)
        }

        try client.unstage(paths: targets)
        status = try client.status()
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(Set(status.unstaged.map(\.path)), Set(targets + decoys))
        for (index, pair) in pairs.enumerated() {
            let patch = try client.diff(path: pair.target, staged: false)
            XCTAssertTrue(patch.contains("+changed target \(index)"), pair.target)
            XCTAssertFalse(patch.contains("+changed decoy \(index)"), pair.target)
        }

        // Put target and lookalike changes in the same commit: a commit-file
        // diff must still return only the exact filename selected in the UI.
        try run(["add", "-A"])
        try run(["commit", "-m", "Change pathspec fixtures"])
        let hash = try XCTUnwrap(client.log(limit: 1).first?.hash)
        for (index, pair) in pairs.enumerated() {
            let patch = try client.commitFileDiff(hash: hash, path: pair.target)
            XCTAssertTrue(patch.contains("+changed target \(index)"), pair.target)
            XCTAssertFalse(patch.contains("+changed decoy \(index)"), pair.target)
        }
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

    func testConflictActionsTreatPathspecsLiterally() throws {
        let paths = ["tool*.txt", "tool-one.txt",
                     "resolve*.txt", "resolve-one.txt",
                     "mark?.txt", "mark1.txt"]
        for path in paths { try write("base\n", to: path) }
        try run(["add", "-A"])
        try run(["commit", "-m", "Add conflict pathspec fixtures"])

        try run(["checkout", "-b", "pathspec-conflicter"])
        for path in paths { try write("from other branch\n", to: path) }
        try run(["add", "-A"])
        try run(["commit", "-m", "Change conflict fixtures on branch"])

        try run(["checkout", "main"])
        for path in paths { try write("from main\n", to: path) }
        try run(["add", "-A"])
        try run(["commit", "-m", "Change conflict fixtures on main"])
        XCTAssertThrowsError(try client.merge("pathspec-conflicter"))
        XCTAssertEqual(Set(try client.conflictedPaths()), Set(paths))

        // A deterministic custom mergetool chooses the other branch's version.
        // Its wildcard-looking target must not resolve the lookalike conflict.
        try run(["config", "mergetool.pathspec-test.cmd", "cp \"$REMOTE\" \"$MERGED\""])
        try run(["config", "mergetool.pathspec-test.trustExitCode", "true"])
        // git-mergetool re-expands the filename it selected with an unquoted
        // `set -- $files`. Where /bin/sh honours SHELLOPTS=noglob (macOS, where
        // it is Bash) the wildcard name resolves only itself; where it doesn't
        // (dash, most Linux distributions) GitClient refuses rather than let
        // the tool resolve every conflicted lookalike. Either way the one thing
        // that must never happen is tool-one.txt being resolved silently.
        if GitClient.shellGlobsDespiteNoglob {
            XCTAssertThrowsError(try client.runMergeTool("pathspec-test", path: "tool*.txt")) {
                XCTAssertTrue("\($0)".contains("wildcard"), "unexpected error: \($0)")
            }
            XCTAssertEqual(Set(try client.conflictedPaths()), Set(paths),
                           "a refused merge tool must leave every conflict untouched")
            try client.resolveConflict(path: "tool*.txt", ours: false)
        } else {
            try client.runMergeTool("pathspec-test", path: "tool*.txt")
        }
        XCTAssertEqual(
            Set(try client.conflictedPaths()),
            Set(paths.filter { $0 != "tool*.txt" }))

        try client.resolveConflict(path: "resolve*.txt", ours: true)
        XCTAssertEqual(
            Set(try client.conflictedPaths()),
            Set(paths.filter { $0 != "tool*.txt" && $0 != "resolve*.txt" }))

        try write("resolved by hand\n", to: "mark?.txt")
        try client.markResolved(path: "mark?.txt")
        XCTAssertEqual(Set(try client.conflictedPaths()),
                       Set(["tool-one.txt", "resolve-one.txt", "mark1.txt"]))
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

    func testOrdinaryFetchAndPullDoNotForceUpdateEveryTag() throws {
        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try run(["init", "--bare", remoteURL.path])
        try run(["remote", "add", "origin", remoteURL.path])
        try run(["push", "-u", "origin", "main"])

        let head = try GitShell.shared.runChecked(
            ["rev-parse", "HEAD"], in: repoURL).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = try GitShell.shared.runChecked(
            ["rev-parse", "HEAD^"], in: repoURL).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try run(["tag", "shared-name", head])
        _ = try GitShell.shared.runChecked(
            ["update-ref", "refs/tags/shared-name", parent], in: remoteURL)

        // `--tags` would reject this routine sync with “would clobber existing
        // tag”. Normal fetch semantics leave the divergent local tag alone.
        try client.fetch()
        try client.pull(rebase: false)

        let localTag = try GitShell.shared.runChecked(
            ["rev-parse", "refs/tags/shared-name"], in: repoURL).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(localTag, head)
    }

    func testBranchUpstreamGoneAfterRemoteDeletion() throws {
        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try run(["init", "--bare", remoteURL.path])
        try run(["remote", "add", "origin", remoteURL.path])
        try client.push(setUpstream: true, remote: "origin")

        var main = try XCTUnwrap(client.branches().first { $0.name == "main" && !$0.isRemote })
        XCTAssertEqual(main.upstream, "origin/main")
        XCTAssertFalse(main.upstreamGone)

        // Delete the branch on the remote, then prune: the tracking config
        // survives but its ref is gone — for-each-ref reports "[gone]".
        _ = try GitShell.shared.runChecked(
            ["-C", remoteURL.path, "update-ref", "-d", "refs/heads/main"], in: nil)
        try run(["fetch", "--prune", "origin"])

        main = try XCTUnwrap(client.branches().first { $0.name == "main" && !$0.isRemote })
        XCTAssertTrue(main.upstreamGone)
        XCTAssertEqual(main.upstream, "origin/main")
    }

    func testUnpushedCommitHashes() throws {
        // No upstream configured: the concept doesn't apply — empty set.
        XCTAssertTrue(try client.unpushedCommitHashes().isEmpty)

        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try run(["init", "--bare", remoteURL.path])
        try run(["remote", "add", "origin", remoteURL.path])
        try client.push(setUpstream: true, remote: "origin")
        XCTAssertTrue(try client.unpushedCommitHashes().isEmpty)

        try write("five\n", to: "e.txt")
        try client.stage(paths: ["e.txt"])
        try client.commit(message: "Unpushed 1")
        try write("six\n", to: "f.txt")
        try client.stage(paths: ["f.txt"])
        try client.commit(message: "Unpushed 2")

        // Exactly the two new commits are flagged — nothing older.
        let unpushed = try client.unpushedCommitHashes()
        let newest = try client.log(limit: 2).map(\.hash)
        XCTAssertEqual(unpushed, Set(newest))

        // Pushing clears the markers.
        try client.push(setUpstream: false)
        XCTAssertTrue(try client.unpushedCommitHashes().isEmpty)
    }

    func testDeleteRemoteBranch() throws {
        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try run(["init", "--bare", remoteURL.path])
        try run(["remote", "add", "origin", remoteURL.path])
        // Publish something to delete, then mirror the remote-tracking ref
        // like a fetch would.
        try run(["checkout", "-b", "to-delete"])
        try client.push(setUpstream: true, remote: "origin")
        try run(["checkout", "main"])
        try client.fetch()
        XCTAssertTrue(try client.branches().contains { $0.name == "origin/to-delete" })

        try client.deleteRemoteBranch("origin/to-delete")

        try client.fetch()
        XCTAssertFalse(try client.branches().contains { $0.name == "origin/to-delete" })
        // The local branch is untouched — remote deletion never cascades.
        XCTAssertTrue(try client.branches().contains { $0.name == "to-delete" && !$0.isRemote })
    }

    func testDeleteRemoteBranchRejectsInvalidRefs() throws {
        // Guard paths: no push happens for any of these. (A remote must exist
        // so the prefix-matching guard, not just "no configured remote", is
        // what rejects the malformed inputs.)
        try run(["remote", "add", "origin", "https://example.com/x/y.git"])
        XCTAssertThrowsError(try client.deleteRemoteBranch("noremote/branch"))
        XCTAssertThrowsError(try client.deleteRemoteBranch("origin/"))
        XCTAssertThrowsError(try client.deleteRemoteBranch("origin/HEAD"))
        XCTAssertThrowsError(try client.deleteRemoteBranch("origin/-dash"))
    }

    func testDeleteRemoteBranchOnSlashNamedRemote() throws {
        // Remote names may contain "/": "up/stream/port" must split into
        // remote "up/stream" + branch "port" (longest-prefix match), never
        // remote "up" + branch "stream/port". (Branch name "port": the shared
        // fixture already has a "feature" branch.)
        let upURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-up-\(UUID().uuidString)")
        let upStreamURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-upstream-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: upURL)
            try? FileManager.default.removeItem(at: upStreamURL)
        }
        try run(["init", "--bare", upURL.path])
        try run(["init", "--bare", upStreamURL.path])
        try run(["remote", "add", "up", upURL.path])
        try run(["remote", "add", "up/stream", upStreamURL.path])

        try run(["checkout", "-b", "port"])
        try client.push(setUpstream: true, remote: "up/stream")
        try run(["push", "up", "port"])   // the same branch on both remotes
        try run(["checkout", "main"])

        try client.deleteRemoteBranch("up/stream/port")

        // Gone from up/stream …
        let upStreamRefs = try GitShell.shared.runChecked(
            ["-C", upStreamURL.path, "for-each-ref", "--format=%(refname)"], in: nil).stdout
        XCTAssertFalse(upStreamRefs.contains("refs/heads/port"))
        // … but untouched on up.
        let upRefs = try GitShell.shared.runChecked(
            ["-C", upURL.path, "for-each-ref", "--format=%(refname)"], in: nil).stdout
        XCTAssertTrue(upRefs.contains("refs/heads/port"))
    }

    func testForcePushWithLease() throws {
        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try run(["init", "--bare", remoteURL.path])
        try run(["remote", "add", "origin", remoteURL.path])
        try client.push(setUpstream: true, remote: "origin")

        // Rewrite local history so local and remote diverge.
        try write("amended\n", to: "a.txt")
        try client.stage(paths: ["a.txt"])
        try client.commit(message: "Amended tip", amend: true)

        // A plain push is refused (non-fast-forward)…
        XCTAssertThrowsError(try client.push(setUpstream: false))
        // …the lease push succeeds, and the remote tip matches local HEAD.
        try client.push(setUpstream: false, forceWithLease: true)
        let localHead = try GitShell.shared.runChecked(["rev-parse", "HEAD"], in: repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHead = try GitShell.shared.runChecked(
            ["-C", remoteURL.path, "rev-parse", "refs/heads/main"], in: nil)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(localHead, remoteHead)
    }

    // MARK: - Unstage never becomes a deletion

    /// `unstage` used to wrap `git restore --staged` in a blanket `catch` that
    /// fell through to `git rm --cached`. That is only correct for an unborn
    /// HEAD; on a repository that has commits, *any* failure — here, one bad
    /// pathspec alongside a good one — turned every selected staged
    /// modification into a staged **deletion**, and reported success while
    /// doing it.
    func testAFailedUnstageLeavesTheFileStagedRatherThanDeleted() throws {
        try write("changed\n", to: "a.txt")
        try client.stage(paths: ["a.txt"])

        // `git restore --staged` refuses the whole invocation when a pathspec
        // matches nothing, so this is a genuine failure with a real staged file
        // in the same call — exactly the shape the old catch mishandled.
        XCTAssertThrowsError(try client.unstage(paths: ["a.txt", "no-such-file.txt"]),
                             "a pathspec that matches nothing must surface, not be swallowed")

        let status = try client.status()
        XCTAssertTrue(status.staged.contains { $0.path == "a.txt" && $0.stagedStatus == .modified },
                      "the file must still be staged as a modification, got \(status.staged)")
        XCTAssertFalse(status.staged.contains { $0.stagedStatus == .deleted },
                       "a failed unstage must never stage a deletion")
    }

    /// A repository whose HEAD does not resolve is not necessarily unborn. With
    /// a corrupt `refs/heads/<branch>`, `rev-parse --verify HEAD` fails exactly
    /// as it does for an unborn HEAD — so keying the fallback off that alone
    /// would run index surgery on a repository full of real files.
    func testACorruptHeadRefFailsInsteadOfStagingDeletions() throws {
        try write("changed\n", to: "a.txt")
        try client.stage(paths: ["a.txt"])
        try corruptHeadRef()

        XCTAssertThrowsError(try client.unstage(paths: ["a.txt"]),
                             "a corrupt HEAD must surface, not fall through to rm --cached")

        // `ls-files` reads the index without needing HEAD, so it still answers
        // in a repository this broken: the entry must still be there.
        let indexed = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "ls-files", "--", "a.txt"], in: nil).stdout
        XCTAssertTrue(indexed.contains("a.txt"),
                      "the file must still be in the index, not removed from it")
    }

    /// Points HEAD's branch ref at garbage, restoring it when the test ends.
    ///
    /// Derived, not assumed: corrupting a ref that isn't HEAD's would leave HEAD
    /// resolving fine and the call under test succeeding, so the test would fail
    /// with "it didn't throw" — which points nowhere near the real cause.
    ///
    /// Hermetic by construction rather than by luck: `setUp` builds a fresh
    /// repository per test today, so nothing inherits this corruption — but that
    /// is a property of the fixture, not of the tests, and a shared fixture would
    /// make every later test fail for an unrelated reason. `addTeardownBlock`
    /// rather than `defer` because a `defer` written here would restore the ref
    /// the moment this helper returns — before the code under test ever runs.
    /// (XCTest's plain assertions don't throw, so the "survives a throwing
    /// assertion" reasoning this comment used to give was not the mechanism.)
    private func corruptHeadRef() throws {
        let branch = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "symbolic-ref", "--short", "HEAD"], in: nil).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Asked, not assumed. `.git` is a *file* in a linked worktree or
        // submodule, and `refs/heads` can live in the common dir — a hardcoded
        // layout would write somewhere git never reads, HEAD would keep
        // resolving, and the guard below would classify that as "not
        // applicable" and skip. `--git-path` handles the remapping and prints a
        // repo-relative path unless the git dir is absolute.
        let refPath = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "rev-parse", "--git-path", "refs/heads/\(branch)"],
            in: nil).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headRef = refPath.hasPrefix("/")
            ? URL(fileURLWithPath: refPath)
            : repoURL.appendingPathComponent(refPath)
        // The directory chain, not just the file: a nested default branch name
        // (`feature/x`) has no `refs/heads/feature` in a fresh fixture, and a
        // reftable-backed repository may have no `refs/heads` at all. Without
        // this the write throws an opaque Cocoa error *before* the skip guard
        // below can classify the situation — turning the graceful degradation
        // this helper is built around into the red suite it exists to avoid.
        try FileManager.default.createDirectory(
            at: headRef.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalHead = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "rev-parse", "HEAD"], in: nil).stdout
        addTeardownBlock {
            try? originalHead.write(to: headRef, atomically: true, encoding: .utf8)
        }
        try "not a sha\n".write(to: headRef, atomically: true, encoding: .utf8)

        // Skip rather than fail. The branch name comes from `symbolic-ref`, so
        // the path cannot be wrong — a HEAD that still resolves means the write
        // was a no-op, and the realistic cause is the reftable backend
        // (git 2.45+, increasingly the default), which does not read loose ref
        // files at all. That is "not applicable here", not "broken": failing
        // would give contributors on newer git a permanently red suite with a
        // message that reads like a product regression.
        guard try GitShell.shared.run(
            ["-C", repoURL.path, "rev-parse", "--verify", "--quiet", "HEAD"],
            in: nil).exitCode != 0 else {
            throw XCTSkip("HEAD still resolves after corrupting \(branch), so this "
                          + "repository is not on loose refs — the corrupt-ref tests "
                          + "need the files backend.")
        }
    }

    /// `discard` shares `isUnbornHEAD()` with `unstage`, so it is pinned too —
    /// but it does **not** behave the same way, and the difference is the point.
    ///
    /// Verified against git 2.43: with `refs/heads/<branch>` pointing at garbage,
    /// `git restore --staged` fails (which is what makes `unstage`'s guard load-
    /// bearing) while `git reset -q HEAD --` *succeeds*, falling back to the
    /// empty tree exactly as it does on a genuinely unborn HEAD. So `discard`
    /// does not throw here; it degrades to an unstage.
    ///
    /// What this test protects is the thing that actually matters: **nothing is
    /// destroyed**. The worktree file keeps the user's content, and discard on a
    /// broken repository can only cost the staging, never the work.
    func testDiscardOnACorruptHeadRefUnstagesRatherThanDestroying() throws {
        try write("changed\n", to: "a.txt")
        try client.stage(paths: ["a.txt"])
        try corruptHeadRef()

        // Recorded, not asserted. On git 2.43 `reset` treats an unresolvable
        // HEAD like an unborn one and falls back to the empty tree, but that is
        // incidental rather than promised — and asserting it would fail the
        // test *before* the assertions that carry the real contract, in exactly
        // the environments where you most want to know that nothing was
        // destroyed. Both outcomes are acceptable; only the state afterwards
        // is not negotiable.
        var discardSucceeded = true
        do {
            try client.discard(paths: ["a.txt"])
        } catch {
            discardSucceeded = false
        }

        let file = repoURL.appendingPathComponent("a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the worktree file must survive a discard on a broken repository")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed\n",
                       "and keep the user's content — the checkout step must not run")

        // The half this test is named for, and was not checking: a `discard`
        // that silently no-opped would satisfy every assertion above. `ls-files`
        // rather than `client.status()` because HEAD is corrupt here and
        // `ls-files` reads the index without consulting it.
        let indexed = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "ls-files", "--", "a.txt"], in: nil).stdout
        if discardSucceeded {
            XCTAssertTrue(indexed.isEmpty,
                          "discard must degrade to an unstage, not to a no-op")
        } else {
            XCTAssertFalse(indexed.isEmpty,
                           "a discard that failed outright must leave the index alone "
                           + "rather than half-applying")
        }
    }

    /// The case the blanket catch was written for still works: on an unborn
    /// HEAD there is nothing to restore against, so unstaging drops the index
    /// entry and leaves the file on disk.
    func testUnstageOnUnbornHeadDropsTheIndexEntry() throws {
        let fresh = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-unborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fresh) }
        // No -b: this test never names the branch, only needs HEAD unborn.
        // Initialised *before* the client is built: nothing in `GitClient.init`
        // inspects the worktree today, but a client naming a repository that
        // does not exist yet works only by that, and the ordering costs nothing.
        _ = try GitShell.shared.runChecked(["init", fresh.path], in: nil)
        let unborn = GitClient(worktree: fresh)
        try "new\n".write(to: fresh.appendingPathComponent("new.txt"),
                          atomically: true, encoding: .utf8)
        try unborn.stage(paths: ["new.txt"])
        XCTAssertEqual(try unborn.status().staged.map(\.path), ["new.txt"])

        try unborn.unstage(paths: ["new.txt"])

        let status = try unborn.status()
        XCTAssertTrue(status.staged.isEmpty, "got \(status.staged)")
        XCTAssertEqual(status.unstaged.map(\.path), ["new.txt"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fresh.appendingPathComponent("new.txt").path),
            "unstaging must never remove the file from disk")
    }

    /// The shape that was broken: stage a file in a brand-new repository, keep
    /// editing it, then unstage.
    ///
    /// `git rm --cached` refuses an entry whose content differs from *both* HEAD
    /// and the worktree. On an unborn HEAD git diffs against the empty tree, so
    /// every staged entry differs from HEAD and the check collapses to "refuse
    /// if the file was edited after staging" — the ordinary flow, in the one
    /// state this branch exists for. Measured on git 2.43:
    ///
    ///     error: the following file has staged content different from both the
    ///     file and the HEAD: new.txt  (use -f to force removal)
    ///
    /// `--ignore-unmatch` does not bypass it; only `-f` does. The sibling
    /// `discard` path has always passed `-f`, so this was an inconsistency
    /// inside one file rather than a considered difference.
    func testUnstageOnUnbornHeadWorksAfterTheFileIsEditedAgain() throws {
        let fresh = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughTests-unborn-edited-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fresh) }
        _ = try GitShell.shared.runChecked(["init", fresh.path], in: nil)
        let unborn = GitClient(worktree: fresh)

        let file = fresh.appendingPathComponent("new.txt")
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        try unborn.stage(paths: ["new.txt"])
        // The edit that makes the index entry differ from the worktree too.
        try "staged\nand edited after staging\n".write(to: file, atomically: true,
                                                       encoding: .utf8)

        try unborn.unstage(paths: ["new.txt"])

        let status = try unborn.status()
        XCTAssertTrue(status.staged.isEmpty, "got \(status.staged)")
        XCTAssertEqual(status.unstaged.map(\.path), ["new.txt"])
        // The later edit must survive: `--cached` drops the index entry and
        // must never reach into the worktree, `-f` included.
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "staged\nand edited after staging\n",
                       "unstaging must not roll the file back to what was staged")
    }

    /// A stale pathspec on a *born* HEAD throws rather than passing quietly to
    /// the unborn branch. That asymmetry is the design: only a positive
    /// unborn-HEAD answer takes the fallback, so a selection the index has moved
    /// on from cannot be answered by dropping index entries.
    func testUnstageRethrowsWhenTheFallbackDoesNotApply() throws {
        XCTAssertThrowsError(try client.unstage(paths: ["no-such-file.txt"])) { error in
            XCTAssertTrue("\(error)".contains("no-such-file.txt"),
                          "the error must name what could not be unstaged, got \(error)")
        }
    }

    // MARK: - Stage All during a conflict

    /// `git add -A` on an unmerged path stages the worktree content — conflict
    /// markers included — and clears the unmerged state, so the commit that
    /// follows lands `<<<<<<< HEAD` in history. In the app it is worse than the
    /// raw command: the conflict section is rendered from the unmerged entries,
    /// so staging them makes the warning vanish and the Commit button light up.
    func testStageAllRefusesWhileAnythingIsConflicted() throws {
        try makeConflict()
        let before = try client.conflictedPaths()
        XCTAssertEqual(before, ["a.txt"], "precondition: a real conflict")

        XCTAssertThrowsError(try client.stageAll()) { assertStageAllRefusal($0, naming: "a.txt") }

        // The unmerged entry survives, so the conflict UI still shows and the
        // markers are still in the worktree rather than in the index.
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"])
        let staged = try client.status().staged
        XCTAssertFalse(staged.contains { $0.path == "a.txt" },
                       "a conflicted path must not become a staged modification")
    }

    /// A modify/delete conflict has **no conflict markers anywhere** — the
    /// worktree simply holds the surviving side's content. `git add -A` there
    /// doesn't commit markers; it silently picks a winner and clears the
    /// unmerged state, which is the quieter and arguably worse failure. Verified
    /// against git 2.43: the entry is `u UD`, `diff --diff-filter=U` reports it,
    /// and `a.txt` contains no `<<<<<<<`.
    func testStageAllRefusesAModifyDeleteConflictThatHasNoMarkers() throws {
        try run(["checkout", "-b", "deleting", "main"])
        try run(["rm", "-q", "a.txt"])
        try run(["commit", "-m", "Delete a.txt"])
        try run(["checkout", "main"])
        try write("one\nedited\n", to: "a.txt")
        try run(["commit", "-am", "Edit a.txt"])
        _ = try GitShell.shared.run(["-C", repoURL.path, "merge", "deleting"], in: nil)

        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"],
                       "precondition: a modify/delete conflict")
        let contents = try String(contentsOf: repoURL.appendingPathComponent("a.txt"),
                                  encoding: .utf8)
        XCTAssertFalse(contents.contains("<<<<<<<"),
                       "precondition: this conflict shape has no markers")

        XCTAssertThrowsError(try client.stageAll()) { assertStageAllRefusal($0, naming: "a.txt") }
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"],
                       "the unmerged entry must survive, not be silently resolved")
    }

    /// The guard is about unmerged paths, not about being mid-merge: once every
    /// conflict is resolved, Stage All works again for the rest of the tree.
    func testStageAllWorksOnceTheConflictIsResolved() throws {
        try makeConflict()
        try client.resolveConflict(path: "a.txt", ours: true)
        try write("unrelated\n", to: "new.txt")

        try client.stageAll()

        XCTAssertTrue(try client.conflictedPaths().isEmpty)
        XCTAssertTrue(try client.status().staged.contains { $0.path == "new.txt" })
    }

    /// Asserts that `stageAll` refused *because of the guard*, and named the
    /// file to resolve.
    ///
    /// A bare `XCTAssertThrowsError` is not enough here: `stageAll` runs
    /// `conflictedPaths()` first, so a parse failure there also throws — and its
    /// text can perfectly well embed the path — leaving the test green while the
    /// guard never fired. Hence the type and `stageAllRefusalPrefix`, which the
    /// guard itself builds its message from — matching the literal here made a
    /// reword of the copy turn these tests red. `-1` marks
    /// "synthesized, not from git", but it is not unique to this guard —
    /// GitShell uses it for "git isn't installed" and "failed to launch" too —
    /// so the prefix is what actually discriminates.
    private func assertStageAllRefusal(_ error: Error, naming path: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        guard let gitError = error as? GitError else {
            return XCTFail("expected the guard's GitError, got \(type(of: error)): \(error)",
                           file: file, line: line)
        }
        XCTAssertEqual(gitError.exitCode, -1, "synthesized, not git's own exit code",
                       file: file, line: line)
        XCTAssertTrue(gitError.message.hasPrefix(GitClient.stageAllRefusalPrefix),
                      "the guard refused, not some other GitError: \(gitError.message)",
                      file: file, line: line)
        XCTAssertTrue(gitError.message.contains(path),
                      "the refusal must name what to resolve, got \(gitError.message)",
                      file: file, line: line)
        // The other half of the shared-constant guarantee. `StageAllBlockedHelpTests`
        // pins the tooltip to `conflictStagingConsequence`; without this, the
        // refusal could be reworded to say something else entirely and every
        // test would stay green — the drift the constant was extracted to make
        // impossible, still possible on the side nobody was asserting.
        XCTAssertTrue(gitError.message.contains(GitClient.conflictStagingConsequence),
                      "the refusal must state the shared consequence verbatim, got \(gitError.message)",
                      file: file, line: line)
    }

    /// main and other both change a.txt's middle line, then merge.
    private func makeConflict() throws {
        try run(["checkout", "-b", "conflicting", "main"])
        try write("one\nfrom-branch\n", to: "a.txt")
        try run(["commit", "-am", "Branch edit"])
        try run(["checkout", "main"])
        try write("one\nfrom-main\n", to: "a.txt")
        try run(["commit", "-am", "Main edit"])
        _ = try GitShell.shared.run(["-C", repoURL.path, "merge", "conflicting"], in: nil)
        // Without this, a merge that silently succeeded (or a fixture drift that
        // stopped the two edits from overlapping) would leave every conflict
        // test passing vacuously — including the ones asserting that a guard
        // *fired*, which would then be asserting nothing at all.
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"],
                       "precondition: the fixture merge really conflicts")
    }

    // MARK: - External diff drivers

    /// `diff.external` is what difftastic's own install instructions set
    /// (`git config --global diff.external difft`). Without `--no-ext-diff`
    /// every patch the app reads becomes that tool's rendered stdout — parsed
    /// as a unified diff by the diff pane, and handed to the commit-message
    /// model as though it were the change.
    ///
    /// Verified against git 2.43: `git diff --staged` and `git diff --no-index`
    /// are replaced; `git show` and `git diff --stat` are not.
    func testDiffReadsIgnoreAConfiguredExternalDiffDriver() throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-fake-difftool-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: script) }
        try "#!/bin/sh\necho EXTERNAL-TOOL-OUTPUT\n"
            .write(to: script, atomically: true, encoding: .utf8)
        // `sh <script>` rather than the script itself: git runs diff.external
        // through a shell, so passing the path as an *argument* needs no exec
        // bit and works on a runner whose TMPDIR is mounted noexec. Verified
        // against git 2.43 — the direct form fails "cannot exec … Permission
        // denied" without the bit, this form produces the output with or
        // without it.
        //
        // Which is why the file is left at its default 0644 rather than
        // chmodded to 0755. A chmod here would be inert on both mounts and
        // would quietly undo the demonstration: the test now *is* the evidence
        // that the exec bit is not needed, instead of asserting it in a
        // comment while arranging for it not to matter.
        //
        // Quoted because that shell splits on whitespace and TMPDIR is not
        // ours to choose. Measured against git 2.43 with a space in the temp
        // path: the bare form hands `sh` a truncated path and every patch read
        // in this test dies `fatal: external diff died`, so the test fails on
        // an environmental quirk it does not cover. The quoted form runs.
        try run(["config", "diff.external", "sh \"\(script.path)\""])

        try write("changed\n", to: "a.txt")
        try client.stage(paths: ["a.txt"])
        try write("brand new\n", to: "fresh.txt")

        // Precondition: the driver really is being invoked. Without this, a
        // fixture that never ran the script — a noexec TMPDIR, a git that
        // stopped honouring diff.external — would leave every "must not
        // contain" assertion below passing for the wrong reason.
        //
        let hijacked = try GitShell.shared.runChecked(
            ["-C", repoURL.path, "diff", "--staged"], in: nil).stdout
        guard hijacked.contains("EXTERNAL-TOOL-OUTPUT") else {
            // Return, don't just record: every assertion below is a "must not
            // contain", so an unhijacked baseline passes all of them. Failing
            // and continuing would bury the one real failure under a dozen
            // green checks that prove nothing.
            XCTFail("precondition: diff.external did not replace an unguarded "
                    + "patch read, so the guards below cannot be tested. Got: \(hijacked)")
            return
        }

        let staged = try client.stagedDiff()
        XCTAssertFalse(staged.contains("EXTERNAL-TOOL-OUTPUT"),
                       "the model must be handed a patch, not a diff tool's rendering")
        XCTAssertTrue(staged.contains("@@"), "…and that patch must be a real one")

        let untracked = try client.diffForUntracked(path: "fresh.txt")
        XCTAssertFalse(untracked.contains("EXTERNAL-TOOL-OUTPUT"))
        XCTAssertTrue(untracked.contains("brand new"))

        // Already carried the flag before this change; pinned so it stays.
        XCTAssertFalse(try client.diff(path: "a.txt", staged: true)
            .contains("EXTERNAL-TOOL-OUTPUT"))

        // Plain `git diff <path>` is the invocation diff.external hijacks most
        // readily, so pin it too. The worktree has to diverge from the index
        // first: after staging they are identical, and an empty diff never
        // invokes the driver — the assertion would pass for the wrong reason.
        try write("changed again\n", to: "a.txt")
        let unstaged = try client.diff(path: "a.txt", staged: false)
        XCTAssertTrue(unstaged.contains("@@"), "precondition: a non-empty diff")
        XCTAssertFalse(unstaged.contains("EXTERNAL-TOOL-OUTPUT"))

        // git does not apply the driver to these two, but they pass the flag
        // for consistency — assert they still return what they always did.
        XCTAssertTrue(try client.stagedDiffStat().contains("a.txt"))
        try client.commit(message: "Change a.txt")
        let head = try XCTUnwrap(try client.log(limit: 1).first?.hash)
        let commitDiff = try client.commitFileDiff(hash: head, path: "a.txt")
        XCTAssertTrue(commitDiff.contains("diff --git"), "got \(commitDiff)")
        XCTAssertFalse(commitDiff.contains("EXTERNAL-TOOL-OUTPUT"))
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

    func testConflictMarkerScanIsStreamingAndThrowsOnReadFailure() throws {
        try write("ordinary\n<<<<<<< HEAD\nours\n>>>>>>> topic\n", to: "markers.txt")
        // A deliberately tiny chunk makes both markers cross read boundaries.
        XCTAssertTrue(try client.fileHasConflictMarkers("markers.txt", chunkSize: 3))

        try write("Title\n=======\nnot an angle marker\n", to: "setext.md")
        XCTAssertFalse(try client.fileHasConflictMarkers("setext.md", chunkSize: 2))
        XCTAssertThrowsError(try client.fileHasConflictMarkers("missing.txt"))
    }

    func testMarkResolvedRefusesAFileThatStillHasMarkers() throws {
        try makeConflictingBranch("marker-conflict")
        XCTAssertThrowsError(try client.merge("marker-conflict"))

        XCTAssertThrowsError(try client.markResolved(path: "a.txt")) { error in
            XCTAssertTrue(error.localizedDescription.contains("still contains conflict markers"))
        }
        XCTAssertEqual(try client.conflictedPaths(), ["a.txt"])
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

    func testCherryPickMergeCommitNeedsMainline() throws {
        // The setup repo's HEAD is a merge. Cherry-picking it must specify the
        // parent to diff against; the UI always passes 1 (the first parent).
        let commits = try client.log(limit: 50)
        let merge = try XCTUnwrap(commits.first)
        XCTAssertTrue(merge.isMerge)
        let initial = try XCTUnwrap(commits.last)

        try run(["checkout", "-b", "pick-target", initial.hash])
        // Without a mainline git refuses outright ("is a merge but no -m
        // option was given") — and does so before writing sequencer state.
        XCTAssertThrowsError(try client.cherryPick(merge.hash))
        XCTAssertNil(client.inProgressOperation())

        // With mainline 1 the merge's first-parent diff (b.txt, brought in by
        // the feature branch) replays cleanly — and only that diff: c.txt was
        // already on the first parent and must not come along.
        try client.cherryPick(merge.hash, mainline: 1)
        XCTAssertNil(client.inProgressOperation())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("b.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("c.txt").path))
        XCTAssertFalse(try client.status().isDirty)
    }

    func testRevertMergeCommitNeedsMainline() throws {
        let commits = try client.log(limit: 50)
        let merge = try XCTUnwrap(commits.first)
        XCTAssertTrue(merge.isMerge)

        XCTAssertThrowsError(try client.revert(merge.hash))
        XCTAssertNil(client.inProgressOperation())

        // Reverting against the first parent undoes what the merge brought
        // onto main: b.txt disappears, a.txt/c.txt stay.
        try client.revert(merge.hash, mainline: 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("b.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("c.txt").path))
        let head = try XCTUnwrap(try client.log(limit: 1).first)
        XCTAssertTrue(head.subject.hasPrefix("Revert"))
        XCTAssertFalse(try client.status().isDirty)
    }

    func testSquashMergeStagesWithoutCommitting() throws {
        // A fresh divergence on top of the setup repo: side gets e.txt,
        // main gets f.txt.
        try run(["checkout", "-b", "side"])
        try write("side change\n", to: "e.txt")
        try run(["add", "e.txt"])
        try run(["commit", "-m", "Add e on side"])
        try run(["checkout", "main"])
        try write("main change\n", to: "f.txt")
        try run(["add", "f.txt"])
        try run(["commit", "-m", "Add f on main"])
        let commitsBefore = try client.log(limit: 50).count

        try client.merge("side", squash: true)

        // Changes staged, nothing committed, no sequencer state left behind.
        let status = try client.status()
        XCTAssertEqual(status.staged.map(\.path), ["e.txt"])
        XCTAssertNil(client.inProgressOperation())
        XCTAssertEqual(try client.log(limit: 50).count, commitsBefore)

        // The normal commit-box flow then lands a single-parent commit.
        try client.commit(message: "Squash side into main")
        let head = try XCTUnwrap(try client.log(limit: 1).first)
        XCTAssertEqual(head.parents.count, 1)
        XCTAssertEqual(head.subject, "Squash side into main")
    }

    func testNoFastForwardMergeCreatesMergeCommit() throws {
        // ff-side is strictly ahead of main — a plain merge would fast-forward
        // and record no merge commit.
        try run(["checkout", "-b", "ff-side"])
        try write("ff change\n", to: "g.txt")
        try run(["add", "g.txt"])
        try run(["commit", "-m", "Add g on ff-side"])
        try run(["checkout", "main"])

        try client.merge("ff-side", noFastForward: true)

        let head = try XCTUnwrap(try client.log(limit: 1).first)
        XCTAssertEqual(head.parents.count, 2)
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
        XCTAssertEqual(entry?.arguments?.first, "status")
        XCTAssertFalse(entry?.arguments?.contains(repoURL.path) ?? true)
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
