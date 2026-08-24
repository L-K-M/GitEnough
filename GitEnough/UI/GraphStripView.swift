import SwiftUI
import AppKit

struct GraphStripView: View {

    let layout: GraphLayout
    /// The commit row this strip renders (index into `layout.segmentsByRow`).
    let row: Int
    let isHeadRow: Bool
    let isSelected: Bool
    /// True when this row's commit hasn't reached the upstream yet (what
    /// `git push` would send) — its dot renders hollow instead of filled.
    let isUnpushedRow: Bool
    /// True for the last row: its tail spill is clipped exactly at the row's
    /// bottom edge (what the old single canvas did at its bottom), so the
    /// "history continues below" stub stops at the list end instead of
    /// painting into whatever sits below it.
    let clipsTail: Bool

    @Environment(\.colorScheme) private var colorScheme

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
            let drawing = layout.drawing(row: row, isHeadRow: isHeadRow,
                                         isUnpushed: isUnpushedRow)
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
        if node.isUnpushed {
            // Unpushed commits render hollow — "not on the remote yet" at a
            // glance. The interior is filled with the list background so lane
            // lines passing into the dot don't show through the ring.
            context.fill(Path(ellipseIn: rect),
                         with: .color(Color(nsColor: .textBackgroundColor)))
            context.stroke(Path(ellipseIn: rect.insetBy(dx: 0.75, dy: 0.75)),
                           with: .color(color), lineWidth: 1.5)
        } else {
            context.fill(Path(ellipseIn: rect), with: .color(color))
            // Thin halo so the dot reads against overlapping lines.
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)),
                           with: .color(Color(nsColor: .textBackgroundColor).opacity(0.6)),
                           lineWidth: 1)
        }
        if node.isHead {
            // HEAD gets the IntelliJ-style double ring.
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -3.5, dy: -3.5)),
                           with: .color(color), lineWidth: 2)
        }
    }
}
