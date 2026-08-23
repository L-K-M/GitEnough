import CGtk
import Dispatch
import Foundation
import GitEnough

/// The GTK application object and the process's main loop.
final class GitEnoughApplication {

    static let applicationID = "dev.gitenough.GitEnough"

    private let application: UnsafeMutablePointer<GtkApplication>
    private var window: MainWindow?

    init() {
        application = require(gtk_application_new(Self.applicationID,
                                                  G_APPLICATION_DEFAULT_FLAGS),
                              "GtkApplication")
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(application))
    }

    func run() -> Int32 {
        DispatchMainQueueBridge.install()
        connect(application, "activate") { [weak self] in
            guard let self else { return }
            // GTK may activate an application more than once (a second launch
            // hands the running instance the request); present what we have
            // rather than opening a second window on top of it.
            if let window {
                window.present()
            } else {
                window = MainWindow(application: application)
                window?.present()
            }
        }
        return g_application_run(cast(application, to: GApplication.self), 0, nil)
    }
}
