import XCTest
@testable import GitEnough

/// Tests for the git-output parsers: porcelain v2 status, log records, refs,
/// remotes, stash, name-status, and quoted paths.
final class GitParsersTests: XCTestCase {

    private let f = GitParsers.fieldSep
    private let r = GitParsers.recordSep

    // MARK: - Log

    func testParseLog() {
        let output = [
            ["abc123", "def456", "Lukas Mathis", "l@example.com",
             "2026-08-17T19:00:00+02:00", "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0", "Ship it"].joined(separator: f),
            ["def456", "", "Claude", "c@example.com",
             "2026-08-17T18:00:00+02:00", "", "Initial commit"].joined(separator: f),
        ].joined(separator: r) + r + "\n"

        let commits = GitParsers.parseLog(output)
        XCTAssertEqual(commits.count, 2)

        XCTAssertEqual(commits[0].hash, "abc123")
        XCTAssertEqual(commits[0].parents, ["def456"])
        XCTAssertEqual(commits[0].author, "Lukas Mathis")
        XCTAssertEqual(commits[0].subject, "Ship it")
        XCTAssertNotNil(commits[0].date)
        // "HEAD -> main" expands to two chips (HEAD marker + branch), plus
        // origin/main and the tag.
        XCTAssertEqual(commits[0].decorations.count, 4)
        XCTAssertEqual(commits[0].decorations[0].kind, .head)
        XCTAssertEqual(commits[0].decorations[1],
                       RefDecoration(kind: .localBranch, name: "main"))
        XCTAssertEqual(commits[0].decorations[2],
                       RefDecoration(kind: .remoteBranch, name: "origin/main"))
        XCTAssertEqual(commits[0].decorations[3],
                       RefDecoration(kind: .tag, name: "v1.0"))
        XCTAssertTrue(commits[0].isHead)
        XCTAssertFalse(commits[0].isMerge)

        XCTAssertEqual(commits[1].parents, [])
        XCTAssertTrue(commits[1].decorations.isEmpty)
    }

    func testParseLogDecorationsClassifyRemoteBranches() {
        let decorations = GitParsers.parseDecorations("refs/remotes/origin/feature, HEAD")
        XCTAssertEqual(decorations[0], RefDecoration(kind: .remoteBranch, name: "origin/feature"))
        XCTAssertEqual(decorations[1], RefDecoration(kind: .head, name: "HEAD"))
    }

    func testParseLogDecorationsClassifySlashedLocalBranchAsLocal() {
        // The short-form contains-"/" heuristic used to mischip the most common
        // branch naming convention as a remote branch; --decorate=full output
        // makes the classification exact.
        let decorations = GitParsers.parseDecorations(
            "HEAD -> refs/heads/feature/foo, refs/remotes/origin/feature/foo")
        XCTAssertEqual(decorations[0], RefDecoration(kind: .head, name: "HEAD"))
        XCTAssertEqual(decorations[1], RefDecoration(kind: .localBranch, name: "feature/foo"))
        XCTAssertEqual(decorations[2], RefDecoration(kind: .remoteBranch, name: "origin/feature/foo"))
    }

    func testParseLogDecorationsDropRemoteHeadSymref() {
        // refs/remotes/<remote>/HEAD decorates the default branch's tip in every
        // repo with a remote; it is a symref, not a branch, and names nothing
        // the user can act on — branches() filters it too.
        let decorations = GitParsers.parseDecorations(
            "refs/remotes/origin/HEAD, refs/remotes/origin/main")
        XCTAssertEqual(decorations, [RefDecoration(kind: .remoteBranch, name: "origin/main")])
    }

    func testParseLogDecorationsShortFormFallback() {
        // Hand-written or pre---decorate=full output (no refs/ prefix) keeps the
        // old heuristic: "/" guesses remote, bare names are local.
        let decorations = GitParsers.parseDecorations("origin/feature, HEAD, stable")
        XCTAssertEqual(decorations[0], RefDecoration(kind: .remoteBranch, name: "origin/feature"))
        XCTAssertEqual(decorations[1], RefDecoration(kind: .head, name: "HEAD"))
        XCTAssertEqual(decorations[2], RefDecoration(kind: .localBranch, name: "stable"))
    }

    func testParseLogDecorationsShortFormHeadTargetStaysLocal() {
        // HEAD only ever points at a local branch — even a slashed one, which
        // the fallback's "/"-guesses-remote heuristic would otherwise mischip.
        let decorations = GitParsers.parseDecorations("HEAD -> feature/foo, stable")
        XCTAssertEqual(decorations, [RefDecoration(kind: .head, name: "HEAD"),
                                     RefDecoration(kind: .localBranch, name: "feature/foo"),
                                     RefDecoration(kind: .localBranch, name: "stable")])
    }

    func testParseLogDecorationsTolerateEmptyParts() {
        // A trailing ", " (comma clings to the last name after the
        // whitespace trim) and ", ," must not produce tainted or
        // empty-name chips.
        XCTAssertEqual(GitParsers.parseDecorations("HEAD -> main, "),
                       [RefDecoration(kind: .head, name: "HEAD"),
                        RefDecoration(kind: .localBranch, name: "main")])
        XCTAssertEqual(GitParsers.parseDecorations("HEAD -> main, , stable"),
                       [RefDecoration(kind: .head, name: "HEAD"),
                        RefDecoration(kind: .localBranch, name: "main"),
                        RefDecoration(kind: .localBranch, name: "stable")])
    }

    func testParseLogDecorationsTagHeadTargetClassifiesExactly() {
        // A tag target must not leak "refs/tags/…" into the chip name.
        let decorations = GitParsers.parseDecorations("HEAD -> tag: refs/tags/v1.0")
        XCTAssertEqual(decorations, [RefDecoration(kind: .head, name: "HEAD"),
                                     RefDecoration(kind: .tag, name: "v1.0")])
    }

    func testParseLogDecorationsDropUnknownRefNamespaces() {
        // refs/ namespaces that are neither branches nor tags (forge-specific
        // refs survive the hiddenRefs exclusion) must not become bogus
        // remote-branch chips bearing the full refname.
        XCTAssertTrue(GitParsers.parseDecorations("refs/stash").isEmpty)
        let decorations = GitParsers.parseDecorations(
            "refs/remotes/origin/main, refs/changes/12/345/1, refs/merge-requests/7/head")
        XCTAssertEqual(decorations, [RefDecoration(kind: .remoteBranch, name: "origin/main")])
    }

    func testParseLogToleratesBlankRecords() {
        XCTAssertEqual(GitParsers.parseLog("").count, 0)
        XCTAssertEqual(GitParsers.parseLog("\n\(r)\n").count, 0)
    }

    // MARK: - Status (porcelain v2)

    func testParseStatusWithBranchHeadersAndChanges() {
        let output = """
        # branch.oid 1234567890abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 M. N... 100644 100644 100644 abc def staged.txt
        1 .M N... 100644 100644 100644 abc def unstaged.txt
        1 AM N... 100644 100644 100644 abc def both.txt
        2 R. N... 100644 100644 100644 abc def R100 new name.txt\told name.txt
        ? untracked file.txt

        """
        let status = GitParsers.parseStatus(output)
        XCTAssertEqual(status.head, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertFalse(status.isDetached)

        // staged.txt: staged only; both.txt: staged; new name.txt: staged rename.
        XCTAssertEqual(status.staged.map(\.path), ["staged.txt", "both.txt", "new name.txt"])
        // unstaged.txt + both.txt modified in worktree; untracked file.txt.
        XCTAssertEqual(status.unstaged.map(\.path), ["unstaged.txt", "both.txt", "untracked file.txt"])

        let rename = status.staged.first { $0.path == "new name.txt" }
        XCTAssertEqual(rename?.stagedStatus, .renamed)
        XCTAssertEqual(rename?.originalPath, "old name.txt")

        XCTAssertTrue(status.isDirty)
        // `both.txt` is partially staged and appears in both arrays, but it is
        // one changed path in the user-facing count.
        XCTAssertEqual(status.changeCount, 5)
    }

    func testParseStatusDetachedAndConflicted() {
        let output = """
        # branch.oid 1234567890abcdef
        # branch.head (detached)
        u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt

        """
        let status = GitParsers.parseStatus(output)
        XCTAssertTrue(status.isDetached)
        XCTAssertNil(status.head)
        XCTAssertEqual(status.conflicted.map(\.path), ["conflict.txt"])
        // Conflicted files are surfaced separately, not as ordinary staged changes.
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertTrue(status.unstaged.isEmpty)
        XCTAssertTrue(status.isDirty)
        XCTAssertEqual(status.changeCount, 1)
    }

    func testParseStatusUnbornBranch() {
        let output = """
        # branch.oid (initial)
        # branch.head main
        ? README.md

        """
        let status = GitParsers.parseStatus(output)
        XCTAssertTrue(status.isUnborn)
        XCTAssertFalse(status.isDetached)
        XCTAssertEqual(status.unstaged.map(\.path), ["README.md"])
    }

    // MARK: - Branches

    func testParseBranches() {
        let line1 = ["refs/heads/main", "main", "origin/main", "[ahead 1, behind 2]", "*"]
            .joined(separator: f)
        let line2 = ["refs/heads/feature", "feature", "", "", ""]
            .joined(separator: f)
        let line3 = ["refs/remotes/origin/main", "origin/main", "", "", ""]
            .joined(separator: f)
        let line4 = ["refs/remotes/origin/HEAD", "origin/HEAD", "", "", ""]
            .joined(separator: f)
        let branches = GitParsers.parseBranches([line1, line2, line3, line4].joined(separator: "\n"))

        XCTAssertEqual(branches.count, 3) // origin/HEAD symref is skipped
        let main = branches[0]
        XCTAssertEqual(main.name, "main")
        XCTAssertFalse(main.isRemote)
        XCTAssertTrue(main.isHead)
        XCTAssertEqual(main.upstream, "origin/main")
        XCTAssertEqual(main.ahead, 1)
        XCTAssertEqual(main.behind, 2)

        XCTAssertTrue(branches[1].upstream == nil)
        XCTAssertTrue(branches[2].isRemote)
        XCTAssertEqual(branches[2].localNameForRemote, "main")
    }

    // MARK: - Remotes

    func testParseRemotesCollapsesFetchAndPush() {
        let output = "origin\thttps://github.com/L-K-M/GitEnough.git (fetch)\n" +
                     "origin\thttps://github.com/L-K-M/GitEnough.git (push)\n" +
                     "upstream\tgit@github.com:apple/swift.git (fetch)\n"
        let remotes = GitParsers.parseRemotes(output)
        XCTAssertEqual(remotes.count, 2)
        XCTAssertEqual(remotes[0].name, "origin")
        XCTAssertEqual(remotes[0].url, "https://github.com/L-K-M/GitEnough.git")
        XCTAssertEqual(remotes[0].displayHost, "github.com/L-K-M/GitEnough")
        XCTAssertEqual(remotes[1].displayHost, "github.com/apple/swift")
    }

    func testDisplayHostStripsOnlyTrailingGitSuffix() {
        // ".git" occurring inside the name must survive — only a suffix goes.
        XCTAssertEqual(Remote(name: "o", url: "https://github.com/u/u.github.io.git").displayHost,
                       "github.com/u/u.github.io")
        XCTAssertEqual(Remote(name: "o", url: "https://github.com/u/u.github.io").displayHost,
                       "github.com/u/u.github.io")
        XCTAssertEqual(Remote(name: "o", url: "git@github.com:u/my.gitops.git").displayHost,
                       "github.com/u/my.gitops")
        XCTAssertEqual(Remote(name: "o", url: "git@github.com:u/plain.git").displayHost,
                       "github.com/u/plain")
        // ".git" inside the HOST must survive too (the old replace-all
        // mangled hostnames like my.gitlab.dev).
        XCTAssertEqual(Remote(name: "o", url: "git@my.gitlab.dev:u/repo.git").displayHost,
                       "my.gitlab.dev/u/repo")
        XCTAssertEqual(Remote(name: "o", url: "https://example.com/team/repo").displayHost,
                       "example.com/team/repo")
    }

    // MARK: - Stash

    func testParseStash() {
        let output = "stash@{0}\(f)WIP on main: abc1234 Fix the thing\n" +
                     "stash@{1}\(f)On feature: experiments\n"
        let entries = GitParsers.parseStash(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].branch, "main")
        XCTAssertEqual(entries[0].message, "Fix the thing")
        XCTAssertEqual(entries[1].index, 1)
        XCTAssertEqual(entries[1].branch, "feature")
        XCTAssertEqual(entries[1].message, "experiments")
        XCTAssertEqual(entries[0].ref, "stash@{0}")
    }

    // MARK: - Name-status (commit files)

    func testParseNameStatus() {
        let output = "M\tSources/App.swift\nA\tREADME.md\nR100\told.txt\tnew.txt\nD\tgone.txt\n"
        let files = GitParsers.parseNameStatus(output)
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(files[0].status, .modified)
        XCTAssertEqual(files[1].status, .added)
        XCTAssertEqual(files[2].status, .renamed)
        XCTAssertEqual(files[2].originalPath, "old.txt")
        XCTAssertEqual(files[2].path, "new.txt")
        XCTAssertEqual(files[3].status, .deleted)
    }

    // MARK: - Commit detail

    func testParseCommitDetail() {
        let header = ["abc123", "Lukas", "l@example.com", "2026-08-17T19:00:00+02:00",
                      "p1 p2", "Merge branch 'x'", "Body line one\n\nBody line two"]
            .joined(separator: f)
        let output = header + r + "M\tSources/App.swift\nA\tNew.swift\n"
        guard let detail = GitParsers.parseCommitDetail(output) else {
            XCTFail("expected a parsed detail")
            return
        }
        XCTAssertEqual(detail.hash, "abc123")
        XCTAssertEqual(detail.parents, ["p1", "p2"])
        XCTAssertEqual(detail.subject, "Merge branch 'x'")
        XCTAssertEqual(detail.body, "Body line one\n\nBody line two")
        XCTAssertEqual(detail.files.count, 2)
        XCTAssertEqual(detail.files[1].path, "New.swift")
    }

    // MARK: - Quoted paths

    func testUnquoteGitPath() {
        XCTAssertEqual(GitParsers.unquoteGitPath("plain.txt"), "plain.txt")
        XCTAssertEqual(GitParsers.unquoteGitPath("\"with space.txt\""), "with space.txt")
        XCTAssertEqual(GitParsers.unquoteGitPath("\"tab\\tname.txt\""), "tab\tname.txt")
        XCTAssertEqual(GitParsers.unquoteGitPath("\"quote\\\"name.txt\""), "quote\"name.txt")
        XCTAssertEqual(GitParsers.unquoteGitPath("\"back\\\\slash.txt\""), "back\\slash.txt")
        // core.quotepath renders non-ASCII as octal UTF-8 bytes: “ü” = \303\274.
        XCTAssertEqual(GitParsers.unquoteGitPath("\"m\\303\\274nchen.txt\""), "münchen.txt")
    }

    // MARK: - Diff parser

    func testDiffParserClassifiesLines() {
        let diff = """
        diff --git a/a.swift b/a.swift
        index 111..222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@
         context
        -removed
        +added
        \\ No newline at end of file
        """
        let lines = DiffParser.parse(diff)
        XCTAssertEqual(lines.map(\.kind), [
            .fileHeader, .fileHeader, .fileHeader, .fileHeader,
            .hunk, .context, .deletion, .addition, .meta,
        ])
    }

    func testDiffParserTruncatesHugeDiffs() {
        let big = (0..<5000).map { "line \($0)" }.joined(separator: "\n")
        let lines = DiffParser.parse(big, maxLines: 100)
        XCTAssertEqual(lines.count, 101)
        XCTAssertEqual(lines.last?.kind, .meta)
    }
}
