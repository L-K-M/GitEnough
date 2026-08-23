import CGtk

/// Lets `DispatchQueue.main.async` work while GLib owns the main loop.
///
/// This is the hinge of the whole port. Every view model in the core hops to
/// `DispatchQueue.main` to publish state — the pattern the macOS app is built
/// on — but libdispatch's main queue only runs when *it* owns the main thread,
/// and here GTK does. Without a bridge, every one of those blocks would sit in
/// the queue forever and the UI would never update.
///
/// The fix is the one CoreFoundation uses on Apple platforms: ask libdispatch
/// for the main queue's wake-up handle (an eventfd on Linux), watch it from the
/// host run loop, and drain the queue whenever it signals. That keeps the core
/// completely unaware there is no libdispatch main loop underneath it, and it is
/// why `Model/` needed no Linux-specific changes at all.
enum DispatchMainQueueBridge {

    private static var installed = false

    /// Call once, before `g_application_run`. Asking for the handle is also what
    /// switches the main queue into externally-drained mode, so it must happen
    /// before anything enqueues work.
    static func install() {
        guard !installed else { return }
        installed = true

        let drain: @convention(c) (Int32, GIOCondition, gpointer?) -> gboolean = { _, _, _ in
            _dispatch_main_queue_callback_4CF(nil)
            return 1  // G_SOURCE_CONTINUE — stay subscribed for the process's life.
        }
        g_unix_fd_add_full(G_PRIORITY_HIGH_IDLE, _dispatch_get_main_queue_handle_4CF(),
                           G_IO_IN, drain, nil, nil)
    }
}
