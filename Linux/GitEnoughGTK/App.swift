import CGtk
import Dispatch
import Foundation
import GitEnough

/// The GTK application object and the process's main loop.
///
/// `GApplication` is single-instance: launching `gitenough-gtk ~/code/other`
/// while GitEnough is already running hands the arguments to the running
/// process instead of starting a second one. That is the desktop-native
/// behaviour, and it is why the folder arguments go through GTK's `open` signal
/// rather than being read from `CommandLine` at startup — a second launch has
/// no startup left to read them at.
final class GitEnoughApplication {

    static let applicationID = "dev.gitenough.GitEnough"

    private let application: UnsafeMutablePointer<GtkApplication>
    private var window: MainWindow?

    init() {
        application = require(gtk_application_new(Self.applicationID,
                                                  G_APPLICATION_HANDLES_OPEN),
                              "GtkApplication")
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(application))
    }

    func run() -> Int32 {
        DispatchMainQueueBridge.install()

        // Launched with no arguments.
        connect(application, "activate") { [weak self] in
            self?.showWindow().present()
        }

        // Launched with folders to open — including a launch handed over to this
        // already-running process. The signal's C signature carries the file
        // array, so it needs its own trampoline rather than the generic one.
        let opened: @convention(c) (UnsafeMutableRawPointer?,
                                    UnsafeMutablePointer<OpaquePointer?>?,
                                    Int32, UnsafePointer<CChar>?,
                                    UnsafeMutableRawPointer?) -> Void = { _, files, count, _, data in
            guard let data else { return }
            let application = Unmanaged<GitEnoughApplication>.fromOpaque(data)
                .takeUnretainedValue()
            var paths: [String] = []
            for index in 0..<Int(count) {
                guard let file = files?[index], let path = g_file_get_path(file) else { continue }
                paths.append(String(cString: path))
                g_free(path)
            }
            let window = application.showWindow()
            window.open(paths: paths)
            window.present()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(application), "open",
                              unsafeBitCast(opened, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(0))

        // Hand GTK the real argv so it parses the folder arguments itself.
        return g_application_run(cast(application, to: GApplication.self),
                                 CommandLine.argc, CommandLine.unsafeArgv)
    }

    /// The window, created on first use. GTK can activate an application more
    /// than once; the second time should raise what is already open.
    private func showWindow() -> MainWindow {
        if let window { return window }
        let window = MainWindow(application: application)
        self.window = window
        return window
    }
}
