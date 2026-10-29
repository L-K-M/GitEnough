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
        // …and folds back into lane 0, reaching it one row below c2's row.
        XCTAssertTrue(hasSegment(layout, fromRow: 2, fromColumn: 1, toRow: 3, toColumn: 0, kind: .joinExisting))
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
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 1, toRow: 2, toColumn: 0, kind: .joinExisting))
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 0, toRow: 2, toColumn: 0, kind: .vertical))
    }

    // MARK: - Lane reuse

    /// A merge whose first parent is already expected elsewhere folds its lane
    /// away — the second parent must then fan out to a FRESH lane to the right,
    /// never back into the node's own just-freed column (which would draw a
    /// curve into itself).
    func testSecondParentNeverGetsTheNodesOwnColumn() {
        // T → p; M merges p and q (p already expected by T's lane when M is seen).
        let layout = GraphLayout.layout(commits: [
            commit("T", parents: ["p"]),
            commit("M", parents: ["p", "q"]),
            commit("p", parents: ["r"]),
            commit("q", parents: ["r"]),
            commit("r"),
        ])
        // M claims lane 1, folds into lane 0 (first parent p); q opens lane 2.
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 1, toRow: 2, toColumn: 0, kind: .joinExisting))
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 1, toRow: 2, toColumn: 2, kind: .branchOut))
        // No segment ever starts and ends in the same column as the merge node.
        XCTAssertFalse(layout.segments.contains {
            $0.kind == .branchOut && $0.fromColumn == $0.toColumn
        })
        XCTAssertEqual(layout.columnCount, 3)
    }

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
        XCTAssertTrue(hasSegment(layout, fromRow: 2, fromColumn: 1, toRow: 3, toColumn: 0, kind: .joinExisting))
        XCTAssertTrue(hasSegment(layout, fromRow: 3, fromColumn: 1, toRow: 4, toColumn: 0, kind: .joinExisting))
    }

    /// Truncated history: the last row folds into a lane whose parent lies
    /// below the loaded window, so the join must reach toRow == commitCount
    /// (clipped at the canvas bottom) instead of stopping short.
    func testLastRowFoldReachesCommitCount() {
        let layout = GraphLayout.layout(commits: [
            commit("a", parents: ["ghost"]),
            commit("b", parents: ["ghost"]),
        ])
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 1,
                                 toRow: 2, toColumn: 0, kind: .joinExisting))
    }

    // MARK: - Attachment invariant

    /// Deterministic RNG so a failing history reproduces from its seed.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func next(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    /// A random newest-first, topologically ordered history: every parent is
    /// drawn from the commits below it. Includes merges, octopus merges, and
    /// disconnected roots.
    private func randomHistory(count: Int, seed: Int) -> [Commit] {
        var rng = SplitMix64(state: UInt64(seed))
        var commits: [Commit] = []
        for i in 0..<count {
            var parents: [String] = []
            if i < count - 1 {
                let parentCount: Int
                switch rng.next(10) {
                case 0: parentCount = 0                    // occasional mid-history root
                case 1, 2: parentCount = 2 + rng.next(2)   // merge, sometimes octopus
                default: parentCount = 1
                }
                var chosen = Set<Int>()
                for _ in 0..<parentCount {
                    let j = i + 1 + rng.next(count - i - 1)
                    if chosen.insert(j).inserted {
                        parents.append("c\(j)")
                    }
                }
                if parents.isEmpty && parentCount > 0 {
                    parents.append("c\(i + 1)")
                }
            }
            commits.append(commit("c\(i)", parents: parents))
        }
        return commits
    }

    /// Every segment endpoint must visibly attach: land on a node, meet another
    /// segment's endpoint, or run off the bottom edge of a truncated history.
    /// Anything else draws a line that stops in mid-air — with row-edge (rather
    /// than center-line) endpoints this showed up as the first commit after a
    /// branch point floating half a row off its lane.
    func testEverySegmentEndpointAttaches() {
        for seed in 0..<60 {
            let commits = randomHistory(count: 30, seed: seed)
            let layout = GraphLayout.layout(commits: commits)

            let nodePoints = Set(layout.nodes.map { "\($0.row):\($0.column)" })
            var endpointRefs: [String: Int] = [:]
            for s in layout.segments {
                endpointRefs["\(s.fromRow):\(s.fromColumn)", default: 0] += 1
                endpointRefs["\(s.toRow):\(s.toColumn)", default: 0] += 1
            }
            for s in layout.segments {
                let start = "\(s.fromRow):\(s.fromColumn)"
                let end = "\(s.toRow):\(s.toColumn)"
                XCTAssertTrue(nodePoints.contains(start) || (endpointRefs[start] ?? 0) > 1,
                              "seed \(seed): \(s.kind) starts detached at \(start)")
                XCTAssertTrue(nodePoints.contains(end) || (endpointRefs[end] ?? 0) > 1
                              || s.toRow == commits.count,
                              "seed \(seed): \(s.kind) ends detached at \(end)")
            }
        }
    }

    // MARK: - Row bucketing (per-row strip rendering)

    /// The UI draws the graph as per-row strips: strip r renders
    /// `segmentsByRow[r]`. The buckets must partition the segment list exactly
    /// — every segment spans one row (toRow == fromRow + 1), so bucketing by
    /// start row loses nothing and duplicates nothing.
    func testSegmentsByRowPartitionsAllSegments() {
        let commits = randomHistory(count: 30, seed: 7)
        let layout = GraphLayout.layout(commits: commits)
        XCTAssertEqual(layout.segmentsByRow.count, commits.count)
        for (row, bucket) in layout.segmentsByRow.enumerated() {
            for segment in bucket {
                XCTAssertEqual(segment.fromRow, row)
                XCTAssertEqual(segment.toRow, row + 1)
            }
        }
        XCTAssertEqual(layout.segmentsByRow.flatMap { $0 }.count, layout.segments.count)
    }

    func testEmptyHistoryHasNoRowBuckets() {
        XCTAssertTrue(GraphLayout.layout(commits: []).segmentsByRow.isEmpty)
    }

    // MARK: - Lane compression

    func testLaneWidthSqueezesBeyondTheWidthBudget() {
        XCTAssertEqual(GraphMetrics.laneWidth(for: 1), GraphMetrics.laneWidth)
        XCTAssertEqual(GraphMetrics.laneWidth(for: GraphMetrics.maxUncompressedLanes),
                       GraphMetrics.laneWidth)
        // Twice the budgeted lanes → half the spacing…
        XCTAssertEqual(GraphMetrics.laneWidth(for: GraphMetrics.maxUncompressedLanes * 2),
                       GraphMetrics.laneWidth / 2, accuracy: 0.001)
        // …and the column width stays capped no matter how pathological the
        // lane count gets (no floor — the cap is the invariant).
        XCTAssertEqual(GraphMetrics.graphWidth(for: 500), GraphMetrics.maxGraphWidth,
                       accuracy: 0.001)
        XCTAssertEqual(GraphMetrics.graphWidth(for: 0), GraphMetrics.laneWidth)
    }

    // MARK: - Duplicate parents

    /// A commit that names the same parent twice must not strand a lane.
    ///
    /// `git commit-tree` refuses to write such an object — measured on 2.43,
    /// it prints "error: duplicate parent … ignored" and writes one parent —
    /// but `git fast-import` writes both without complaint, `git fsck` passes
    /// them, and `%P` prints the hash twice. Verified end to end: a
    /// `from X` / `merge X` import stream produces a commit whose
    /// `git log --format=%P` is the same hash repeated, which is exactly the
    /// array `GitParsers.parseLog` builds. So this is what an imported history
    /// from cvs2git, hg-fast-export or git-filter-repo can hand the graph.
    ///
    /// The stranded lane is permanent: no later commit can claim it, so it
    /// draws a vertical segment on every remaining row of the history.
    func testDuplicateFirstParentDoesNotStrandALane() {
        let layout = GraphLayout.layout(commits: [
            commit("M", parents: ["a", "a"]),
            commit("a", parents: ["b"]),
            commit("b"),
        ])

        XCTAssertEqual(layout.columnCount, 1, "two edges to one commit are one lane")
        XCTAssertEqual(layout.nodes.map(\.column), [0, 0, 0])
        XCTAssertEqual(layout.segments.count, 2, "one vertical per row, nothing extra")
        XCTAssertTrue(hasSegment(layout, fromRow: 0, fromColumn: 0,
                                 toRow: 1, toColumn: 0, kind: .vertical))
        XCTAssertTrue(hasSegment(layout, fromRow: 1, fromColumn: 0,
                                 toRow: 2, toColumn: 0, kind: .vertical))
    }

    /// The same defect inside an octopus, with a real second parent in
    /// between — so the fix is pinned against the narrower reading that only
    /// an adjacent repeat matters.
    ///
    /// What strands a lane is a repeat of the **first** parent, wherever it
    /// sits in the list. Measured against the unfixed algorithm, for a merge
    /// over parents `a`, `b` and root `r`:
    ///
    ///     [a, a]     repeat of first      → columnCount 3, 1 segment past the root
    ///     [a, b, a]  repeat of first      → columnCount 3, 1 segment past the root
    ///     [a, b, b]  repeat of non-first  → columnCount 2, 0 segments past the root
    ///
    /// The last row is the tell: a repeated non-first parent folds into the
    /// lane that already expects it and merely draws a duplicate edge over the
    /// branch-out, which is invisible. A repeated first parent cannot, because
    /// the lookup excludes the node's own column.
    func testDuplicateParentInOctopusDrawsOneEdge() {
        let layout = GraphLayout.layout(commits: [
            commit("M", parents: ["a", "b", "a"]),
            commit("a", parents: ["r"]),
            commit("b", parents: ["r"]),
            commit("r"),
        ])

        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.segments.filter { $0.kind == .branchOut }.count, 1)
        // The root consumes every lane, so nothing may start on the last row.
        // This is the assertion that catches an immortal lane rather than
        // merely a miscounted column.
        XCTAssertTrue(layout.segmentsByRow[3].isEmpty,
                      "no lane may outlive the commit that closes the history")
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
