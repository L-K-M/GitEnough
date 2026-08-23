import CGtk

/// Setting GObject properties without `g_object_set`.
///
/// `g_object_set` is variadic, so Swift can't call it, and GTK exposes some
/// things — text-tag colours, most notably — only as properties with no typed
/// setter. The non-variadic `g_object_set_property` takes a `GValue`, which is
/// what these wrap.
enum Properties {

    static func set(_ object: some GObjectPointer, _ name: String, _ value: String) {
        withValue(gitenough_type_string()) { boxed in
            g_value_set_string(boxed, value)
            g_object_set_property(cast(object, to: GObject.self), name, boxed)
        }
    }

    static func set(_ object: some GObjectPointer, _ name: String, _ value: Bool) {
        withValue(gitenough_type_boolean()) { boxed in
            g_value_set_boolean(boxed, value ? 1 : 0)
            g_object_set_property(cast(object, to: GObject.self), name, boxed)
        }
    }

    static func set(_ object: some GObjectPointer, _ name: String, _ value: Int32) {
        withValue(gitenough_type_int()) { boxed in
            g_value_set_int(boxed, value)
            g_object_set_property(cast(object, to: GObject.self), name, boxed)
        }
    }

    /// Reads a boolean property. Used for the theme's dark-mode flag, which GTK
    /// exposes on GtkSettings and nowhere else.
    static func bool(_ object: some GObjectPointer, _ name: String) -> Bool {
        var result = false
        withValue(gitenough_type_boolean()) { boxed in
            g_object_get_property(cast(object, to: GObject.self), name, boxed)
            result = g_value_get_boolean(boxed) != 0
        }
        return result
    }

    /// A zero-initialised `GValue`, typed, handed to `body`, then unset. GValue
    /// must start life as all-zeroes or `g_value_init` refuses it.
    private static func withValue(_ type: GType,
                                  _ body: (UnsafeMutablePointer<GValue>) -> Void) {
        var value = GValue()
        withUnsafeMutablePointer(to: &value) { pointer in
            g_value_init(pointer, type)
            body(pointer)
            g_value_unset(pointer)
        }
    }
}
