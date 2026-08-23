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
