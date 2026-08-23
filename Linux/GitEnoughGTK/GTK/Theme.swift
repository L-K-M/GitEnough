import CGtk

/// Whether the desktop is running a dark theme.
///
/// The graph's lane colours are brighter in dark mode — the same adjustment the
/// macOS front end makes from `colorScheme` — so the strips need an answer.
/// GTK only exposes it as a GtkSettings property, and the theme name is the
/// fallback for desktops that ship a separate dark theme instead of the flag.
enum Theme {

    static var isDark: Bool {
        guard let settings = gtk_settings_get_default() else { return false }
        if Properties.bool(settings, "gtk-application-prefer-dark-theme") { return true }
        return themeName.lowercased().contains("dark")
    }

    private static var themeName: String {
        guard let settings = gtk_settings_get_default() else { return "" }
        var name = ""
        var value = GValue()
        withUnsafeMutablePointer(to: &value) { boxed in
            g_value_init(boxed, gitenough_type_string())
            g_object_get_property(cast(settings, to: GObject.self), "gtk-theme-name", boxed)
            if let raw = g_value_get_string(boxed) { name = String(cString: raw) }
            g_value_unset(boxed)
        }
        return name
    }

    /// Re-runs `onChange` when the user switches between light and dark, so open
    /// graph strips repaint instead of staying at yesterday's contrast.
    static func onChange(_ onChange: @escaping () -> Void) {
        guard let settings = gtk_settings_get_default() else { return }
        connect(settings, "notify::gtk-application-prefer-dark-theme") { _ in onChange() }
        connect(settings, "notify::gtk-theme-name") { _ in onChange() }
    }
}
