import CGtk

/// Small constructors over GTK's C API. Not a widget framework — just the
/// handful of shapes GitEnough builds over and over, so the panes read as
/// layout rather than as pointer casts.
enum UI {

    // MARK: - Containers

    static func box(_ orientation: GtkOrientation,
                    spacing: Int32 = 0,
                    margin: Int32 = 0) -> UnsafeMutablePointer<GtkWidget> {
        let box = require(gtk_box_new(orientation, spacing), "box")
        if margin != 0 { setMargin(box, margin) }
        return box
    }

    static func append(_ parent: UnsafeMutablePointer<GtkWidget>,
                       _ children: UnsafeMutablePointer<GtkWidget>...) {
        for child in children {
            gtk_box_append(cast(parent, to: GtkBox.self), child)
        }
    }

    static func scroller(_ child: UnsafeMutablePointer<GtkWidget>,
                         horizontal: GtkPolicyType = GTK_POLICY_AUTOMATIC)
        -> UnsafeMutablePointer<GtkWidget> {
        let scroller = require(gtk_scrolled_window_new(), "scrolled window")
        let typed = opaque(scroller)
        gtk_scrolled_window_set_policy(typed, horizontal, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(typed, child)
        expand(scroller)
        return scroller
    }

    static func paned(_ orientation: GtkOrientation,
                      start: UnsafeMutablePointer<GtkWidget>,
                      end: UnsafeMutablePointer<GtkWidget>,
                      position: Int32) -> UnsafeMutablePointer<GtkWidget> {
        let paned = require(gtk_paned_new(orientation), "paned")
        let typed = opaque(paned)
        gtk_paned_set_start_child(typed, start)
        gtk_paned_set_end_child(typed, end)
        gtk_paned_set_position(typed, position)
        gtk_paned_set_resize_start_child(typed, 0)
        return paned
    }

    // MARK: - Leaves

    /// A label. `dim` and `monospace` map onto GTK's stock style classes, so the
    /// user's theme decides what they actually look like.
    static func label(_ text: String,
                      dim: Bool = false,
                      monospace: Bool = false,
                      bold: Bool = false,
                      ellipsize: Bool = false,
                      selectable: Bool = false,
                      xalign: Float = 0) -> UnsafeMutablePointer<GtkWidget> {
        let widget = require(gtk_label_new(text), "label")
        let label = opaque(widget)
        gtk_label_set_xalign(label, xalign)
        if ellipsize {
            gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_END)
            gtk_label_set_single_line_mode(label, 1)
            // An ellipsizing label still asks for its full natural width unless
            // it is told it may shrink, which pushes the whole pane wider than
            // its allocation and clips whatever sits at the edges.
            gtk_label_set_max_width_chars(label, 1)
        }
        if selectable { gtk_label_set_selectable(label, 1) }
        if dim { gtk_widget_add_css_class(widget, "dim-label") }
        if monospace { gtk_widget_add_css_class(widget, "monospace") }
        if bold { gtk_widget_add_css_class(widget, "heading") }
        return widget
    }

    static func button(_ title: String,
                       tooltip: String? = nil,
                       action: @escaping () -> Void) -> UnsafeMutablePointer<GtkWidget> {
        let button = require(gtk_button_new_with_label(title), "button")
        if let tooltip { gtk_widget_set_tooltip_text(button, tooltip) }
        connect(button, "clicked", action)
        return button
    }

    static func iconButton(_ iconName: String,
                           tooltip: String,
                           action: @escaping () -> Void) -> UnsafeMutablePointer<GtkWidget> {
        let button = require(gtk_button_new_from_icon_name(iconName), "button")
        gtk_widget_set_tooltip_text(button, tooltip)
        connect(button, "clicked", action)
        return button
    }

    static func listBox(selection: GtkSelectionMode = GTK_SELECTION_SINGLE)
        -> UnsafeMutablePointer<GtkWidget> {
        let widget = require(gtk_list_box_new(), "list box")
        gtk_list_box_set_selection_mode(opaque(widget), selection)
        return widget
    }

    /// Replaces a list box's rows wholesale. GitEnough rebuilds lists from
    /// freshly published model state rather than diffing them: the lists are a
    /// page long at most, and a rebuild can't drift out of sync with the model.
    static func replaceRows(_ listBox: UnsafeMutablePointer<GtkWidget>,
                            with rows: [UnsafeMutablePointer<GtkWidget>]) {
        let typed = opaque(listBox)
        gtk_list_box_remove_all(typed)
        for row in rows { gtk_list_box_append(typed, row) }
    }

    /// A placeholder for an empty list or an unselected pane.
    static func placeholder(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = label(text, dim: true, xalign: 0.5)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(label, 1)
        gtk_widget_set_hexpand(label, 1)
        return label
    }

    // MARK: - Attributes

    static func setMargin(_ widget: UnsafeMutablePointer<GtkWidget>, _ margin: Int32) {
        gtk_widget_set_margin_start(widget, margin)
        gtk_widget_set_margin_end(widget, margin)
        gtk_widget_set_margin_top(widget, margin)
        gtk_widget_set_margin_bottom(widget, margin)
    }

    static func expand(_ widget: UnsafeMutablePointer<GtkWidget>,
                       horizontal: Bool = true, vertical: Bool = true) {
        gtk_widget_set_hexpand(widget, horizontal ? 1 : 0)
        gtk_widget_set_vexpand(widget, vertical ? 1 : 0)
    }

    static func setVisible(_ widget: UnsafeMutablePointer<GtkWidget>, _ visible: Bool) {
        gtk_widget_set_visible(widget, visible ? 1 : 0)
    }

    static func setText(_ label: UnsafeMutablePointer<GtkWidget>, _ text: String) {
        gtk_label_set_text(opaque(label), text)
    }

    /// GTK's own style classes, used rather than hand-rolled CSS so GitEnough
    /// inherits whatever theme the desktop is running.
    static func addClass(_ widget: UnsafeMutablePointer<GtkWidget>, _ name: String) {
        gtk_widget_add_css_class(widget, name)
    }
}
