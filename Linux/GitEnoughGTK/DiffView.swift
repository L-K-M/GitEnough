import CGtk
import GitEnough

/// A unified diff, coloured per line.
///
/// A `GtkTextView` with one tag per line kind rather than one widget per line:
/// a large diff is thousands of lines, and a box full of labels would cost a
/// widget each.
///
/// Classification comes from `DiffParser` in the core — the same pass the macOS
/// pane renders — rather than from prefix tests here. Prefixes are ambiguous out
/// of context: inside a hunk the first column belongs to the diff, not to the
/// content, so a deleted `--- ` (every YAML document separator, every SQL or
/// Lua comment) arrives as `----` and reads as a file header, and an added
/// `++i;` arrives as `+++i;`. The parser is a hunk state machine for exactly
/// that reason, it understands the combined diffs `git diff` emits for a
/// conflicted path, and it caps very long diffs — none of which a second
/// classifier in a front end would inherit.
final class DiffView {

    let widget: UnsafeMutablePointer<GtkWidget>

    private let textView: UnsafeMutablePointer<GtkWidget>
    private let buffer: UnsafeMutablePointer<GtkTextBuffer>
    private let tags: [DiffLine.Kind: UnsafeMutablePointer<GtkTextTag>]
    /// The theme the tag colours were last resolved for, so a desktop switching
    /// between light and dark repaints instead of keeping yesterday's contrast.
    private var colouredForDark: Bool

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
        let table = require(gtk_text_buffer_get_tag_table(buffer), "tag table")

        var tags: [DiffLine.Kind: UnsafeMutablePointer<GtkTextTag>] = [:]
        for kind in Self.tagged {
            let tag = require(gtk_text_tag_new(Self.tagName(for: kind)), "text tag")
            gtk_text_tag_table_add(table, tag)
            tags[kind] = tag
        }
        self.tags = tags
        colouredForDark = Theme.isDark
        Self.applyColours(tags, isDark: colouredForDark)

        widget = UI.scroller(textView, horizontal: GTK_POLICY_AUTOMATIC)
    }

    /// Replaces the shown diff. An empty string clears the view.
    func show(_ diff: String) {
        let lines = DiffParser.parse(diff)
        // Trailing carriage returns are stripped. A `GtkTextBuffer` counts a
        // bare `\r` as a line separator of its own, so a CRLF file's last diff
        // line — the one `\r` this join does not follow with a `\n` — adds a
        // phantom empty line at the end of the pane. Measured against gtk 4.14:
        // "@@…\r\n-old\r\n+new\r" is 4 buffer lines, the same text without the
        // CRs is 3. Stripping them also makes the indices below agree with the
        // parser's by construction rather than because `\r\n` happens to count
        // as a single separator.
        let text = lines.map { stripTrailingCR($0.text) }.joined(separator: "\n")
        gtk_text_buffer_set_text(buffer, text, -1)
        guard !lines.isEmpty else { return }

        for (index, line) in lines.enumerated() {
            guard let tag = tags[line.kind] else { continue }
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_iter_at_line(buffer, &start, Int32(index))
            gtk_text_buffer_get_iter_at_line(buffer, &end, Int32(index))
            gtk_text_iter_forward_to_line_end(&end)
            gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
        }
        refreshColoursIfThemeChanged()
    }

    private func stripTrailingCR(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    /// Re-resolved on each diff rather than from a `GtkSettings` handler: this
    /// pane is rebuilt on every model publish anyway, and a per-instance global
    /// settings handler is one more thing nothing ever disconnects.
    private func refreshColoursIfThemeChanged() {
        let isDark = Theme.isDark
        guard isDark != colouredForDark else { return }
        colouredForDark = isDark
        Self.applyColours(tags, isDark: isDark)
    }

    // MARK: - Palette

    /// Context lines carry no tag: they are the diff's baseline and should be
    /// whatever the theme's text colour is.
    private static let tagged: [DiffLine.Kind] = [
        .addition, .deletion, .hunk, .fileHeader, .meta,
    ]

    private static func tagName(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: return "addition"
        case .deletion: return "deletion"
        case .hunk: return "hunk"
        case .fileHeader: return "fileHeader"
        case .meta: return "meta"
        case .context: return "context"
        }
    }

    /// The same semantic set the macOS pane uses (`DiffView.swift`), with a
    /// second row for dark desktops. The light values are tuned for a white
    /// background and sit near 2:1 contrast on a dark one, which is why there
    /// are two.
    private static func colour(for kind: DiffLine.Kind, isDark: Bool) -> String? {
        switch kind {
        case .addition: return isDark ? "#81c995" : "#2e7d32"
        case .deletion: return isDark ? "#f28b82" : "#c62828"
        case .hunk: return isDark ? "#8ab4f8" : "#3949ab"
        case .fileHeader: return isDark ? "#e0e0e0" : "#2b2b2b"
        case .meta: return isDark ? "#9aa0a6" : "#6a6a6a"
        case .context: return nil
        }
    }

    private static func applyColours(
        _ tags: [DiffLine.Kind: UnsafeMutablePointer<GtkTextTag>], isDark: Bool
    ) {
        for (kind, tag) in tags {
            guard let colour = colour(for: kind, isDark: isDark) else { continue }
            Properties.set(tag, "foreground", colour)
        }
    }
}
