import XCTest
@testable import GitEnough

/// Tests for unified-diff classification and intraline (word-level) emphasis.
final class DiffParserTests: XCTestCase {

    private func emphasizedText(of line: DiffLine) -> [String] {
        line.emphasizedRanges.sorted { $0.lowerBound < $1.lowerBound }
            .map { String(line.text[$0]) }
    }

    /// Line text → kind for assertions. Fails when two identical texts classify
    /// differently, which plain first-wins would silently hide.
    private func kindsByText(_ lines: [DiffLine]) -> [String: DiffLine.Kind] {
        var result: [String: DiffLine.Kind] = [:]
        for line in lines {
            if let existing = result[line.text] {
                XCTAssertEqual(existing, line.kind,
                               "\(line.text.debugDescription) classified two ways")
            }
            result[line.text] = line.kind
        }
        return result
    }

    private func first(_ lines: [DiffLine], kind: DiffLine.Kind) -> DiffLine? {
        lines.first { $0.kind == kind }
    }

    /// Assert that every body line in a parsed fixture really opens with
    /// `columns` marker columns.
    ///
    /// Three review rounds have read the combined fixtures below as carrying
    /// one leading space where they carry two, because a rendered diff is a
    /// poor place to count whitespace. Whitespace that load-bearing should not
    /// rest on the eye: a fixture silently reduced to one column still parses,
    /// just against a shape git never emits, and the kind assertions alone
    /// would not notice. This reads the width back out of the fixture.
    private func assertBodyLinesCarryMarkerColumns(
        _ columns: Int, _ lines: [DiffLine],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let bodyKinds: [DiffLine.Kind] = [.context, .addition, .deletion]
        for parsed in lines where bodyKinds.contains(parsed.kind) {
            let markers = parsed.text.prefix(columns)
            XCTAssertEqual(markers.count, columns,
                           "\(parsed.text.debugDescription) is too short to carry "
                           + "\(columns) marker column(s)", file: file, line: line)
            XCTAssertTrue(markers.allSatisfy { $0 == " " || $0 == "+" || $0 == "-" },
                          "\(parsed.text.debugDescription) must open with \(columns) "
                          + "marker column(s), one per parent", file: file, line: line)
        }
    }

    func testChangedWordsAreEmphasizedOnBothSides() {
        let diff = """
diff --git a/f.txt b/f.txt
index 1234567..89abcde 100644
--- a/f.txt
+++ b/f.txt
@@ -1 +1 @@
-the quick fox
+the slow fox
"""
        let lines = DiffParser.parse(diff)
        XCTAssertEqual(emphasizedText(of: first(lines, kind: .deletion)!), ["quick"])
        XCTAssertEqual(emphasizedText(of: first(lines, kind: .addition)!), ["slow"])
        // Context and header lines are never emphasized.
        XCTAssertTrue(lines.filter { $0.kind != .deletion && $0.kind != .addition }
            .allSatisfy { $0.emphasizedRanges.isEmpty })
    }

    func testInsertedWordEmphasizesOnlyOnTheAdditionSide() {
        let diff = """
@@ -1 +1 @@
-hello world
+hello brave world
"""
        let lines = DiffParser.parse(diff)
        XCTAssertTrue(first(lines, kind: .deletion)!.emphasizedRanges.isEmpty)
        XCTAssertEqual(emphasizedText(of: first(lines, kind: .addition)!), ["brave"])
    }

    func testPrefixColumnIsNeverEmphasized() {
        let diff = """
@@ -1 +1 @@
-old ending
+new ending
"""
        let lines = DiffParser.parse(diff)
        for line in lines where !line.emphasizedRanges.isEmpty {
            for range in line.emphasizedRanges {
                XCTAssertGreaterThan(range.lowerBound, line.text.startIndex,
                                     "the +/- prefix must not be part of the emphasis")
            }
        }
    }

    func testIdenticalWordContentGetsNoEmphasis() {
        let diff = """
@@ -1 +1 @@
-same words
+same words
"""
        let lines = DiffParser.parse(diff)
        XCTAssertTrue(lines.allSatisfy { $0.emphasizedRanges.isEmpty })
    }

    func testMultiLineRunsPairKthDeletionWithKthAddition() {
        let diff = """
@@ -1,2 +1,2 @@
-alpha one
-beta two
+alpha uno
+beta dos
"""
        let lines = DiffParser.parse(diff)
        let deletions = lines.filter { $0.kind == .deletion }
        let additions = lines.filter { $0.kind == .addition }
        XCTAssertEqual(emphasizedText(of: deletions[0]), ["one"])
        XCTAssertEqual(emphasizedText(of: deletions[1]), ["two"])
        XCTAssertEqual(emphasizedText(of: additions[0]), ["uno"])
        XCTAssertEqual(emphasizedText(of: additions[1]), ["dos"])
    }

    // MARK: - Classification

    /// Inside a hunk the leading character belongs to the diff, not the
    /// content, so a deleted line whose text starts with "--" arrives as "---"
    /// and an added line starting with "++" arrives as "+++". Classifying by
    /// prefix alone painted both grey as file headers — in the pane whose only
    /// job is showing what changed.
    func testHunkContentThatLooksLikeAFileHeaderIsStillAChange() {
        let diff = """
diff --git a/k8s.yaml b/k8s.yaml
index 1234567..89abcde 100644
--- a/k8s.yaml
+++ b/k8s.yaml
@@ -1,5 +1,4 @@
 kind: Service
----
--- a comment removed by SQL
-++ not a header either
+++i;
+--- a YAML separator added
 kind: Deployment
"""
        let lines = DiffParser.parse(diff)
        let byText = kindsByText(lines)

        // The real file headers, which appear before the first @@.
        XCTAssertEqual(byText["--- a/k8s.yaml"], .fileHeader)
        XCTAssertEqual(byText["+++ b/k8s.yaml"], .fileHeader)
        XCTAssertEqual(byText["diff --git a/k8s.yaml b/k8s.yaml"], .fileHeader)

        // Everything after the @@ is content, whatever it starts with.
        XCTAssertEqual(byText["----"], .deletion, "a deleted YAML document separator")
        XCTAssertEqual(byText["--- a comment removed by SQL"], .deletion)
        XCTAssertEqual(byText["-++ not a header either"], .deletion)
        XCTAssertEqual(byText["+++i;"], .addition, "an added C pre-increment")
        XCTAssertEqual(byText["+--- a YAML separator added"], .addition)
        XCTAssertEqual(byText[" kind: Service"], .context)
    }

    /// A second file's header ends the previous file's hunk, even though no
    /// blank line separates them.
    func testANewFileHeaderEndsThePreviousHunk() {
        let diff = """
@@ -1 +1 @@
-old
+new
diff --git a/b.txt b/b.txt
index 111..222 100644
--- a/b.txt
+++ b/b.txt
@@ -1 +1 @@
----
+ok
"""
        let lines = DiffParser.parse(diff)
        let byText = kindsByText(lines)
        // Counted, because `kindsByText` collapses the fixture into a
        // dictionary: a parser that dropped a line entirely would still
        // satisfy every lookup below.
        XCTAssertEqual(lines.count, 10, "the whole fixture should survive parsing")
        XCTAssertEqual(byText["diff --git a/b.txt b/b.txt"], .fileHeader)
        XCTAssertEqual(byText["--- a/b.txt"], .fileHeader,
                       "the second file's header must not be read as hunk content")
        XCTAssertEqual(byText["+++ b/b.txt"], .fileHeader)
        XCTAssertEqual(byText["----"], .deletion,
                       "…but content in the second file's hunk still is content")
    }

    func testNoNewlineMarkerAndBinaryNoticeStayMeta() {
        let diff = """
diff --git a/f b/f
--- a/f
+++ b/f
@@ -1 +1 @@
-a
+b
\\ No newline at end of file
diff --git a/img.png b/img.png
index 4d04a58..91dc45e 100644
Binary files a/img.png and b/img.png differ
"""
        let lines = DiffParser.parse(diff)
        let byText = kindsByText(lines)
        XCTAssertEqual(lines.count, 10, "the whole fixture should survive parsing")
        XCTAssertEqual(byText["\\ No newline at end of file"], .meta)
        // git puts an `index` line between the header and the notice (verified
        // against 2.43), so the notice is never the line right after `diff
        // --git`. Omitting it made the fixture pin an ordering git never emits.
        XCTAssertEqual(byText["index 4d04a58..91dc45e 100644"], .fileHeader)
        XCTAssertEqual(byText["Binary files a/img.png and b/img.png differ"], .meta)
    }

    /// Dropping the phantom trailing component changed a public behaviour:
    /// `parse("")` used to return one blank context line and now returns none.
    /// Pinned so a future refactor can't quietly reintroduce the phantom row,
    /// and so callers rendering an empty state have something to rely on.
    func testEmptyInputYieldsNoLines() {
        XCTAssertEqual(DiffParser.parse("").map(\.kind), [])
        // A lone separator is still one (contentless) line, not zero.
        XCTAssertEqual(DiffParser.parse("\n").map(\.kind), [.context])
    }

    /// A trailing newline is a separator, not a line — the split must drop the
    /// empty final component while keeping blank lines that are hunk content.
    func testATrailingNewlineDoesNotAddAPhantomLine() {
        // Every git diff ends in a newline; splitting on it leaves an empty
        // final component that used to render as a blank context row and spend
        // one line of the truncation budget.
        let lines = DiffParser.parse("@@ -1 +1 @@\n-a\n+b\n")
        XCTAssertEqual(lines.map(\.text), ["@@ -1 +1 @@", "-a", "+b"])

        // An empty line inside the body is still content and must survive.
        let withBlank = DiffParser.parse("@@ -1,3 +1,3 @@\n a\n\n b\n")
        XCTAssertEqual(withBlank.map(\.text), ["@@ -1,3 +1,3 @@", " a", "", " b"])
        XCTAssertEqual(withBlank.map(\.kind), [.hunk, .context, .context, .context])
    }

    func testDissimilarityIndexIsAFileHeader() {
        // git emits this for a broken-out rewrite (-B). Nothing in the app
        // passes -B today, so this pins the classification before it can.
        let lines = DiffParser.parse("""
diff --git a/f b/f
dissimilarity index 96%
--- a/f
+++ b/f
""")
        XCTAssertEqual(kindsByText(lines)["dissimilarity index 96%"], .fileHeader)
    }

    /// `git diff` on a conflicted path emits a **combined** diff: `diff --cc`,
    /// `@@@` hunks, and one marker column per parent. Captured verbatim from
    /// git 2.43 on a two-branch content conflict.
    ///
    /// Two things were wrong before. The `diff --cc` line fell through every
    /// header prefix and rendered as hunk content, and — worse — a line like
    /// ` +OURS`, whose *second* column marks it as added, was classified from
    /// its first column alone and came out as unchanged context. Mid-merge,
    /// that told the user their own side's new line wasn't a change.
    func testACombinedDiffReadsBothMarkerColumns() {
        let diff = """
diff --cc a.txt
index daf31e1,594dc4f..0000000
--- a/a.txt
+++ b/a.txt
@@@ -1,3 -1,3 +1,7 @@@
  one
++<<<<<<< HEAD
 +OURS
++=======
+ THEIRS
++>>>>>>> other
  three
"""
        let lines = DiffParser.parse(diff)
        assertBodyLinesCarryMarkerColumns(2, lines)
        XCTAssertEqual(lines.map(\.kind), [
            .fileHeader,   // diff --cc a.txt
            .fileHeader,   // index …
            .fileHeader,   // --- a/a.txt
            .fileHeader,   // +++ b/a.txt
            .hunk,         // @@@ … @@@
            .context,      // "  one"
            .addition,     // "++<<<<<<< HEAD"
            .addition,     // " +OURS"      ← second column
            .addition,     // "++======="
            .addition,     // "+ THEIRS"    ← first column
            .addition,     // "++>>>>>>> other"
            .context,      // "  three"
        ])
    }

    /// Removals in a combined diff, which the addition test above cannot reach.
    /// Captured from git 2.43: a merge resolved by dropping lines both parents
    /// had, shown with `git show --cc --format=`.
    ///
    /// ` -THEIRS` is the exact mirror of the ` +OURS` case — marked removed by
    /// its *second* column while its first is a space. A fix that only promoted
    /// lines containing `+` would leave it reading as unchanged content.
    func testACombinedDiffMarksRemovalsInEitherColumn() {
        let diff = """
diff --cc a.txt
index 5a7db94,a79868b..f7628f4
--- a/a.txt
+++ b/a.txt
@@@ -1,4 -1,4 +1,2 @@@
  keep
--doomed
--both-had
- OURS
 -THEIRS
++RESOLVED
"""
        let lines = DiffParser.parse(diff)
        assertBodyLinesCarryMarkerColumns(2, lines)
        XCTAssertEqual(lines.map(\.kind), [
            .fileHeader,   // diff --cc a.txt
            .fileHeader,   // index …
            .fileHeader,   // --- a/a.txt
            .fileHeader,   // +++ b/a.txt
            .hunk,         // @@@ … @@@
            .context,      // "  keep"
            .deletion,     // "--doomed"        both parents
            .deletion,     // "--both-had"      both parents
            .deletion,     // "- OURS"          first column
            .deletion,     // " -THEIRS"        ← second column
            .addition,     // "++RESOLVED"
        ])
    }

    /// The single-column analogue is `testASecondFileClosesTheFirstFilesHunk`;
    /// the combined case is where it bites hardest. Inside a `@@@` hunk the
    /// classifier reads *two* columns, so the second file's `--- a/b.txt`
    /// presents `--` and reads as removed content for as long as the hunk is
    /// still open. It closes on `diff --cc b.txt` — the first line whose
    /// columns are not markers — which then has to classify as a header rather
    /// than falling through to context, so this covers both halves at once.
    /// Captured verbatim from git 2.43: two files conflicted by one merge.
    func testACombinedDiffHeaderClosesThePreviousCombinedHunk() {
        let diff = """
diff --cc a.txt
index daf31e1,594dc4f..0000000
--- a/a.txt
+++ b/a.txt
@@@ -1,3 -1,3 +1,7 @@@
  one
++<<<<<<< HEAD
 +OURS
++=======
+ THEIRS
++>>>>>>> other
  three
diff --cc b.txt
index d91eb2d,5a70c8a..0000000
--- a/b.txt
+++ b/b.txt
@@@ -1,3 -1,3 +1,7 @@@
  x
++<<<<<<< HEAD
 +OURS-B
++=======
+ THEIRS-B
++>>>>>>> other
  z
"""
        let lines = DiffParser.parse(diff)
        assertBodyLinesCarryMarkerColumns(2, lines)
        XCTAssertEqual(lines.count, 24, "the whole fixture should survive parsing")

        // The four header lines of the *second* file are the whole point.
        let second = lines[12..<16]
        XCTAssertEqual(second.map(\.text), ["diff --cc b.txt",
                                            "index d91eb2d,5a70c8a..0000000",
                                            "--- a/b.txt",
                                            "+++ b/b.txt"])
        XCTAssertEqual(second.map(\.kind), [.fileHeader, .fileHeader, .fileHeader, .fileHeader],
                       "the second file's headers must not inherit the first file's hunk")

        // And the second file's body still classifies by both columns, so
        // closing the hunk did not leave the marker width stale either.
        XCTAssertEqual(lines[16...].map(\.kind),
                       [.hunk, .context, .addition, .addition, .addition,
                        .addition, .addition, .context])
    }

    /// The next file's `diff --git` closes an open hunk, so its `--- `/`+++ `
    /// lines are headers again rather than content.
    func testASecondFileClosesTheFirstFilesHunk() {
        let diff = """
@@ -1 +1 @@
-a
+b
diff --git a/g b/g
index 0000000..1111111 100644
--- a/g
+++ b/g
@@ -1 +1 @@
-x
+y
"""
        XCTAssertEqual(DiffParser.parse(diff).map(\.kind), [
            .hunk, .deletion, .addition,
            .fileHeader, .fileHeader, .fileHeader, .fileHeader,
            .hunk, .deletion, .addition,
        ])
    }

    /// A fragment with no `@@` — the hunk state cannot help, so the header
    /// patterns have to be precise enough on their own.
    func testAFragmentWithoutAHunkHeaderStillColoursItsChanges() {
        let lines = DiffParser.parse("----\n+++i;\n-- sql\n")
        // The whole array, not subscripts: a parser regression that returns
        // fewer lines should fail this test, not trap and abort the run.
        XCTAssertEqual(lines.map(\.kind), [.deletion, .addition, .deletion])
    }

    func testUnpairedDeletionRunIsLeftPlain() {
        // A deletion run with no additions following it (a pure removal) must
        // stay plain — there is nothing to pair with.
        let diff = """
@@ -1,3 +1,3 @@
 context line
-remove me
 more context
+added line
"""
        let lines = DiffParser.parse(diff)
        XCTAssertTrue(lines.allSatisfy { $0.emphasizedRanges.isEmpty },
                      "unpaired lines must not be emphasized")
    }
}
