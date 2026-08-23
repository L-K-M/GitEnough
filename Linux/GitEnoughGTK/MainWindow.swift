import CGtk
import GitEnough

/// Temporary shell so the target links; the real two-pane window follows.
final class MainWindow {
    private let window: UnsafeMutablePointer<GtkWindow>

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = cast(require(gtk_application_window_new(application), "window"))
        gtk_window_set_title(window, "GitEnough")
        gtk_window_set_default_size(window, 1100, 700)
    }

    func present() {
        gtk_window_present(window)
    }
}
