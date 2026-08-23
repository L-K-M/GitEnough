import SwiftUI
import AppKit

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
    /// True for the last row: its tail spill is clipped exactly at the row's
    /// bottom edge (what the old single canvas did at its bottom), so the
    /// "history continues below" stub stops at the list end instead of
    /// painting into whatever sits below it.
    let clipsTail: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var laneWidth: CGFloat {
        GraphMetrics.laneWidth(for: layout.columnCount)
    }

    private var width: CGFloat {
        GraphMetrics.graphWidth(for: layout.columnCount)
    }

    var body: some View {
        if clipsTail {
            strip.clipped()
        } else {
            strip
        }
    }

    private var strip: some View {
        Canvas { context, _ in
            let drawing = layout.drawing(row: row, isHeadRow: isHeadRow)
            if isSelected {
                let rect = CGRect(x: 0, y: 0, width: drawing.width, height: drawing.height)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.20)))
            }
            for stroke in drawing.strokes {
                context.stroke(path(for: stroke.shape),
                               with: .color(laneColor(stroke.colorIndex)),
                               style: StrokeStyle(lineWidth: GraphRowDrawing.lineWidth,
                                                  lineCap: .round))
            }
            if let node = drawing.node {
                drawNode(node, in: &context)
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

    // MARK: - Shapes

    private func point(_ point: GraphRowDrawing.Point) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    private func path(for shape: GraphRowDrawing.Stroke.Shape) -> Path {
        var path = Path()
        switch shape {
        case .line(let from, let to):
            path.move(to: point(from))
            path.addLine(to: point(to))
        case .curve(let from, let to, let control1, let control2):
            path.move(to: point(from))
            path.addCurve(to: point(to),
                          control1: point(control1), control2: point(control2))
        }
        return path
    }

    // MARK: - Nodes

    private func drawNode(_ node: GraphRowDrawing.Node, in context: inout GraphicsContext) {
        let center = point(node.center)
        let rect = CGRect(x: center.x - node.radius, y: center.y - node.radius,
                          width: node.radius * 2, height: node.radius * 2)
        let color = laneColor(node.colorIndex)
        context.fill(Path(ellipseIn: rect), with: .color(color))
        // Thin halo so the dot reads against overlapping lines.
        context.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)),
                       with: .color(Color(nsColor: .textBackgroundColor).opacity(0.6)),
                       lineWidth: 1)
        if node.isHead {
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -3.5, dy: -3.5)),
                           with: .color(color), lineWidth: 2)
        }
    }
}
