import Foundation

/// A single invocation of the `git` CLI.
struct GitResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

/// An error running git: either the binary is missing, or git itself exited
/// non-zero (in which case `message` is git's stderr, which is usually the
/// message a user needs to see — "not a git repository", merge conflicts, …).
struct GitError: Error, LocalizedError {
    let message: String
    let exitCode: Int32

    var errorDescription: String? { message }
}

/// Thin synchronous wrapper around the `git` binary.
///
/// GitEnough shells out to the user's own git (like GitHub Desktop shells out to
/// dugite) instead of linking libgit2: it behaves exactly like the command line the
/// user already knows, respects their config/credentials/hooks, and adds no
/// third-party dependency.
///
/// All methods are **synchronous and blocking** — call them from a background
/// queue (each `RepoViewModel` owns a serial queue for exactly this). Process
/// stdout/stderr are drained on helper threads so large output can't deadlock the
/// pipe.
final class GitShell {

    /// Shared instance; the shell is stateless (every call takes the working dir).
    static let shared = GitShell()

    /// Resolved path to a working git binary, or nil when Xcode CLT is missing.
    private(set) var gitURL: URL?

    private init() {
        gitURL = Self.findGit()
    }

    /// True when a runnable git was found at launch.
    var isAvailable: Bool { gitURL != nil }

    /// Re-probe for git (used after the user installs the Command Line Tools).
    func reprobe() {
        gitURL = Self.findGit()
    }

    private static func findGit() -> URL? {
        let candidates = [
            "/usr/bin/git",                 // Xcode CLT shim (always present on macOS with CLT)
            "/opt/homebrew/bin/git",        // Homebrew on Apple Silicon
            "/usr/local/bin/git",           // Homebrew on Intel / git installer
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Running

    /// Runs git with `args` in `directory` and returns the raw result without
    /// throwing on non-zero exit. Throws only when git can't be executed at all.
    @discardableResult
    func run(_ args: [String], in directory: URL?) throws -> GitResult {
        guard let gitURL else {
            throw GitError(message: "git is not installed. Install the Xcode Command Line Tools (`xcode-select --install`) and relaunch GitEnough.", exitCode: -1)
        }

        let process = Process()
        process.executableURL = gitURL
        if let directory {
            process.currentDirectoryURL = directory
        }
        // Never let git block on a terminal credential/passphrase prompt — fail
        // fast instead and surface the error. HTTPS credentials still resolve
        // non-interactively via the osxkeychain helper; SSH via ssh-agent.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS"] = "/usr/bin/true"
        environment["LC_ALL"] = "en_US.UTF-8"
        // Keep hooks and editor invocations from opening an interactive editor.
        environment["GIT_EDITOR"] = "/usr/bin/true"
        process.environment = environment
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw GitError(message: "Failed to launch git: \(error.localizedDescription)", exitCode: -1)
        }

        // Drain both pipes concurrently: a full pipe buffer would otherwise block
        // the child mid-write and deadlock waitUntilExit().
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let stdout = String(data: outData, encoding: .utf8)
            ?? String(decoding: outData, as: UTF8.self)
        let stderr = String(data: errData, encoding: .utf8)
            ?? String(decoding: errData, as: UTF8.self)
        return GitResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    /// Runs git with `args`, piping `stdin` to the process (used by `git commit -F -`).
    /// Throws `GitError` carrying stderr when the exit code is non-zero.
    func runChecked(_ args: [String],
                    in directory: URL?,
                    stdin: String? = nil) throws -> GitResult {
        let result: GitResult
        if let stdin {
            result = try runWithStdin(args, in: directory, stdin: stdin)
        } else {
            result = try run(args, in: directory)
        }
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: message.isEmpty
                           ? "git \(args.first ?? "") failed with exit code \(result.exitCode)."
                           : message,
                           exitCode: result.exitCode)
        }
        return result
    }

    /// Separate entry point because `standardInput` must be assigned before `run()`.
    private func runWithStdin(_ args: [String], in directory: URL?, stdin: String) throws -> GitResult {
        guard let gitURL else {
            throw GitError(message: "git is not installed. Install the Xcode Command Line Tools (`xcode-select --install`) and relaunch GitEnough.", exitCode: -1)
        }
        let process = Process()
        process.executableURL = gitURL
        if let directory {
            process.currentDirectoryURL = directory
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS"] = "/usr/bin/true"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        process.environment = environment
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do {
            try process.run()
        } catch {
            throw GitError(message: "Failed to launch git: \(error.localizedDescription)", exitCode: -1)
        }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        // Write stdin on its own thread too: a message larger than the pipe buffer
        // must not block while the child is also writing to stderr.
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let stdout = String(data: outData, encoding: .utf8)
            ?? String(decoding: outData, as: UTF8.self)
        let stderr = String(data: errData, encoding: .utf8)
            ?? String(decoding: errData, as: UTF8.self)
        return GitResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
