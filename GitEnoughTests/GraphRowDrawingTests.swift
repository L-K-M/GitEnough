import XCTest
@testable import GitEnough

/// The renderer-independent graph geometry both front ends paint from. SwiftUI's
/// Canvas and Cairo consume exactly these numbers, so a regression here shows up
/// identically on both platforms — which is the point of it living in the core.
final class GraphRowDrawingTests: XCTestCase {

    /// Two commits in one lane, then a branch: enough to produce a vertical, a
    /// branch-out curve and nodes on distinct rows.
    private func commit(_ hash: String, parents: [String] = []) -> Commit {
        Commit(hash: hash, parents: parents, author: "A", email: "a@example.com",
               date: nil, subject: hash, decorations: [])
    }

    private var linear: GraphLayout {
        GraphLayout.layout(commits: [commit("c2", parents: ["c1"]),
                                     commit("c1", parents: ["c0"]),
                                     commit("c0")])
    }

    // MARK: - Geometry

    func testNodeSitsOnItsLaneCentreAndItsRowCentre() throws {
        let node = try XCTUnwrap(linear.drawing(row: 0, isHeadRow: false).node)
        // Single lane: centred at half a lane width, half a row down.
        XCTAssertEqual(node.center.x, Double(GraphMetrics.laneWidth) / 2)
        XCTAssertEqual(node.center.y, Double(GraphMetrics.rowHeight) / 2)
    }

    func testAVerticalSpansFromThisRowsCentreToTheNextRowsCentre() throws {
        let drawing = linear.drawing(row: 0, isHeadRow: false)
        let vertical = try XCTUnwrap(drawing.strokes.first)
        guard case .line(let from, let to) = vertical.shape else {
            return XCTFail("a lane continuing downward should be a straight line")
        }
        let rowHeight = Double(GraphMetrics.rowHeight)
        XCTAssertEqual(from.y, rowHeight / 2)
        // Half a row below the strip: the deliberate spill that tiles the next
        // strip seamlessly onto this one.
        XCTAssertEqual(to.y, rowHeight + rowHeight / 2)
        XCTAssertEqual(from.x, to.x, "a vertical must not drift sideways")
    }

    func testDrawingSizeMatchesTheGraphColumn() {
        let drawing = linear.drawing(row: 0, isHeadRow: false)
        XCTAssertEqual(drawing.width, Double(GraphMetrics.graphWidth(for: linear.columnCount)))
        XCTAssertEqual(drawing.height, Double(GraphMetrics.rowHeight))
    }

    // MARK: - Paint order

    func testVerticalsArePaintedBeforeCurvesWithinEachHalf() {
        // A join curve has to land *on* the lane it merges into; painting the
        // lane afterwards would overpaint the endpoint and sever the join. A
        // strip paints two groups — the half flowing in from the row above,
        // then its own — and each is ordered verticals-first, so a curve may be
        // followed by a vertical exactly once: at the boundary between them.
        let layout = GraphLayout.layout(commits: [
            commit("M", parents: ["a", "b"]),
            commit("a", parents: ["base"]),
            commit("b", parents: ["base"]),
            commit("base"),
        ])
        for row in 0..<4 {
            let isLine = layout.drawing(row: row, isHeadRow: false).strokes.map { stroke -> Bool in
                if case .line = stroke.shape { return true } else { return false }
            }
            let curveThenVertical = zip(isLine, isLine.dropFirst())
                .filter { !$0.0 && $0.1 }
                .count
            XCTAssertLessThanOrEqual(curveThenVertical, 1,
                                     "row \(row) reorders strokes within a half")
        }
    }

    /// The regression this guards: a strip used to draw only its own segments
    /// and let them spill below its frame, relying on the next strip tiling
    /// underneath. Put a host that clips to the frame between them — which is
    /// what both a SwiftUI row and a GTK widget do — and every lane loses its
    /// top half, turning continuous lines into dashes.
    func testALaneIsCoveredTopToBottomSoRowsNeedNoSpill() throws {
        let rowHeight = Double(GraphMetrics.rowHeight)
        // Row 1 of a linear history: a lane passes straight through it.
        let drawing = linear.drawing(row: 1, isHeadRow: false)

        func covers(_ y: Double) -> Bool {
            drawing.strokes.contains { stroke in
                guard case .line(let from, let to) = stroke.shape else { return false }
                return min(from.y, to.y) <= y && y <= max(from.y, to.y)
            }
        }
        XCTAssertTrue(covers(0.5), "nothing drawn at the row's top edge — the gap is back")
        XCTAssertTrue(covers(rowHeight / 2), "nothing drawn at the row's centre")
        XCTAssertTrue(covers(rowHeight - 0.5), "nothing drawn at the row's bottom edge")
    }

    func testTheFirstRowHasNothingFlowingIntoIt() {
        // Row 0 has no row above, so its strokes start at its own centre line
        // and no stub pokes above the topmost dot.
        let drawing = linear.drawing(row: 0, isHeadRow: false)
        for stroke in drawing.strokes {
            switch stroke.shape {
            case .line(let from, let to):
                XCTAssertGreaterThanOrEqual(min(from.y, to.y), Double(GraphMetrics.rowHeight) / 2)
            case .curve(let from, let to, _, _):
                XCTAssertGreaterThanOrEqual(min(from.y, to.y), Double(GraphMetrics.rowHeight) / 2)
            }
        }
    }

    // MARK: - Bounds

    func testRowsOutsideTheLayoutComeBackEmptyRatherThanTrapping() {
        // The list and the layout refresh independently, so a stale row index is
        // an ordinary transient.
        for row in [-1, 99] {
            let drawing = linear.drawing(row: row, isHeadRow: false)
            XCTAssertTrue(drawing.strokes.isEmpty)
            XCTAssertNil(drawing.node)
        }
    }

    func testHeadRowIsMarkedForTheDoubleRing() {
        XCTAssertEqual(linear.drawing(row: 0, isHeadRow: true).node?.isHead, true)
        XCTAssertEqual(linear.drawing(row: 0, isHeadRow: false).node?.isHead, false)
    }

    // MARK: - Palette

    func testLaneColorsConvertToRGBAndStayInRange() {
        for index in 0..<(GraphPalette.hues.count * 2) {
            for isDark in [true, false] {
                let (r, g, b) = GraphPalette.rgb(forColorIndex: index, isDark: isDark)
                for component in [r, g, b] {
                    XCTAssertTrue((0...1).contains(component),
                                  "component \(component) out of range at \(index)")
                }
            }
        }
    }

    func testDarkModeLanesAreBrighterThanLightModeLanes() {
        for index in 0..<GraphPalette.hues.count {
            let dark = GraphPalette.rgb(forColorIndex: index, isDark: true)
            let light = GraphPalette.rgb(forColorIndex: index, isDark: false)
            XCTAssertGreaterThan(max(dark.red, dark.green, dark.blue),
                                 max(light.red, light.green, light.blue))
        }
    }

    func testHSBConversionMatchesKnownColors() {
        func rgb(_ h: Double, _ s: Double, _ b: Double) -> [Double] {
            let c = GraphPalette.hsbToRGB(hue: h, saturation: s, brightness: b)
            return [c.red, c.green, c.blue].map { ($0 * 1000).rounded() / 1000 }
        }
        XCTAssertEqual(rgb(0, 1, 1), [1, 0, 0])          // red
        XCTAssertEqual(rgb(1.0 / 3, 1, 1), [0, 1, 0])    // green
        XCTAssertEqual(rgb(2.0 / 3, 1, 1), [0, 0, 1])    // blue
        XCTAssertEqual(rgb(0.5, 0, 0.4), [0.4, 0.4, 0.4]) // no saturation is grey
        XCTAssertEqual(rgb(1, 1, 1), [1, 0, 0], "hue wraps at 1")
    }
}

/// Lane placement across the graph's width. A crowded stretch must not set the
/// spacing for rows that only draw a lane or two — those are the rows people
/// read most, and they were being squeezed to match the busiest merge in the
/// history.
final class GraphLanePlacementTests: XCTestCase {

    func testGraphsWithinTheWidthBudgetAreEvenlySpaced() {
        // Nothing changes until lanes outgrow the column.
        for count in 1...GraphMetrics.maxUncompressedLanes {
            for column in 0..<count {
                XCTAssertEqual(GraphMetrics.laneCentre(column, columnCount: count),
                               (CGFloat(column) + 0.5) * GraphMetrics.laneWidth,
                               "column \(column) of \(count)")
            }
        }
    }

    func testTheFirstLanesKeepFullSpacingHoweverCrowdedTheGraphGets() {
        // The complaint this fixes: a 54-lane history drew its trunk-only rows
        // at 3.6pt. The low lanes now keep the same spacing they would have in
        // a quiet graph, no matter what the busiest row does.
        for count in [20, 54, 200] {
            let full = GraphMetrics.uncompressedLanes(for: count)
            XCTAssertGreaterThanOrEqual(full, 3, "\(count) lanes left almost nothing at full width")
            for column in 0..<full {
                XCTAssertEqual(GraphMetrics.laneCentre(column, columnCount: count),
                               (CGFloat(column) + 0.5) * GraphMetrics.laneWidth)
            }
        }
    }

    func testTheCrowdKeepsMostOfTheSpacingAnEvenSqueezeWouldGiveIt() {
        // Widening the front is paid for out of the back, so the back has a
        // floor — otherwise a busy graph would trade one unreadable region for
        // another.
        for count in [13, 20, 54, 200] {
            let even = GraphMetrics.laneWidth(for: count)
            XCTAssertGreaterThanOrEqual(GraphMetrics.crowdedSpacing(for: count), even * 0.6,
                                        "\(count) lanes squeezed the crowd too hard")
        }
    }

    func testLanesStayInsideTheColumnAndInOrder() {
        for count in [1, 3, 12, 13, 20, 54, 200] {
            var previous = -CGFloat.greatestFiniteMagnitude
            for column in 0..<count {
                let centre = GraphMetrics.laneCentre(column, columnCount: count)
                XCTAssertGreaterThan(centre, previous, "column \(column) of \(count) went backwards")
                XCTAssertLessThanOrEqual(centre, GraphMetrics.maxGraphWidth,
                                         "column \(column) of \(count) escaped the column")
                previous = centre
            }
        }
    }

    func testALanesPositionNeverDependsOnTheRow() {
        // The reason placement is a function of the column alone: anything
        // row-dependent slides a lane sideways in proportion to its column as
        // the graph's density changes around it.
        let layout = GraphLayout.layout(commits: (0..<40).map { index in
            Commit(hash: "c\(index)",
                   parents: index == 39 ? [] : ["c\(index + 1)"],
                   author: "A", email: "a@example.com", date: nil,
                   subject: "c\(index)", decorations: [])
        })
        let centres = (0..<layout.nodes.count).compactMap {
            layout.drawing(row: $0, isHeadRow: false).node?.center.x
        }
        XCTAssertEqual(Set(centres).count, 1, "the trunk drifted between rows")
    }
}
