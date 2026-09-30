import CGtk

/// GTK's C API is a tower of structs joined by cast macros — `GTK_WIDGET(x)`,
/// `G_OBJECT(x)`, `GTK_BOX(x)` — and Swift imports none of them, because macros
/// aren't functions. What the macros do at runtime is nothing: GObject is C-style
/// single inheritance, so a `GtkButton *` and the `GtkWidget *` inside it are the
/// same address. These helpers are that same reinterpretation, spelled once here
/// instead of at every call site.
///
/// GTK 4 made most widget structs private, so Swift sees two flavours of the
/// same idea: a few types with public layout (`GtkWidget`, `GtkWindow`,
/// `GtkApplication`) arrive as typed pointers, and everything else arrives as an
/// `OpaquePointer`. Hence both `asWidget` and `opaque`.

/// Anything that is a GObject instance pointer, whichever flavour Swift chose.
protocol GObjectPointer {
    var rawObject: UnsafeMutableRawPointer { get }
}

extension UnsafeMutablePointer: GObjectPointer {
    var rawObject: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension OpaquePointer: GObjectPointer {
    var rawObject: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

/// Reinterprets one GObject pointer as another type with public layout.
///
/// `assumingMemoryBound` is the honest spelling: the memory really does begin
/// with the target struct — that is what C-style inheritance means — we are just
/// telling Swift what the C headers already know.
@inline(__always)
func cast<To>(_ pointer: some GObjectPointer, to type: To.Type = To.self)
    -> UnsafeMutablePointer<To> {
    pointer.rawObject.assumingMemoryBound(to: To.self)
}

/// `GTK_WIDGET(x)` — anything, seen as the base widget.
@inline(__always)
func asWidget(_ pointer: some GObjectPointer) -> UnsafeMutablePointer<GtkWidget> {
    cast(pointer)
}

/// The same instance, for the GTK 4 types whose struct layout is private.
@inline(__always)
func opaque(_ pointer: some GObjectPointer) -> OpaquePointer {
    OpaquePointer(pointer.rawObject)
}

/// Widgets arrive from GTK as implicitly-unwrapped optionals; a nil here would
/// mean GTK itself failed to allocate, which is not a condition worth threading
/// an error type through the whole UI for.
@inline(__always)
func require<T>(_ pointer: T?, _ what: String,
                file: StaticString = #file, line: UInt = #line) -> T {
    guard let pointer else {
        fatalError("GTK returned no \(what)", file: file, line: line)
    }
    return pointer
}
