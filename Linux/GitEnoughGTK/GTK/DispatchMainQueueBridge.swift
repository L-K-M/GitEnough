import CGtk
#if canImport(Glibc)
import Glibc
#endif

/// Lets `DispatchQueue.main.async` work while GLib owns the main loop.
///
/// This is the hinge of the whole port. Every view model in the core publishes
/// state by hopping to `DispatchQueue.main` — the pattern the macOS app is built
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

        let drain: @convention(c) (Int32, GIOCondition, gpointer?) -> gboolean = { handle, _, _ in
            // Consume the wake-up token first. libdispatch signals an eventfd to
            // say "the main queue has work"; draining the queue does not clear
            // it. Leaving it readable makes GLib re-dispatch this source
            // immediately and forever — a spin at 100% CPU that also starves
            // every lower-priority source, which in this app means the idle
            // callbacks the UI refreshes itself from.
            var token: UInt64 = 0
            _ = withUnsafeMutablePointer(to: &token) {
                read(handle, $0, MemoryLayout<UInt64>.size)
            }
            _dispatch_main_queue_callback_4CF(nil)
            return 1  // G_SOURCE_CONTINUE — stay subscribed for the process's life.
        }
        // Default priority, not idle: work posted to the main queue is the model
        // publishing state, which should not queue behind redraws.
        g_unix_fd_add_full(G_PRIORITY_DEFAULT, _dispatch_get_main_queue_handle_4CF(),
                           G_IO_IN, drain, nil, nil)
    }
}
