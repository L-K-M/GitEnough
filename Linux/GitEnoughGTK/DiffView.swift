import CGtk
import GitEnough

/// A unified diff, coloured per line.
///
/// A `GtkTextView` with three tags rather than one widget per line: a large diff
/// is thousands of lines, and a box full of labels would cost a widget each.
final class DiffView {

    let widget: UnsafeMutablePointer<GtkWidget>

    private let textView: UnsafeMutablePointer<GtkWidget>
    private let buffer: UnsafeMutablePointer<GtkTextBuffer>
    private let addedTag: UnsafeMutablePointer<GtkTextTag>
    private let removedTag: UnsafeMutablePointer<GtkTextTag>
    private let headerTag: UnsafeMutablePointer<GtkTextTag>

    init() {
        textView = require(gtk_text_view_new(), "text view")
        let view = cast(textView, to: GtkTextView.self)
        gtk_text_view_set_editable(view, 0)
        gtk_text_view_set_cursor_visible(view, 0)
        gtk_text_view_set_monospace(view, 1)
        gtk_text_view_set_wrap_mode(view, GTK_WRAP_NONE)
        gtk_text_view_set_left_margin(view, 8)
        gtk_text_view_set_top_margin(view, 8)

        buffer = require(gtk_text_view_get_buffer(view), "text buffer")
        let tags = require(gtk_text_buffer_get_tag_table(buffer), "tag table")

        func tag(_ name: String, foreground: String) -> UnsafeMutablePointer<GtkTextTag> {
            let tag = require(gtk_text_tag_new(name), "text tag")
            Properties.set(tag, "foreground", foreground)
            gtk_text_tag_table_add(tags, tag)
            return tag
        }
        // Colours rather than style classes: GTK has no stock "this line was
        // added" class, and a diff has to read the same on every theme.
        addedTag = tag("added", foreground: "#2e7d32")
        removedTag = tag("removed", foreground: "#c62828")
        headerTag = tag("header", foreground: "#6a6a6a")

        widget = UI.scroller(textView, horizontal: GTK_POLICY_AUTOMATIC)
    }

    /// Replaces the shown diff. An empty string clears the view.
    func show(_ diff: String) {
        gtk_text_buffer_set_text(buffer, diff, -1)
        guard !diff.isEmpty else { return }

        for (index, line) in diff.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            guard let tag = tag(for: line) else { continue }
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_iter_at_line(buffer, &start, Int32(index))
            gtk_text_buffer_get_iter_at_line(buffer, &end, Int32(index))
            gtk_text_iter_forward_to_line_end(&end)
            gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
        }
    }

    /// `+++`/`---` are file headers, not content — they must not read as one
    /// enormous added and removed line.
    private func tag(for line: Substring) -> UnsafeMutablePointer<GtkTextTag>? {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return headerTag }
        if line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return headerTag
        }
        if line.hasPrefix("+") { return addedTag }
        if line.hasPrefix("-") { return removedTag }
        return nil
    }
}
