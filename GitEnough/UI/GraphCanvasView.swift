import SwiftUI
import AppKit

/// Geometry constants for the history graph.
enum GraphMetrics {
    static let laneWidth: CGFloat = 16
    static let rowHeight: CGFloat = 27
    static let nodeRadius: CGFloat = 4.5
}

/// Draws the branch/merge graph: one SwiftUI Canvas sized to the whole history,
/// aligned row-for-row with the commit list next to it. Edges are drawn first
/// (verticals, then curves), nodes last so they sit on top.
struct GraphCanvasView: View {

    let layout: GraphLayout
    let commitCount: Int
    let headRow: Int?
    let selectedRow: Int?

    @Environment(\.colorScheme) private var colorScheme

    private var width: CGFloat {
        CGFloat(max(1, layout.columnCount)) * GraphMetrics.laneWidth
    }

    private var height: CGFloat {
        CGFloat(max(1, commitCount)) * GraphMetrics.rowHeight
    }

    var body: some View {
        Canvas { context, _ in
            if let selectedRow {
                let rect = CGRect(x: 0, y: CGFloat(selectedRow) * GraphMetrics.rowHeight,
                                  width: width, height: GraphMetrics.rowHeight)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.20)))
            }
            for segment in layout.segments {
                drawSegment(segment, in: &context)
            }
            for node in layout.nodes {
                drawNode(node, in: &context)
            }
        }
        .frame(width: width, height: height)
    }

    // MARK: - Colors

    private func laneColor(_ index: Int) -> Color {
        let hue = GraphPalette.hues[index % GraphPalette.hues.count]
        return Color(hue: hue, saturation: 0.62,
                     brightness: colorScheme == .dark ? 0.95 : 0.72)
    }

    // MARK: - Geometry

    private func x(_ column: Int) -> CGFloat {
        CGFloat(column) * GraphMetrics.laneWidth + GraphMetrics.laneWidth / 2
    }

    private func nodePoint(row: Int, column: Int) -> CGPoint {
        CGPoint(x: x(column), y: CGFloat(row) * GraphMetrics.rowHeight + GraphMetrics.rowHeight / 2)
    }

    // MARK: - Segments

    private func drawSegment(_ segment: GraphLayout.Segment,
                             in context: inout GraphicsContext) {
        let rowH = GraphMetrics.rowHeight
        var path = Path()
        switch segment.kind {
        case .vertical:
            path.move(to: CGPoint(x: x(segment.fromColumn), y: CGFloat(segment.fromRow) * rowH))
            path.addLine(to: CGPoint(x: x(segment.toColumn), y: CGFloat(segment.toRow) * rowH))
        case .branchOut:
            // From the merge node diagonally down into the newborn lane.
            let start = nodePoint(row: segment.fromRow, column: segment.fromColumn)
            let end = CGPoint(x: x(segment.toColumn), y: CGFloat(segment.toRow) * rowH)
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x, y: start.y + rowH * 0.55),
                          control2: CGPoint(x: end.x, y: end.y - rowH * 0.55))
        case .joinExisting:
            // A lane folding into a lane that passes through this row. When the
            // source lane comes from above (it wasn't a node), the curve starts
            // at the lane's top edge; otherwise at the node itself.
            let start: CGPoint
            if segment.fromRow == segment.toRow {
                start = nodePoint(row: segment.fromRow, column: segment.fromColumn)
            } else {
                start = CGPoint(x: x(segment.fromColumn), y: CGFloat(segment.fromRow) * rowH)
            }
            let end: CGPoint
            if segment.fromRow == segment.toRow, segment.fromColumn < segment.toColumn {
                // Node joining a lane to its right: meet it at the row's bottom edge.
                end = CGPoint(x: x(segment.toColumn), y: CGFloat(segment.toRow) * rowH + rowH)
            } else {
                // Lane folding into the row's node (from the right, same row).
                end = nodePoint(row: segment.toRow, column: segment.toColumn)
            }
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x, y: start.y + rowH * 0.55),
                          control2: CGPoint(x: end.x, y: end.y - rowH * 0.55))
        }
        context.stroke(path, with: .color(laneColor(segment.colorIndex)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    // MARK: - Nodes

    private func drawNode(_ node: GraphLayout.Node, in context: inout GraphicsContext) {
        let center = nodePoint(row: node.row, column: node.column)
        let radius = GraphMetrics.nodeRadius
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let color = laneColor(node.colorIndex)
        context.fill(Path(ellipseIn: rect), with: .color(color))
        // Thin halo so the dot reads against overlapping lines.
        context.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)),
                       with: .color(Color(nsColor: .textBackgroundColor).opacity(0.6)),
                       lineWidth: 1)
        // HEAD gets the IntelliJ-style double ring.
        if let headRow, node.row == headRow {
            let outer = rect.insetBy(dx: -3.5, dy: -3.5)
            context.stroke(Path(ellipseIn: outer), with: .color(color), lineWidth: 2)
        }
    }
}
