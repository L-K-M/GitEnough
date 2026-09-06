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
    func testAppendedBytesSurviveACarriageReturnAtTheJoin() {
        let existing = "a\r"
        XCTAssertEqual(GitIgnore.appending("x", to: existing), "a\r\n/x\n")
        XCTAssertEqual(
            String(decoding: GitIgnore.appendedBytes("x", to: existing), as: UTF8.self),
            "\n/x\n")

        // The slice that must not be used: it swallows the separator, gluing the
        // new rule onto the previous one — "a\r/x\n" — which destroys the "a"
        // rule and leaves the new one matching nothing.
        let updated = GitIgnore.appending("x", to: existing)
        XCTAssertEqual(String(updated.dropFirst(existing.count)), "/x\n",
                       "precondition: the Character slice is short by the separator")
    }

    /// The general invariant the caller depends on: appending these bytes to the
    /// existing bytes reproduces `appending` exactly, for any input.
    func testAppendedBytesReconstructTheWholeFile() {
        let cases: [(String, String)] = [
            ("", "notes.md"),
            ("build/\n", "dist/"),
            ("build/", "dist/"),                 // no trailing newline
            ("a\r", "x"),                        // CR at the join
            ("\u{1F600}", "emoji.txt"),          // multi-byte final character
            ("e\u{301}", "combining.txt"),       // combining mark at the join
        ]
        for (existing, path) in cases {
            let expected = GitIgnore.appending(path, to: existing)
            let rebuilt = Data(existing.utf8) + GitIgnore.appendedBytes(path, to: existing)
            XCTAssertEqual(String(decoding: rebuilt, as: UTF8.self), expected,
                           "existing: \(existing.debugDescription), path: \(path)")
        }
    }

    func testAppendedBytesAreEmptyWhenTheRuleAlreadyExists() {
        XCTAssertTrue(GitIgnore.appendedBytes("build", to: "/build\n").isEmpty)
    }

    /// The returned `Data` is zero-based, not a slice of the whole updated file.
    /// Appending works either way, but a slice indexed as `addition[0]` traps —
    /// the API shouldn't hand callers that edge.
    func testAppendedBytesAreZeroBased() {
        let addition = GitIgnore.appendedBytes("x", to: "build/\ndist/\n")
        XCTAssertFalse(addition.isEmpty, "precondition: there is something to append")
        XCTAssertEqual(addition.startIndex, 0)
        XCTAssertEqual(addition[0], UInt8(ascii: "/"))
    }

    /// Pins the platform behaviour `RepoViewModel.ignore` relies on for its
    /// "no .gitignore yet" branch.
    ///
    /// `fileExists(atPath:)` **resolves** symlinks, so a `.gitignore` symlinked
    /// to a target that doesn't exist yet reports false and lands in that
    /// branch. `Data.write(to:options:.atomic)` there would replace the user's
    /// symlink with a regular file; `createFile` opens with `O_CREAT`, which
    /// follows the final symlink and creates its target instead. Verified at the
    /// syscall level on Linux; this pins it on macOS too.
    func testCreatingThroughADanglingSymlinkWritesTheTargetNotTheLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let link = directory.appendingPathComponent(".gitignore")
        let target = directory.appendingPathComponent("shared-ignore")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path),
                       "precondition: fileExists resolves the link, so a dangling one is 'missing'")

        XCTAssertTrue(FileManager.default.createFile(atPath: link.path, contents: nil))
        let handle = try FileHandle(forWritingTo: link)
        defer { try? handle.close() }
        try handle.write(contentsOf: GitIgnore.appendedBytes("build", to: ""))

        // Throws if .gitignore is no longer a symlink, which is the regression.
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            target.path,
            "the symlink must survive, not be replaced by a regular file")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "/build\n",
                       "and the rule must land in its target")
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
