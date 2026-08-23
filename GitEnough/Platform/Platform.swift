import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The handful of desktop-integration calls the core needs but Foundation only
/// answers on Apple platforms: "open this in the browser", "move this to the
/// Trash", and "where does per-user application data live".
///
/// Everything else in `GitEnoughCore` is plain Foundation, so this file plus
/// `SecretStore` is the whole macOS/Linux seam below the UI.
public enum Platform {

    /// Hands `url` to the desktop environment — the browser for http(s), the
    /// file manager for file URLs. Returns false when nothing could take it.
    ///
    /// Non-blocking on both platforms: the helper is launched and forgotten, so
    /// a cold-starting browser can't stall a caller on the main thread.
    @discardableResult
    public static func open(_ url: URL) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        guard let opener = urlOpener else { return false }
        do {
            try ProcessRunner.launchDetached(opener.executable,
                                             opener.arguments + [url.absoluteString])
            return true
        } catch {
            return false
        }
        #endif
    }

    /// Moves `url` to the Trash, so a discarded untracked file stays
    /// recoverable. Blocking; call it off the main thread.
    public static func moveToTrash(_ url: URL) throws {
        #if canImport(AppKit)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        try FreedesktopTrash.trash(url)
        #endif
    }

    /// Per-user application data: `~/Library/Application Support` on macOS,
    /// `$XDG_DATA_HOME` (default `~/.local/share`) on Linux.
    ///
    /// Foundation's `.applicationSupportDirectory` lookup returns an empty list
    /// on Linux, so the XDG path is resolved by hand rather than subscripted
    /// into a crash.
    public static var applicationSupportDirectory: URL {
        #if canImport(AppKit)
        if let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first {
            return url
        }
        #endif
        return xdgDirectory(variable: "XDG_DATA_HOME", fallback: "/.local/share")
    }

    /// Per-user configuration: `$XDG_CONFIG_HOME` (default `~/.config`).
    public static var configurationDirectory: URL {
        xdgDirectory(variable: "XDG_CONFIG_HOME", fallback: "/.config")
    }

    /// An XDG base directory. Relative values are ignored, as the spec requires.
    public static func xdgDirectory(variable: String,
                             fallback: String,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: String = NSHomeDirectory()) -> URL {
        let configured = environment[variable].flatMap { $0.hasPrefix("/") ? $0 : nil }
        return URL(fileURLWithPath: configured ?? home + fallback)
    }

    #if !canImport(AppKit)
    /// The first URL handler this desktop has. `xdg-open` covers every
    /// freedesktop desktop; the rest are the fallbacks for a session where
    /// xdg-utils isn't installed but the desktop's own opener is.
    private static let urlOpener: (executable: URL, arguments: [String])? = {
        let candidates: [(String, [String])] = [
            ("xdg-open", []),
            ("gio", ["open"]),
            ("gnome-open", []),
            ("kde-open5", []),
            ("kde-open", []),
        ]
        for (name, arguments) in candidates {
            if let executable = ProcessRunner.which(name) {
                return (executable, arguments)
            }
        }
        return nil
    }()
    #endif
}
