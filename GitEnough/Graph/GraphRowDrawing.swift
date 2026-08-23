import Foundation

/// One graph row resolved into shapes and colors, with no drawing API in sight.
///
/// The lane geometry — where a node sits, how far a merge curve reaches, which
/// hue a lane gets — is the same whether SwiftUI's `Canvas` or Cairo does the
/// painting. Keeping it here means the macOS and Linux front ends can't drift
/// apart in the one place where a difference would be obvious and hard to
/// diagnose, and it makes the curve math unit-testable without a renderer.
///
/// Coordinates are local to the row's strip: x from the left edge of the graph
/// column, y from the top of the row. Endpoints on the *next* row's center line
/// land half a row below the strip — deliberately, so consecutive strips tile
/// seamlessly (see `GraphStripView`).
public struct GraphRowDrawing: Equatable {

    public struct Point: Equatable {
        public let x: Double
        public let y: Double
    }

    /// A colored line piece. Curves are cubic beziers; lines are straight.
    public struct Stroke: Equatable {
        public enum Shape: Equatable {
            case line(from: Point, to: Point)
            case curve(from: Point, to: Point, control1: Point, control2: Point)
        }

        public let shape: Shape
        public let colorIndex: Int
    }

    public struct Node: Equatable {
        public let center: Point
        public let radius: Double
        public let colorIndex: Int
        /// HEAD gets the IntelliJ-style double ring.
        public let isHead: Bool
        /// The commit hasn't reached the upstream yet (what `git push` would
        /// send). Renders hollow — "not on the remote" at a glance — with the
        /// interior filled in the list's own background so lane lines passing
        /// behind it don't show through the ring.
        public let isUnpushed: Bool
    }

    public let width: Double
    public let height: Double
    /// Paint in order. Verticals come first: a join curve must paint *over* the
    /// lane it lands on, or the connection looks severed.
    public let strokes: [Stroke]
    public let node: Node?

    public static let lineWidth: Double = 2
}

extension GraphLayout {

    /// The drawing for one row. Out-of-range rows come back empty rather than
    /// trapping — the list and the layout are refreshed independently, so a
    /// stale row index is a normal transient, not a bug.
    public func drawing(row: Int, isHeadRow: Bool,
                        isUnpushed: Bool = false) -> GraphRowDrawing {
        let laneWidth = GraphMetrics.laneWidth(for: columnCount)
        let width = GraphMetrics.graphWidth(for: columnCount)
        let rowHeight = Double(GraphMetrics.rowHeight)

        func point(absoluteRow: Int, column: Int) -> GraphRowDrawing.Point {
            GraphRowDrawing.Point(
                x: Double(column) * Double(laneWidth) + Double(laneWidth) / 2,
                y: Double(absoluteRow - row) * rowHeight + rowHeight / 2)
        }

        var strokes: [GraphRowDrawing.Stroke] = []
        if row >= 0, row < segmentsByRow.count {
            let segments = segmentsByRow[row]
            for segment in segments where segment.kind == .vertical {
                strokes.append(stroke(for: segment, rowHeight: rowHeight, point: point))
            }
            for segment in segments where segment.kind != .vertical {
                strokes.append(stroke(for: segment, rowHeight: rowHeight, point: point))
            }
        }

        var node: GraphRowDrawing.Node?
        if row >= 0, row < nodes.count {
            let layoutNode = nodes[row]
            node = GraphRowDrawing.Node(
                center: point(absoluteRow: layoutNode.row, column: layoutNode.column),
                radius: Double(GraphMetrics.nodeRadius(forLaneWidth: laneWidth)),
                colorIndex: layoutNode.colorIndex,
                isHead: isHeadRow,
                isUnpushed: isUnpushed)
        }

        return GraphRowDrawing(width: Double(width), height: rowHeight,
                               strokes: strokes, node: node)
    }

    /// All segment endpoints are node points (row center lines), so a lane
    /// terminating at a node is drawn all the way *into* the dot and no stub
    /// pokes above the topmost row.
    private func stroke(
        for segment: Segment,
        rowHeight: Double,
        point: (Int, Int) -> GraphRowDrawing.Point
    ) -> GraphRowDrawing.Stroke {
        let start = point(segment.fromRow, segment.fromColumn)
        let end = point(segment.toRow, segment.toColumn)
        let reach = rowHeight * 0.55

        let shape: GraphRowDrawing.Stroke.Shape
        switch segment.kind {
        case .vertical:
            shape = .line(from: start, to: end)
        case .branchOut:
            // From the merge node diagonally down into the newborn lane, ending
            // on the next row's center line — exactly where that lane's vertical
            // (or the branch tip's dot) picks it up.
            shape = .curve(from: start, to: end,
                           control1: GraphRowDrawing.Point(x: start.x, y: start.y + reach),
                           control2: GraphRowDrawing.Point(x: end.x, y: end.y - reach))
        case .joinExisting where segment.fromColumn < segment.toColumn:
            // Joining a lane to the right: a smooth S that continues the
            // downward flow.
            shape = .curve(from: start, to: end,
                           control1: GraphRowDrawing.Point(x: start.x, y: start.y + reach),
                           control2: GraphRowDrawing.Point(x: end.x, y: end.y - reach))
        case .joinExisting:
            // Folding into a lane to the left: sweep down, then hook in — a
            // clear perpendicular connection instead of a tangential graze.
            shape = .curve(from: start, to: end,
                           control1: GraphRowDrawing.Point(x: start.x, y: end.y),
                           control2: GraphRowDrawing.Point(
                               x: start.x + (end.x - start.x) * 0.55, y: end.y))
        }
        return GraphRowDrawing.Stroke(shape: shape, colorIndex: segment.colorIndex)
    }
}

extension GraphPalette {

    /// A lane's color as plain RGB components in 0...1, for renderers that have
    /// no HSB constructor of their own (Cairo). SwiftUI builds the same color
    /// straight from `hues`, so both front ends stay on one palette.
    public static func rgb(forColorIndex index: Int,
                    isDark: Bool) -> (red: Double, green: Double, blue: Double) {
        hsbToRGB(hue: hues[index % hues.count],
                 saturation: 0.62,
                 brightness: isDark ? 0.95 : 0.72)
    }

    /// Standard HSB → RGB. Hue wraps; saturation and brightness clamp.
    public static func hsbToRGB(hue: Double, saturation: Double,
                         brightness: Double) -> (red: Double, green: Double, blue: Double) {
        let saturation = min(max(saturation, 0), 1)
        let brightness = min(max(brightness, 0), 1)
        guard saturation > 0 else { return (brightness, brightness, brightness) }

        let hue = (hue.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        switch index {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
