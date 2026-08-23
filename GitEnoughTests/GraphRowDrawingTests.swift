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

    func testVerticalsArePaintedBeforeCurves() {
        // A join curve has to land *on* the lane it merges into; painting the
        // lane afterwards would overpaint the endpoint and sever the join.
        let layout = GraphLayout.layout(commits: [
            commit("M", parents: ["a", "b"]),
            commit("a", parents: ["base"]),
            commit("b", parents: ["base"]),
            commit("base"),
        ])
        for row in 0..<4 {
            let kinds = layout.drawing(row: row, isHeadRow: false).strokes.map { stroke -> Bool in
                if case .line = stroke.shape { return true } else { return false }
            }
            let lastLine = kinds.lastIndex(of: true) ?? -1
            let firstCurve = kinds.firstIndex(of: false) ?? kinds.count
            XCTAssertLessThan(lastLine, firstCurve,
                              "row \(row) paints a curve before a vertical")
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
