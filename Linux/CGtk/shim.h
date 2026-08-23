// One umbrella header for the whole GTK stack. GTK's own headers refuse to be
// included piecemeal, and pulling gtk.h in also brings GLib, GObject, Pango and
// Cairo, which is everything the front end talks to.
#include <gtk/gtk.h>
#include <glib-unix.h>

// libdispatch declares these only in its private headers, but exports them from
// the shared library: they are how CoreFoundation drains the main queue from a
// foreign run loop, and how GitEnough's GTK front end drains it from GLib's.
// Declaring them here is what lets the core keep using DispatchQueue.main.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);
