import SwiftUI
import AppKit

/// Geometry constants for the history graph.
enum GraphMetrics {
    /// Lane spacing while the lane count fits the column's width budget.
    static let laneWidth: CGFloat = 16
    /// How many lanes fit at full width; beyond this, lanes squeeze.
    static let maxUncompressedLanes = 12
    /// Hard cap on the graph column's width (maxUncompressedLanes × laneWidth).
    static let maxGraphWidth: CGFloat = 192
    static let rowHeight: CGFloat = 27
    static let nodeRadius: CGFloat = 4.5

    /// Lane spacing for a graph with `columnCount` lanes. Lanes squeeze once
    /// more are active than the width budget allows — otherwise a busy repo's
    /// historical lane high-water mark (30+ over a long history) makes the
    /// graph column hog the pane and pushes the commit text past the edge.
    /// No floor: the width cap is the invariant that keeps the layout sane —
    /// past a few dozen lanes the graph is a color smear no matter what, but
    /// a bounded one.
    static func laneWidth(for columnCount: Int) -> CGFloat {
        let count = max(1, columnCount)
        guard count > maxUncompressedLanes else { return laneWidth }
        return maxGraphWidth / CGFloat(count)
    }

    /// Width of the graph column for a graph with `columnCount` lanes — never
    /// exceeds `maxGraphWidth`.
    static func graphWidth(for columnCount: Int) -> CGFloat {
        CGFloat(max(1, columnCount)) * laneWidth(for: columnCount)
    }

    /// Node radius shrinks with squeezing lanes so dots don't bleed together.
    static func nodeRadius(forLaneWidth laneWidth: CGFloat) -> CGFloat {
        min(nodeRadius, laneWidth * 0.36)
    }
}

/// One row of the branch/merge graph: a row-height canvas sitting inside the
/// commit row it belongs to, drawing the segments that start at that row.
///
/// This used to be a single Canvas sized to the whole history
/// (`commitCount × rowHeight` tall). That layer overflows Core Animation's size
/// limit on long histories and renders at wrong offsets (the "graph flows under
/// the sidebar" glitch), and every selection change re-rasterized the whole
/// thing. Per-row strips are realized lazily with the rows themselves, so only
/// visible slices of the graph ever exist as layers.
///
/// Segments run from a row's center line to the next row's center line, so a
/// strip's strokes spill half a row BELOW its frame — deliberately not clipped:
/// the next row's strip picks up exactly where the spill ends, which tiles
/// seamlessly, and later rows paint later, so nodes always sit on top of the
/// tails flowing into them. One deliberate consequence of per-row painting: a
/// passing lane's vertical now paints over the spilled tail of an unrelated
/// curve from the row above (the old single canvas painted all curves over all
/// verticals globally) — a sub-pixel crossing difference, and lanes read as
/// continuous "in front" of joins passing under them.
struct GraphStripView: View {

    let layout: GraphLayout
    /// The commit row this strip renders (index into `layout.segmentsByRow`).
    let row: Int
    let isHeadRow: Bool
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var laneWidth: CGFloat {
        GraphMetrics.laneWidth(for: layout.columnCount)
    }

    private var width: CGFloat {
        GraphMetrics.graphWidth(for: layout.columnCount)
    }

    var body: some View {
        Canvas { context, _ in
            if isSelected {
                let rect = CGRect(x: 0, y: 0, width: width, height: GraphMetrics.rowHeight)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.20)))
            }
            // Vertical lane segments first: join curves must paint OVER the lane
            // they connect to — drawing a lane's vertical after the curve that
            // ends on it overpaints the curve's endpoint, which makes the
            // connection look severed.
            if row < layout.segmentsByRow.count {
                let segments = layout.segmentsByRow[row]
                for segment in segments where segment.kind == .vertical {
                    drawSegment(segment, in: &context)
                }
                for segment in segments where segment.kind != .vertical {
                    drawSegment(segment, in: &context)
                }
            }
            if row < layout.nodes.count {
                drawNode(layout.nodes[row], in: &context)
            }
        }
        .frame(width: width, height: GraphMetrics.rowHeight)
    }

    // MARK: - Colors

    private func laneColor(_ index: Int) -> Color {
        let hue = GraphPalette.hues[index % GraphPalette.hues.count]
        return Color(hue: hue, saturation: 0.62,
                     brightness: colorScheme == .dark ? 0.95 : 0.72)
    }

    // MARK: - Geometry

    private func x(_ column: Int) -> CGFloat {
        CGFloat(column) * laneWidth + laneWidth / 2
    }

    /// `absoluteRow` translated into this strip's local coordinates: the strip
    /// covers its own row, and endpoints on the next row's center line land
    /// half a row below the frame (the seamless-tiling spill, see the type doc).
    private func nodePoint(absoluteRow: Int, column: Int) -> CGPoint {
        CGPoint(x: x(column),
                y: CGFloat(absoluteRow - row) * GraphMetrics.rowHeight + GraphMetrics.rowHeight / 2)
    }

    // MARK: - Segments

    /// All segment endpoints are node points (row center lines). Consecutive
    /// verticals tile seamlessly center-to-center, a lane terminating at a node
    /// is drawn all the way INTO the dot (no half-row gap above the first commit
    /// after a branch point), and no stub pokes above the topmost row's node.
    private func drawSegment(_ segment: GraphLayout.Segment,
                             in context: inout GraphicsContext) {
        let rowH = GraphMetrics.rowHeight
        var path = Path()
        switch segment.kind {
        case .vertical:
            path.move(to: nodePoint(absoluteRow: segment.fromRow, column: segment.fromColumn))
            path.addLine(to: nodePoint(absoluteRow: segment.toRow, column: segment.toColumn))
        case .branchOut:
            // From the merge node diagonally down into the newborn lane, ending
            // on the next row's center line — exactly where the lane's vertical
            // (or the branch tip's dot) picks it up.
            let start = nodePoint(absoluteRow: segment.fromRow, column: segment.fromColumn)
            let end = nodePoint(absoluteRow: segment.toRow, column: segment.toColumn)
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x, y: start.y + rowH * 0.55),
                          control2: CGPoint(x: end.x, y: end.y - rowH * 0.55))
        case .joinExisting:
            // A node/lane merging into a lane that passes through this row. The
            // curve lands on the target lane at the next row's center line — a
            // point the lane's vertical always passes through (and the merging
            // parent's dot itself when it sits directly below).
            let start = nodePoint(absoluteRow: segment.fromRow, column: segment.fromColumn)
            let end = nodePoint(absoluteRow: segment.toRow, column: segment.toColumn)
            path.move(to: start)
            if segment.fromColumn < segment.toColumn {
                // Merge node joining a lane to its right: smooth S, continuing
                // the downward flow.
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x, y: start.y + rowH * 0.55),
                              control2: CGPoint(x: end.x, y: end.y - rowH * 0.55))
            } else {
                // Lane folding into a lane to its left: sweep down, then hook
                // into the lane — a clear, perpendicular connection instead of
                // a tangential graze.
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x, y: end.y),
                              control2: CGPoint(x: start.x + (end.x - start.x) * 0.55, y: end.y))
            }
        }
        context.stroke(path, with: .color(laneColor(segment.colorIndex)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    // MARK: - Nodes

    private func drawNode(_ node: GraphLayout.Node, in context: inout GraphicsContext) {
        let center = nodePoint(absoluteRow: node.row, column: node.column)
        let radius = GraphMetrics.nodeRadius(forLaneWidth: laneWidth)
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let color = laneColor(node.colorIndex)
        context.fill(Path(ellipseIn: rect), with: .color(color))
        // Thin halo so the dot reads against overlapping lines.
        context.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)),
                       with: .color(Color(nsColor: .textBackgroundColor).opacity(0.6)),
                       lineWidth: 1)
        // HEAD gets the IntelliJ-style double ring.
        if isHeadRow {
            let outer = rect.insetBy(dx: -3.5, dy: -3.5)
            context.stroke(Path(ellipseIn: outer), with: .color(color), lineWidth: 2)
        }
    }
}
