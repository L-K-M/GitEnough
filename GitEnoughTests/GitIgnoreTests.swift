import XCTest
@testable import GitEnough

/// Tests for the pure .gitignore append/escape rules behind "Ignore in .gitignore".
final class GitIgnoreTests: XCTestCase {

    func testEscapeLeavesPlainPathsAlone() {
        XCTAssertEqual(GitIgnore.escape("Sources/App.swift"), "Sources/App.swift")
        XCTAssertEqual(GitIgnore.escape("with space.txt"), "with space.txt")
    }

    func testEscapeEscapesGlobMetacharacters() {
        XCTAssertEqual(GitIgnore.escape("report[1].txt"), "report\\[1\\].txt")
        XCTAssertEqual(GitIgnore.escape("a*b?c.txt"), "a\\*b\\?c.txt")
        XCTAssertEqual(GitIgnore.escape("back\\slash.txt"), "back\\\\slash.txt")
    }

    func testEscapeProtectsLeadingCommentAndNegationMarkers() {
        // A file literally named "#notes.md" would otherwise produce a
        // comment line, "!keep.txt" a negation — neither ignores anything.
        XCTAssertEqual(GitIgnore.escape("#notes.md"), "\\#notes.md")
        XCTAssertEqual(GitIgnore.escape("!keep.txt"), "\\!keep.txt")
    }

    func testEscapeProtectsTrailingWhitespace() {
        XCTAssertEqual(GitIgnore.escape("notes "), "notes\\ ")
        XCTAssertEqual(GitIgnore.escape("notes  "), "notes\\ \\ ")
        XCTAssertEqual(GitIgnore.escape("notes\t "), "notes\\\t\\ ")
    }

    func testAppendingToEmptyFileAnchorsAtRoot() {
        XCTAssertEqual(GitIgnore.appending("build/output", to: ""),
                       "/build/output\n")
    }

    func testAppendingAddsNewlineSeparatorWhenMissing() {
        XCTAssertEqual(GitIgnore.appending("b.txt", to: "/a.txt"),
                       "/a.txt\n/b.txt\n")
        XCTAssertEqual(GitIgnore.appending("b.txt", to: "/a.txt\n"),
                       "/a.txt\n/b.txt\n")
    }

    func testAppendingIsIdempotent() {
        let once = GitIgnore.appending("report[1].txt", to: "")
        XCTAssertEqual(GitIgnore.appending("report[1].txt", to: once), once)
        // An unescaped glob is not equivalent to the literal bracketed name.
        XCTAssertEqual(GitIgnore.appending("report[1].txt", to: "report[1].txt\n"),
                       "report[1].txt\n/report\\[1\\].txt\n")
    }

    func testAppendingDetectsDuplicatesInCRLFFiles() {
        let crlf = "/a.txt\r\n/report\\[1\\].txt\r\n"
        XCTAssertEqual(GitIgnore.appending("report[1].txt", to: crlf), crlf)
    }

    func testCommentAndNegationLinesDontSuppressAppends() {
        // An existing *comment* "#notes.md" must not block ignoring a file
        // literally named "#notes.md" — comments ignore nothing.
        let withComment = "#notes.md\n"
        XCTAssertEqual(GitIgnore.appending("#notes.md", to: withComment),
                       "#notes.md\n/\\#notes.md\n")
        let withNegation = "!keep.txt\n"
        XCTAssertEqual(GitIgnore.appending("!keep.txt", to: withNegation),
                       "!keep.txt\n/\\!keep.txt\n")
        // But the escaped forms do count as duplicates.
        let already = "/\\#notes.md\n"
        XCTAssertEqual(GitIgnore.appending("#notes.md", to: already), already)
    }

    func testLeadingWhitespaceLinesDontFalsePositive() {
        // A pattern with a leading space matches a different name than the
        // trimmed candidate — it must not count as a duplicate.
        let existing = " /build/output\n"
        XCTAssertEqual(GitIgnore.appending("/build/output", to: existing),
                       " /build/output\n//build/output\n")
    }

    // MARK: - The bytes the caller appends

    /// `RepoViewModel.ignore` appends only the tail of `appending`'s result to
    /// the existing file, so the tail has to be taken in bytes. A .gitignore
    /// ending in a bare CR is the case that makes a Character-count slice wrong:
    /// the separator "\n" merges with it into one CRLF grapheme cluster, so the
    /// result has one Character *fewer* at the join than `existing` does.
    func testAppendedBytesSurviveACarriageReturnAtTheJoin() throws {
        let existing = "a\r"
        XCTAssertEqual(GitIgnore.appending("x", to: existing), "a\r\n/x\n")
        // `nil` here would mean the byte-prefix invariant broke, which is a
        // different failure from the wrong bytes — so unwrap explicitly rather
        // than letting a default paper over it.
        let bytes = try XCTUnwrap(GitIgnore.appendedBytes("x", to: existing))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\n/x\n")

        // The slice that must not be used: it swallows the separator, gluing the
        // new rule onto the previous one — "a\r/x\n" — which destroys the "a"
        // rule and leaves the new one matching nothing.
        let updated = GitIgnore.appending("x", to: existing)
        XCTAssertEqual(String(updated.dropFirst(existing.count)), "/x\n",
                       "precondition: the Character slice is short by the separator")
    }

    /// The general invariant the caller depends on: appending these bytes to the
    /// existing bytes reproduces `appending` exactly, for any input.
    func testAppendedBytesReconstructTheWholeFile() throws {
        let cases: [(String, String)] = [
            ("", "notes.md"),
            ("build/\n", "dist/"),
            ("build/", "dist/"),                 // no trailing newline
            ("a\r", "x"),                          // bare CR at the join
            ("a\r\n", "x"),                        // already CRLF-terminated
            ("/build\n", "build"),                 // already covered: no bytes
            ("\u{1F600}", "emoji.txt"),          // multi-byte final character
            ("e\u{301}", "combining.txt"),       // combining mark at the join
            ("a\u{2028}", "x"),                    // multi-byte Unicode line separator
            ("a\u{0B}", "x"),                      // single-byte newline that isn't \n
        ]
        for (existing, path) in cases {
            let expected = GitIgnore.appending(path, to: existing)
            let addition = try XCTUnwrap(
                GitIgnore.appendedBytes(path, to: existing),
                "the byte-prefix invariant broke for \(existing.debugDescription)")
            let rebuilt = Data(existing.utf8) + addition
            XCTAssertEqual(String(decoding: rebuilt, as: UTF8.self), expected,
                           "existing: \(existing.debugDescription), path: \(path)")
        }
    }

    /// Empty, and specifically *not* `nil`: "already covered" is an ordinary
    /// outcome the callers must be able to tell apart from a broken invariant.
    func testAppendedBytesAreEmptyWhenTheRuleAlreadyExists() throws {
        let bytes = try XCTUnwrap(GitIgnore.appendedBytes("build", to: "/build\n"),
                                  "already-covered must be empty, never nil")
        XCTAssertTrue(bytes.isEmpty)
    }

    /// The returned `Data` is zero-based, not a slice of the whole updated file.
    /// Appending works either way, but a slice indexed as `addition[0]` traps —
    /// the API shouldn't hand callers that edge.
    func testAppendedBytesAreZeroBased() throws {
        let addition = try XCTUnwrap(GitIgnore.appendedBytes("x", to: "build/\ndist/\n"))
        XCTAssertFalse(addition.isEmpty, "precondition: there is something to append")
        XCTAssertEqual(addition.startIndex, 0)
        XCTAssertEqual(addition.first, UInt8(ascii: "/"))
    }

    /// Pins the platform behaviour `RepoViewModel.ignore` relies on for its
    /// "no .gitignore yet" branch.
    ///
    /// A symlinked `.gitignore` is refused, in every shape, because git does
    /// not read one. The four tests this replaces pinned the *opposite*
    /// behaviour — resolving the whole chain and writing at its end — on a
    /// premise `testGitIgnoresASymlinkedGitignoreEntirely` below shows is false.
    ///
    /// Both directions matter. A dangling link lands in the creation branch
    /// (`fileExists` resolves symlinks, so it reports false); a live one lands
    /// in the append branch, which follows the link through an open handle. The
    /// check sits above both, so one assertion covers the pair.
    func testASymlinkedGitignoreIsRefusedRatherThanWrittenThrough() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let link = directory.appendingPathComponent(".gitignore")
        let outside = directory.appendingPathComponent("target-outside")

        // Dangling: the creation branch's shape.
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path),
                       "precondition: fileExists resolves the link, so a dangling one is 'missing'")
        assertRefusesSymlinkedIgnore(at: link, stillPointingTo: outside.path)
        // The link surviving is not the whole guarantee: a regression that
        // wrote through it *before* throwing would satisfy that assertion.
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path),
                       "nothing may be created through the dangling link")

        // Live: the append branch's shape. Same link, target now real.
        try "existing\n".write(to: outside, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path),
                      "precondition: a live link reports as existing")
        assertRefusesSymlinkedIgnore(at: link, stillPointingTo: outside.path)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "existing\n",
                       "the target must be untouched — this is the file a hostile "
                       + "repo would have aimed at")
    }

    /// A relative link to a sibling *inside* the repository is refused too. It
    /// is the shape that reads most legitimate, and it is the one the old
    /// chain-following code was written to serve — so if the refusal were going
    /// to be too narrow anywhere, it would be here.
    func testARelativeInRepoSymlinkIsRefusedToo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-symlink-relative-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        // The target exists, so the link is *live* — which routes through the
        // append branch. Without this the link dangles and lands in the creation
        // branch, which the absolute-link test above already covers, leaving the
        // shape this test is named for unexercised: a refusal that keyed off a
        // failed `fileExists` would have passed while writing through a live
        // in-repo link.
        let target = directory.appendingPathComponent("shared-ignore")
        try "existing\n".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent(".gitignore")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "shared-ignore")
        assertRefusesSymlinkedIgnore(at: link, stillPointingTo: "shared-ignore")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "existing\n",
                       "the in-repo target must be untouched too")
    }

    /// A regular file is not refused — the check must not reject the only shape
    /// that works.
    func testARegularGitignoreIsNotRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-regular-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(".gitignore")
        XCTAssertNoThrow(try RepoViewModel.requireRegularIgnoreFile(at: url),
                         "a missing .gitignore is the ordinary creation case")
        try "build\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try RepoViewModel.requireRegularIgnoreFile(at: url),
                         "and an existing regular file is the ordinary append case")
    }

    /// The measurement the refusal rests on: git does not read a symlinked
    /// `.gitignore`, so writing through the link puts the rule where git never
    /// looks. Asserted against real git rather than quoted in a comment,
    /// because the whole design turns on it — and the previous design turned on
    /// the opposite being true.
    ///
    /// The mechanism is `O_NOFOLLOW`, not a loop: git opens `.gitignore`
    /// without following symlinks, and "Too many levels of symbolic links" is
    /// just `strerror(ELOOP)`. Verified on a link that provably cannot cycle —
    /// one hop to a regular file, which `cat` reads through fine while git
    /// refuses it. Behaviour is version-dependent in principle, which is what
    /// makes this a test rather than a comment: it runs on both CI platforms,
    /// so git 2.43 (Ubuntu) and git 2.55 (macOS) are both pinned on every run,
    /// and a git that starts following the link fails here rather than silently
    /// making the product's refusal over-strict.
    func testGitIgnoresASymlinkedGitignoreEntirely() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-symlink-git-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        _ = try GitShell.shared.runChecked(["init", directory.path], in: nil)

        try "shared.txt\n".write(to: directory.appendingPathComponent("shared-ignore"),
                                 atomically: true, encoding: .utf8)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("shared.txt").path, contents: Data()),
            "precondition: shared.txt must exist, or its absence from status means nothing")

        func untracked() throws -> String {
            // Shielded from ambient config: a contributor's global
            // `core.excludesFile` naming `*.txt`, or `status.showUntrackedFiles
            // = no`, would drop `shared.txt` from this listing before the
            // symlink is even reached — and the first assertion below would
            // then fail saying git honoured a symlinked .gitignore, which is
            // the opposite of what happened.
            try GitShell.shared.runChecked(
                ["-C", directory.path,
                 "-c", "core.excludesFile=/dev/null",
                 "-c", "status.showUntrackedFiles=all",
                 "status", "--porcelain"], in: nil).stdout
        }

        let link = directory.appendingPathComponent(".gitignore")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "shared-ignore")
        XCTAssertTrue(try untracked().contains("shared.txt"),
                      "shared.txt must still be listed as untracked — git must NOT "
                      + "apply a rule from a symlinked .gitignore")

        try FileManager.default.removeItem(at: link)
        try "shared.txt\n".write(to: link, atomically: true, encoding: .utf8)
        XCTAssertFalse(try untracked().contains("shared.txt"),
                       "shared.txt is now absent from status, so the same rule in a "
                       + "regular file is applied — the symlink, not the rule, is "
                       + "what git rejects")
    }

    /// Asserts the refusal fired *and* left the link exactly as it was.
    private func assertRefusesSymlinkedIgnore(
        at link: URL, stillPointingTo destination: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try RepoViewModel.requireRegularIgnoreFile(at: link),
                             "a symlinked .gitignore must be refused",
                             file: file, line: line) { error in
            // Not just "something threw": a sandbox EACCES or a future refactor
            // failing for another reason would satisfy a bare assertion while
            // the symlink went unnoticed. Matched on the two terms rather than
            // the whole sentence, so rewording the copy is not a red suite.
            let description = "\(error)".lowercased()
            XCTAssertTrue(description.contains("symbolic link") && description.contains("git"),
                          "expected the symlink refusal, got \(error)",
                          file: file, line: line)
        }
        XCTAssertEqual(
            try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            destination,
            "a refusal must leave the link exactly as it found it",
            file: file, line: line)
    }

    func testGeneratedRulesMatchLiteralNamesWithGit() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        _ = try GitShell.shared.runChecked(["init"], in: directory)

        let literalNames = [
            "report[1].txt", "star*.txt", "question?.txt", "#notes.md",
            "!keep.txt", "back\\slash.txt", "one space ", "two spaces  ",
        ]
        let ignoreContents = literalNames.reduce(into: "") { contents, name in
            contents = GitIgnore.appending(name, to: contents)
        }
        try ignoreContents.write(to: directory.appendingPathComponent(".gitignore"),
                                 atomically: true, encoding: .utf8)

        for name in literalNames {
            let result = try GitShell.shared.run(
                ["check-ignore", "--no-index", "--quiet", "--", name], in: directory)
            XCTAssertEqual(result.exitCode, 0, "Expected generated rule to ignore \(name)")
        }

        for nearMiss in ["report1.txt", "star-anything.txt", "questionX.txt", "one space"] {
            let result = try GitShell.shared.run(
                ["check-ignore", "--no-index", "--quiet", "--", nearMiss], in: directory)
            XCTAssertEqual(result.exitCode, 1, "Generated rule unexpectedly ignored \(nearMiss)")
        }
    }
}
