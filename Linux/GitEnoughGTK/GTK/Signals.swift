import CGtk

/// Connecting a Swift closure to a GObject signal.
///
/// `g_signal_connect` is a macro, so the real entry point is
/// `g_signal_connect_data`: a C function pointer plus a `user_data` blob plus a
/// destructor for it. A Swift closure is neither, so it goes into a box, the box
/// is passed as `user_data` with a +1 retain, and GObject's destroy-notify hands
/// the retain back when the widget dies. That is what keeps a closure capturing
/// a view model alive exactly as long as the widget that uses it.
private final class SignalBox {
    let handler: (UnsafeMutableRawPointer?) -> Void
    init(_ handler: @escaping (UnsafeMutableRawPointer?) -> Void) {
        self.handler = handler
    }
}

private let releaseBox: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<SignalBox>.fromOpaque(data).release()
}

/// Signals whose handler takes only the emitting instance: `clicked`,
/// `activate`, `changed`, `value-changed`, …
@discardableResult
func connect(_ instance: some GObjectPointer,
             _ signal: String,
             _ handler: @escaping () -> Void) -> gulong {
    let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
        _, data in
        guard let data else { return }
        Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue().handler(nil)
    }
    return g_signal_connect_data(
        instance.rawObject, signal,
        unsafeBitCast(trampoline, to: GCallback.self),
        Unmanaged.passRetained(SignalBox { _ in handler() }).toOpaque(),
        releaseBox, GConnectFlags(0))
}

/// Signals that hand the handler one argument before `user_data` —
/// `row-selected` (the row), `row-activated` (the row), `notify::` (the pspec).
/// The argument arrives untyped; the caller knows what it is.
@discardableResult
func connect(_ instance: some GObjectPointer,
             _ signal: String,
             _ handler: @escaping (UnsafeMutableRawPointer?) -> Void) -> gulong {
    let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                    UnsafeMutableRawPointer?) -> Void = { _, argument, data in
        guard let data else { return }
        Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue().handler(argument)
    }
    return g_signal_connect_data(
        instance.rawObject, signal,
        unsafeBitCast(trampoline, to: GCallback.self),
        Unmanaged.passRetained(SignalBox(handler)).toOpaque(),
        releaseBox, GConnectFlags(0))
}

/// Runs `body` on the next main-loop iteration. Used where GTK forbids mutating
/// a widget from inside its own callback (rebuilding a list box from a
/// `row-selected` handler, for one).
func onNextMainLoopTurn(_ body: @escaping () -> Void) {
    let trampoline: GSourceFunc = { data in
        guard let data else { return 0 }
        Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue().handler(nil)
        return 0  // G_SOURCE_REMOVE — one shot.
    }
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, trampoline,
                    Unmanaged.passRetained(SignalBox { _ in body() }).toOpaque(),
                    { data in
                        guard let data else { return }
                        Unmanaged<SignalBox>.fromOpaque(data).release()
                    })
}
