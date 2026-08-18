import XCTest
@testable import GitEnough

/// Tests for unified-diff classification and intraline (word-level) emphasis.
final class DiffParserTests: XCTestCase {

    private func emphasizedText(of line: DiffLine) -> [String] {
        line.emphasizedRanges.sorted { $0.lowerBound < $1.lowerBound }
            .map { String(line.text[$0]) }
    }

    private func first(_ lines: [DiffLine], kind: DiffLine.Kind) -> DiffLine? {
        lines.first { $0.kind == kind }
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

    func testUnpairedDeletionRunIsLeftPlain() {
        // A deletion run with no additions following it (a pure removal) must
        // stay plain — there is nothing to pair with.
        let diff = """
@@ -1,3 +1,2 @@
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
