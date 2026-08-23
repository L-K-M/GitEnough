import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs the short-lived helper processes the platform layer needs — `xdg-open`,
/// `secret-tool`, and PATH lookups for merge tools.
///
/// `GitShell` stays the only way to run *git*: it owns the child environment and
/// the per-repo serial queue. This is the much smaller sibling for everything
/// else, and it never blocks on a process that outlives the call
/// (`launchDetached`).
public enum ProcessRunner {

    public struct Result {
        public let stdout: Data
        public let stderr: String
        public let exitCode: Int32

        public var standardOutput: String { String(decoding: stdout, as: UTF8.self) }
        public var succeeded: Bool { exitCode == 0 }
    }

    public enum RunError: Error, LocalizedError {
        case notFound(String)
        case launchFailed(String, underlying: String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "\(name) is not installed."
            case .launchFailed(let name, let underlying):
                return "Could not run \(name): \(underlying)"
            }
        }
    }

    /// Writing to a child that has already exited raises SIGPIPE, and its
    /// default action is to kill *us* — the write is never allowed to fail, so
    /// there is no error for the call site to swallow. Ignoring the signal
    /// process-wide turns a broken pipe back into an ordinary EPIPE error.
    ///
    /// Process-wide is the only option that works: Darwin can suppress it
    /// per-descriptor with `F_SETNOSIGPIPE`, Linux has no equivalent for pipes.
    /// It is also the strictly safer default for a GUI app — nothing here wants
    /// a closed pipe to be fatal — and it is installed lazily on first use
    /// rather than from an app delegate the Linux build doesn't have.
    public static let brokenPipesAreErrors: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Runs `executable`, optionally feeding `input` to its stdin, and waits.
    ///
    /// **Blocking** — call it off the main thread. stdout is drained on a helper
    /// thread and stdin is written on another so a child that talks on both
    /// pipes can't deadlock against a full buffer.
    public static func run(_ executable: URL,
                    _ arguments: [String],
                    input: Data? = nil) throws -> Result {
        _ = brokenPipesAreErrors
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
                // With SIGPIPE ignored (above), a child that exited before
                // draining its stdin makes this throw EPIPE instead of killing
                // the process. Nothing to report: the child is already gone and
                // its exit code is the outcome the caller wants.
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
        public var value = Data()
    }

    /// Starts `executable` and returns without waiting.
    ///
    /// Used for handing a URL or a file to the desktop environment: those
    /// helpers can outlive the call by minutes (a browser cold start), and
    /// waiting for them on any of GitEnough's queues would jam it.
    public static func launchDetached(_ executable: URL, _ arguments: [String]) throws {
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
    public static func which(_ name: String, searchPath: String? = nil) -> URL? {
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
    public static var defaultSearchPath: String {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var extras = ["/usr/local/bin", "/usr/bin", "/bin"]
        #if os(Linux)
        // Snap and Flatpak exports are where a lot of Ubuntu GUI tools live.
        extras += ["/snap/bin", "/var/lib/flatpak/exports/bin",
                   NSHomeDirectory() + "/.local/share/flatpak/exports/bin"]
        #else
        extras += ["/opt/homebrew/bin"]
        #endif
        // Dedupe across the whole list, not just the additions: an inherited
        // PATH that already repeats a directory (shell rc files and CI images
        // both do it) would otherwise carry the duplicate through. First
        // occurrence wins, so inherited entries keep their precedence.
        var seen = Set<String>()
        return (inherited.split(separator: ":").map(String.init) + extras)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }
}
