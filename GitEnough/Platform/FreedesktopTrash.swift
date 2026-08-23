import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The freedesktop.org Trash specification (v1.0) — Linux's answer to
/// `FileManager.trashItem`, which Foundation only implements on Apple platforms.
///
/// GitEnough discards untracked files by moving them to the Trash rather than
/// unlinking them, so a mis-click stays recoverable. On Ubuntu that means:
///
/// - the *home trash* at `$XDG_DATA_HOME/Trash` (`~/.local/share/Trash`) for
///   anything on the same filesystem as `$HOME`;
/// - a *volume trash* — `$topdir/.Trash/$uid` when the admin-created `.Trash`
///   passes the spec's sticky-bit/symlink check, else `$topdir/.Trash-$uid` —
///   for anything else, because the trash has to be a rename away: copying a
///   directory across filesystems is neither atomic nor cheap.
///
/// Every trashed item gets a `info/<name>.trashinfo` companion recording where
/// it came from, which is what makes "Restore" work in Nautilus/Dolphin.
///
/// The naming and encoding halves are pure so the tests can cover them on any
/// platform; only `trash(_:)` touches the filesystem.
public enum FreedesktopTrash {

    public enum TrashError: Error, LocalizedError {
        case noTrashDirectory(String)
        case couldNotReserveName(String)

        public var errorDescription: String? {
            switch self {
            case .noTrashDirectory(let path):
                return "No usable Trash directory for \(path)."
            case .couldNotReserveName(let name):
                return "Could not reserve a Trash entry for \(name)."
            }
        }
    }

    /// Moves `url` to the appropriate trash directory, writing its `.trashinfo`
    /// record first. Blocking; call it off the main thread.
    ///
    /// `homeTrash` is a seam for the tests, which must not be able to fill the
    /// developer's real Trash.
    public static func trash(_ url: URL, homeTrash: URL = homeTrashDirectory()) throws {
        let item = url.standardizedFileURL
        let trashDirectory = try trashDirectory(for: item, homeTrash: homeTrash)
        let files = trashDirectory.appendingPathComponent("files")
        let info = trashDirectory.appendingPathComponent("info")
        try createDirectory(files)
        try createDirectory(info)

        // The info file doubles as the lock on the name: creating it O_EXCL is
        // what the spec prescribes so two apps trashing "notes.txt" at the same
        // moment can't land on the same entry.
        let (name, handle) = try reserveName(item.lastPathComponent, in: info)
        defer { close(handle) }

        let recordedPath = originalPath(of: item, relativeTo: trashDirectory)
        let record = Data(trashInfo(originalPath: recordedPath, deletedAt: Date()).utf8)
        record.withUnsafeBytes { buffer in
            _ = write(handle, buffer.baseAddress, buffer.count)
        }

        do {
            try FileManager.default.moveItem(at: item,
                                             to: files.appendingPathComponent(name))
        } catch {
            // Never leave an info record pointing at nothing.
            try? FileManager.default.removeItem(
                at: info.appendingPathComponent(name + ".trashinfo"))
            throw error
        }
    }

    // MARK: - Pure helpers

    /// The body of a `.trashinfo` file. `Path` is percent-encoded exactly like a
    /// URL path (separators kept, everything else escaped), and `DeletionDate`
    /// is local wall-clock time with no zone marker — both per the spec.
    public static func trashInfo(originalPath: String, deletedAt: Date) -> String {
        let encoded = originalPath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? originalPath
        return """
        [Trash Info]
        Path=\(encoded)
        DeletionDate=\(deletionDateFormatter.string(from: deletedAt))

        """
    }

    /// The `Path` value for an item: absolute for the home trash, relative to
    /// the volume root for a volume trash, so the volume stays relocatable.
    public static func originalPath(of item: URL, relativeTo trashDirectory: URL) -> String {
        guard let topDirectory = volumeRoot(ofTrash: trashDirectory) else {
            return item.path
        }
        let prefix = topDirectory.hasSuffix("/") ? topDirectory : topDirectory + "/"
        guard item.path.hasPrefix(prefix) else { return item.path }
        return String(item.path.dropFirst(prefix.count))
    }

    /// The volume root a volume trash belongs to, or nil for the home trash.
    /// `/data/.Trash-1000` → `/data`; `/data/.Trash/1000` → `/data`.
    public static func volumeRoot(ofTrash trashDirectory: URL) -> String? {
        let name = trashDirectory.lastPathComponent
        if name.hasPrefix(".Trash-") {
            return trashDirectory.deletingLastPathComponent().path
        }
        if trashDirectory.deletingLastPathComponent().lastPathComponent == ".Trash" {
            return trashDirectory.deletingLastPathComponent()
                .deletingLastPathComponent().path
        }
        return nil
    }

    /// `name`, or `name.2`, `name.3`, … — the disambiguation Nautilus uses,
    /// inserted before the extension so "notes.txt" becomes "notes.2.txt".
    public static func candidateName(_ name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        // A dotfile with no extension (".env") must not lose its leading dot.
        guard !base.isEmpty, !ext.isEmpty else { return "\(name).\(attempt)" }
        return "\(base).\(attempt).\(ext)"
    }

    private static let deletionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    // MARK: - Filesystem

    /// Reserves a free `<name>.trashinfo` in `info` and returns the open
    /// descriptor. O_EXCL makes the reservation atomic against other trashers.
    private static func reserveName(_ name: String,
                                    in info: URL) throws -> (String, Int32) {
        for attempt in 1...1000 {
            let candidate = candidateName(name, attempt: attempt)
            let path = info.appendingPathComponent(candidate + ".trashinfo").path
            let handle = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if handle >= 0 { return (candidate, handle) }
            if errno != EEXIST {
                throw TrashError.couldNotReserveName(name)
            }
        }
        throw TrashError.couldNotReserveName(name)
    }

    /// Home trash when `item` lives on the same device, else the volume trash
    /// for the device it does live on.
    public static func trashDirectory(for item: URL, homeTrash home: URL) throws -> URL {
        try createDirectory(home)
        let itemDevice = deviceID(of: item.deletingLastPathComponent().path)
        if let itemDevice, itemDevice == deviceID(of: home.path) {
            return home
        }
        guard let itemDevice,
              let top = volumeRoot(containing: item.deletingLastPathComponent().path,
                                   device: itemDevice) else {
            throw TrashError.noTrashDirectory(item.path)
        }
        return try volumeTrashDirectory(topDirectory: top)
    }

    /// `$XDG_DATA_HOME/Trash`, defaulting to `~/.local/share/Trash`.
    public static func homeTrashDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        let dataHome = environment["XDG_DATA_HOME"].flatMap {
            $0.hasPrefix("/") ? $0 : nil          // the spec ignores relative values
        } ?? home + "/.local/share"
        return URL(fileURLWithPath: dataHome).appendingPathComponent("Trash")
    }

    /// The spec's two-step volume trash: an admin-provided `$topdir/.Trash`
    /// (which must be sticky and not a symlink) gets a per-uid subdirectory;
    /// otherwise we create `$topdir/.Trash-$uid` ourselves.
    private static func volumeTrashDirectory(topDirectory: String) throws -> URL {
        let uid = getuid()
        let shared = URL(fileURLWithPath: topDirectory).appendingPathComponent(".Trash")
        if isStickyDirectory(shared.path) {
            let mine = shared.appendingPathComponent("\(uid)")
            if (try? createDirectory(mine)) != nil { return mine }
        }
        let mine = URL(fileURLWithPath: topDirectory)
            .appendingPathComponent(".Trash-\(uid)")
        do {
            try createDirectory(mine)
        } catch {
            throw TrashError.noTrashDirectory(topDirectory)
        }
        return mine
    }

    /// Walks up from `path` while the device stays the same; the last directory
    /// that matches is the mount point.
    private static func volumeRoot(containing path: String, device: dev_t) -> String? {
        var current = URL(fileURLWithPath: path)
        var best: String? = deviceID(of: current.path) == device ? current.path : nil
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            guard deviceID(of: parent.path) == device else { break }
            best = parent.path
            current = parent
        }
        return best
    }

    private static func deviceID(of path: String) -> dev_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_dev
    }

    /// Sticky, a real directory, and not a symlink — the spec's guard against a
    /// planted `.Trash` redirecting other users' deletions.
    private static func isStickyDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & S_ISVTX) != 0
    }

    @discardableResult
    private static func createDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }
}
