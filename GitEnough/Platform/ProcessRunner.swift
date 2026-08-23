import Foundation

/// Runs the short-lived helper processes the platform layer needs — `xdg-open`,
/// `secret-tool`, and PATH lookups for merge tools.
///
/// `GitShell` stays the only way to run *git*: it owns the child environment and
/// the per-repo serial queue. This is the much smaller sibling for everything
/// else, and it never blocks on a process that outlives the call
/// (`launchDetached`).
enum ProcessRunner {

    struct Result {
        let stdout: Data
        let stderr: String
        let exitCode: Int32

        var standardOutput: String { String(decoding: stdout, as: UTF8.self) }
        var succeeded: Bool { exitCode == 0 }
    }

    enum RunError: Error, LocalizedError {
        case notFound(String)
        case launchFailed(String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "\(name) is not installed."
            case .launchFailed(let name, let underlying):
                return "Could not run \(name): \(underlying)"
            }
        }
    }

    /// Runs `executable`, optionally feeding `input` to its stdin, and waits.
    ///
    /// **Blocking** — call it off the main thread. stdout is drained on a helper
    /// thread and stdin is written on another so a child that talks on both
    /// pipes can't deadlock against a full buffer.
    static func run(_ executable: URL,
                    _ arguments: [String],
                    input: Data? = nil) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(executable.lastPathComponent,
                                        underlying: error.localizedDescription)
        }

        let out = DataBox()
        let err = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            out.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            err.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if let inPipe, let input {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                // A child that exits before reading turns the write into SIGPIPE;
                // Foundation's FileHandle raises it as an ObjC exception on Darwin
                // and an error on Linux, so guard both with `try?`.
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
                group.leave()
            }
        }
        process.waitUntilExit()
        group.wait()

        return Result(stdout: out.value,
                      stderr: String(decoding: err.value, as: UTF8.self)
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      exitCode: process.terminationStatus)
    }

    /// Hand-off box for a draining thread's output. The `DispatchGroup` above is
    /// the synchronisation — the value is written once before `leave()` and read
    /// only after `wait()` — so the unchecked conformance is carrying a fact the
    /// compiler can't see rather than papering over a race.
    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    /// Starts `executable` and returns without waiting.
    ///
    /// Used for handing a URL or a file to the desktop environment: those
    /// helpers can outlive the call by minutes (a browser cold start), and
    /// waiting for them on any of GitEnough's queues would jam it.
    static func launchDetached(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(executable.lastPathComponent,
                                        underlying: error.localizedDescription)
        }
    }

    /// The first executable called `name` on `searchPath` (defaults to the
    /// inherited PATH plus the handful of directories a desktop session tends
    /// to have but a launchd/systemd-started process does not).
    static func which(_ name: String, searchPath: String? = nil) -> URL? {
        // An absolute or relative path is a path, not something to look up.
        guard !name.contains("/") else {
            return FileManager.default.isExecutableFile(atPath: name)
                ? URL(fileURLWithPath: name) : nil
        }
        let path = searchPath ?? defaultSearchPath
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// PATH as inherited, with the usual desktop tool directories appended.
    /// Additive only: an inherited entry always wins on ordering.
    static var defaultSearchPath: String {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var extras = ["/usr/local/bin", "/usr/bin", "/bin"]
        #if os(Linux)
        // Snap and Flatpak exports are where a lot of Ubuntu GUI tools live.
        extras += ["/snap/bin", "/var/lib/flatpak/exports/bin",
                   NSHomeDirectory() + "/.local/share/flatpak/exports/bin"]
        #else
        extras += ["/opt/homebrew/bin"]
        #endif
        let existing = Set(inherited.split(separator: ":").map(String.init))
        let additions = extras.filter { !existing.contains($0) }
        if inherited.isEmpty { return additions.joined(separator: ":") }
        return additions.isEmpty ? inherited
            : inherited + ":" + additions.joined(separator: ":")
    }
}
