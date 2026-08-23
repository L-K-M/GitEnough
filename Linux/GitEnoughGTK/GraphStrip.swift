import CGtk
import GitEnough

/// One row of the branch/merge graph, drawn with Cairo.
///
/// The geometry comes from `GraphLayout.drawing(row:isHeadRow:)` in the core —
/// the same description SwiftUI's Canvas paints on macOS — so this file is only
/// the translation into Cairo calls. Nothing about lane positions or curve
/// shapes is decided here.
///
/// Segments run from one row's centre line to the next one's, so half of every
/// segment belongs to the row below the one that owns it. macOS lets that half
/// spill out of the strip's frame and tiles the strips; GTK clips a widget to
/// its allocation, which would leave the top half of every row blank and the
/// lanes visibly broken above each dot.
///
/// So each strip paints two rows' worth of geometry: the previous row's
/// segments shifted up by one row height (the incoming half), then its own.
/// The result is identical to what macOS draws — the seam just moves from
/// between the widgets to inside them.
/// What one strip needs at paint time, boxed for the C draw callback. At file
/// scope because a C function pointer can't be formed from a closure that
/// carries enclosing type context.
private final class GraphStripContext {
    let drawing: GraphRowDrawing
    /// The row above, painted shifted up by one row height so its lower half
    /// lands in this row.
    let incoming: GraphRowDrawing
    let isDark: Bool
    init(drawing: GraphRowDrawing, incoming: GraphRowDrawing, isDark: Bool) {
        self.drawing = drawing
        self.incoming = incoming
        self.isDark = isDark
    }
}

enum GraphStrip {

    /// A drawing area sized to the graph column, painting `row` of `layout`.
    static func make(layout: GraphLayout,
                     row: Int,
                     isHeadRow: Bool,
                     isUnpushed: Bool,
                     isDark: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let drawing = layout.drawing(row: row, isHeadRow: isHeadRow,
                                     isUnpushed: isUnpushed)
        // Row -1 comes back empty, which is exactly right for the first row:
        // nothing flows into it from above.
        let incoming = layout.drawing(row: row - 1, isHeadRow: false)
        let area = require(gtk_drawing_area_new(), "drawing area")
        gtk_drawing_area_set_content_width(cast(area, to: GtkDrawingArea.self),
                                           Int32(drawing.width.rounded()))
        gtk_drawing_area_set_content_height(cast(area, to: GtkDrawingArea.self),
                                            Int32(drawing.height.rounded()))
        // Must not stretch: the row height is shared with the text beside it
        // through GraphMetrics.
        gtk_widget_set_valign(area, GTK_ALIGN_START)

        let context = GraphStripContext(drawing: drawing, incoming: incoming, isDark: isDark)
        gtk_drawing_area_set_draw_func(cast(area, to: GtkDrawingArea.self), { _, cairo, _, _, data in
            guard let cairo, let data else { return }
            paintGraphStrip(Unmanaged<GraphStripContext>.fromOpaque(data).takeUnretainedValue(), into: cairo)
        }, Unmanaged.passRetained(context).toOpaque(), { data in
            guard let data else { return }
            Unmanaged<GraphStripContext>.fromOpaque(data).release()
        })
        return area
    }

}

private func paintGraphStrip(_ context: GraphStripContext, into cairo: OpaquePointer) {
    cairo_set_line_width(cairo, GraphRowDrawing.lineWidth)
    cairo_set_line_cap(cairo, CAIRO_LINE_CAP_ROUND)

    // The half that flows in from the row above, then this row's own — same
    // order macOS paints them in, so a join curve still lands on top of the
    // lane it merges into rather than under it.
    paintStrokes(context.incoming.strokes, offsetY: -context.drawing.height,
                 isDark: context.isDark, into: cairo)
    paintStrokes(context.drawing.strokes, offsetY: 0,
                 isDark: context.isDark, into: cairo)

    guard let node = context.drawing.node else { return }
    let background: (r: Double, g: Double, b: Double) =
        context.isDark ? (0.12, 0.12, 0.12) : (1, 1, 1)
    if node.isUnpushed {
        // Hollow: the commit hasn't reached the upstream yet. The interior is
        // the list background so lane lines passing behind don't show through.
        cairo_set_source_rgb(cairo, background.r, background.g, background.b)
        circle(cairo, node.center, node.radius)
        cairo_fill(cairo)
        setColor(cairo, node.colorIndex, isDark: context.isDark)
        cairo_set_line_width(cairo, 1.5)
        circle(cairo, node.center, node.radius - 0.75)
        cairo_stroke(cairo)
    } else {
        setColor(cairo, node.colorIndex, isDark: context.isDark)
        circle(cairo, node.center, node.radius)
        cairo_fill(cairo)
        // A thin halo in the row's own background colour, so the dot reads
        // against any line passing behind it.
        cairo_set_line_width(cairo, 1)
        cairo_set_source_rgba(cairo, background.r, background.g, background.b, 0.6)
        circle(cairo, node.center, node.radius + 1)
        cairo_stroke(cairo)
    }
    if node.isHead {
        // HEAD gets the IntelliJ-style double ring.
        setColor(cairo, node.colorIndex, isDark: context.isDark)
        cairo_set_line_width(cairo, GraphRowDrawing.lineWidth)
        circle(cairo, node.center, node.radius + 3.5)
        cairo_stroke(cairo)
    }
}

private func paintStrokes(_ strokes: [GraphRowDrawing.Stroke],
                          offsetY: Double, isDark: Bool, into cairo: OpaquePointer) {
    for stroke in strokes {
        setColor(cairo, stroke.colorIndex, isDark: isDark)
        switch stroke.shape {
        case .line(let from, let to):
            cairo_move_to(cairo, from.x, from.y + offsetY)
            cairo_line_to(cairo, to.x, to.y + offsetY)
        case .curve(let from, let to, let control1, let control2):
            cairo_move_to(cairo, from.x, from.y + offsetY)
            cairo_curve_to(cairo, control1.x, control1.y + offsetY,
                           control2.x, control2.y + offsetY, to.x, to.y + offsetY)
        }
        cairo_stroke(cairo)
    }
}

private func circle(_ cairo: OpaquePointer,
                _ center: GraphRowDrawing.Point, _ radius: Double) {
    cairo_new_sub_path(cairo)
    cairo_arc(cairo, center.x, center.y, radius, 0, 2 * Double.pi)
}

private func setColor(_ cairo: OpaquePointer, _ index: Int, isDark: Bool) {
    let color = GraphPalette.rgb(forColorIndex: index, isDark: isDark)
    cairo_set_source_rgb(cairo, color.red, color.green, color.blue)
}
