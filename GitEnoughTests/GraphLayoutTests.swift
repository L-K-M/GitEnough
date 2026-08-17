import XCTest
@testable import GitEnough

/// Tests for the lane-assignment algorithm behind the history graph.
final class GraphLayoutTests: XCTestCase {

    /// Builds a commit with the given hash/parents (other fields irrelevant).
    private func commit(_ hash: String, parents: [String] = []) -> Commit {
        Commit(hash: hash, parents: parents, author: "Test", email: "t@example.com",
               date: nil, subject: hash, decorations: [])
    }

    private func hasSegment(_ layout: GraphLayout,
                            fromRow: Int, fromColumn: Int,
                            toRow: Int, toColumn: Int,
                            kind: GraphLayout.Segment.Kind) -> Bool {
        layout.segments.contains {
            $0.fromRow == fromRow && $0.fromColumn == fromColumn
                && $0.toRow == toRow && $0.toColumn == toColumn
                && $0.kind == kind
        }
    }

    // MARK: - Linear

    func testLinearHistoryStaysInOneLane() {
        let layout = GraphLayout.layout(commits: [
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a"),
        ])
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.nodes.map(\.column), [0, 0, 0])
        // Two vertical links; the root ends the lane (no segment past the last row).
        XCTAssertEqual(layout.segments.count, 2)
        XCTAssertTrue(hasSegment(layout, fromRow: 0, fromColumn: 0, toRow: 1, toColumn: 0, kind: .vertical))
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 0, toRow: 2, toColumn: 0, kind: .vertical))
    }

    func testEmptyHistory() {
        let layout = GraphLayout.layout(commits: [])
        XCTAssertEqual(layout.columnCount, 0)
        XCTAssertTrue(layout.nodes.isEmpty)
        XCTAssertTrue(layout.segments.isEmpty)
    }

    // MARK: - Branch + merge (diamond)

    ///   M (parents c1, c2)
    ///   c1 (parent c0)
    ///   c2 (parent c0)
    ///   c0
    func testMergeDiamond() {
        let layout = GraphLayout.layout(commits: [
            commit("M", parents: ["c1", "c2"]),
            commit("c1", parents: ["c0"]),
            commit("c2", parents: ["c0"]),
            commit("c0"),
        ])
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.nodes.map(\.column), [0, 0, 1, 0])

        // The merge fans a new lane out for c2…
        XCTAssertTrue(hasSegment(layout, fromRow: 0, fromColumn: 0, toRow: 1, toColumn: 1, kind: .branchOut))
        // …the first parent continues straight down lane 0…
        XCTAssertTrue(hasSegment(layout, fromRow: 0, fromColumn: 0, toRow: 1, toColumn: 0, kind: .vertical))
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 0, toRow: 2, toColumn: 0, kind: .vertical))
        // …the side lane passes through row 1…
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 1, toRow: 2, toColumn: 1, kind: .vertical))
        // …and folds back into lane 0 at c2's row.
        XCTAssertTrue(hasSegment(layout, fromRow: 2, fromColumn: 1, toRow: 2, toColumn: 0, kind: .joinExisting))
        XCTAssertTrue(hasSegment(layout, fromRow: 2, fromColumn: 0, toRow: 3, toColumn: 0, kind: .vertical))
        XCTAssertEqual(layout.segments.count, 6)
    }

    // MARK: - Octopus merge

    func testOctopusMergeFansOutOneLanePerParent() {
        let layout = GraphLayout.layout(commits: [
            commit("O", parents: ["p1", "p2", "p3"]),
            commit("p1"),
            commit("p2"),
            commit("p3"),
        ])
        XCTAssertEqual(layout.columnCount, 3)
        XCTAssertEqual(layout.nodes.map(\.column), [0, 0, 1, 2])
        XCTAssertTrue(hasSegment(layout, fromRow: 0, fromColumn: 0, toRow: 1, toColumn: 1, kind: .branchOut))
        XCTAssertTrue(hasSegment(layout, fromRow: 0, fromColumn: 0, toRow: 1, toColumn: 2, kind: .branchOut))
        // Each side lane lives until its own tip's row.
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 1, toRow: 2, toColumn: 1, kind: .vertical))
        XCTAssertTrue(hasSegment(layout, fromRow: 2, fromColumn: 2, toRow: 3, toColumn: 2, kind: .vertical))
    }

    // MARK: - Converging branches

    /// Two tips whose parent is the same commit: the second tip folds into the
    /// first tip's lane instead of opening a duplicate lane.
    func testTwoTipsSharingAParentConvergeIntoOneLane() {
        let layout = GraphLayout.layout(commits: [
            commit("A", parents: ["C"]),
            commit("B", parents: ["C"]),
            commit("C"),
        ])
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.nodes.map(\.column), [0, 1, 0])
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 1, toRow: 1, toColumn: 0, kind: .joinExisting))
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 0, toRow: 2, toColumn: 0, kind: .vertical))
    }

    // MARK: - Lane reuse

    /// Two disconnected roots: the second reuses the freed lane 0 instead of
    /// growing the graph wider.
    func testDisconnectedRootsReuseFreedLanes() {
        let layout = GraphLayout.layout(commits: [
            commit("X"),
            commit("Y"),
        ])
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.nodes.map(\.column), [0, 0])
        XCTAssertTrue(layout.segments.isEmpty)
    }

    /// A long side branch gets its lane recycled by the next branch once it ends.
    func testLanesAreReusedAfterTheyEnd() {
        // M1 (parents a, b), a (parent r), b (parent r), M2 (parent r), r
        let layout = GraphLayout.layout(commits: [
            commit("M1", parents: ["a", "b"]),
            commit("a", parents: ["r"]),
            commit("b", parents: ["r"]),
            commit("M2", parents: ["r"]),
            commit("r"),
        ])
        // b folds into lane 0 at row 2, freeing lane 1; M2 reuses lane 1 rather
        // than widening the graph, then itself folds into lane 0 (which expects r).
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.nodes.map(\.column), [0, 0, 1, 1, 0])
        XCTAssertTrue(hasSegment(layout, fromRow: 2, fromColumn: 1, toRow: 2, toColumn: 0, kind: .joinExisting))
        XCTAssertTrue(hasSegment(layout, fromRow: 3, fromColumn: 1, toRow: 3, toColumn: 0, kind: .joinExisting))
    }

    // MARK: - Colors

    func testLaneColorsAreStableAlongALaneAndDistinctAcrossLanes() {
        let layout = GraphLayout.layout(commits: [
            commit("M", parents: ["c1", "c2"]),
            commit("c1", parents: ["c0"]),
            commit("c2", parents: ["c0"]),
            commit("c0"),
        ])
        let mainColor = layout.nodes[0].colorIndex
        let sideColor = layout.nodes[2].colorIndex
        XCTAssertNotEqual(mainColor, sideColor)
        XCTAssertEqual(layout.nodes[1].colorIndex, mainColor)
        XCTAssertEqual(layout.nodes[3].colorIndex, mainColor)
        // The branch-out segment takes the new lane's color.
        let branchOut = layout.segments.first { $0.kind == .branchOut }
        XCTAssertEqual(branchOut?.colorIndex, sideColor)
    }
}
