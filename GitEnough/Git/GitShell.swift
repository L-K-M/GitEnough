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

    /// Environment handed to every git child process. Built once — the PATH
    /// lookup hits the filesystem and re-running it for every git call would
    /// waste I/O. Tradeoff: tools installed after the first git command in a
    /// session stay invisible to hooks until the app relaunches. `static let`
    /// gives us thread-safe lazy initialization.
    private static let childEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        // Apps launched from Finder inherit launchd's bare PATH
        // (/usr/bin:/bin:/usr/sbin:/sbin), so git hooks that call node/npm/npx
        // (husky, lint-staged, …) die with "command not found". Append the
        // usual tool locations that actually exist on disk — purely additive;
        // an inherited PATH (e.g. when launched from Terminal) always wins.
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let nvmRoot = home + "/.nvm/versions/node"
        env["PATH"] = augmentedPATH(
            base: env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            home: home,
            directoryExists: { fm.fileExists(atPath: $0) },
            nvmVersionDirs: { (try? fm.contentsOfDirectory(atPath: nvmRoot)) ?? [] },
            fileContents: { try? String(contentsOfFile: $0, encoding: .utf8) })
        // Never let git block on a terminal credential/passphrase prompt — fail
        // fast instead and surface the error. HTTPS credentials still resolve
        // non-interactively via the osxkeychain helper; SSH via ssh-agent.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["SSH_ASKPASS"] = "/usr/bin/true"
        // Without a TTY ssh may ignore SSH_ASKPASS and probe /dev/tty instead;
        // force makes the fail-fast override deterministic (OpenSSH 8.4+).
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["LC_ALL"] = "en_US.UTF-8"
        // Keep hooks and editor invocations from opening an interactive editor.
        env["GIT_EDITOR"] = "/usr/bin/true"
        return env
    }()

    /// `base` PATH plus every well-known tool location that exists on disk, so
    /// git hooks can find node/npm/npx even under launchd's minimal PATH.
    /// Pure: filesystem access arrives through the closures so tests stub it.
    static func augmentedPATH(base: String,
                              home: String,
                              directoryExists: (String) -> Bool,
                              nvmVersionDirs: () -> [String],
                              fileContents: (String) -> String?) -> String {
        var extras = [
            "/opt/homebrew/bin",            // Homebrew on Apple Silicon
            "/usr/local/bin",               // Homebrew on Intel / node installer
            home + "/.local/bin",
            home + "/.volta/bin",
            home + "/.asdf/shims",
            home + "/.local/share/mise/shims",
            home + "/.bun/bin",
            home + "/.deno/bin",
            home + "/Library/pnpm",
            home + "/.local/share/pnpm",
            home + "/.yarn/bin",
        ]
        if let nvmBin = bestNvmBin(home: home, versionDirs: nvmVersionDirs(),
                                   fileContents: fileContents) {
            extras.append(nvmBin)
        }
        let existing = Set(base.split(separator: ":").map(String.init))
        let additions = extras.filter { directoryExists($0) && !existing.contains($0) }
        return additions.isEmpty ? base : base + ":" + additions.joined(separator: ":")
    }

    /// The `bin` directory of the nvm-installed node the user most likely
    /// expects: their `default` alias when it resolves to an installed version
    /// ("node"/"lts/*" aliases just mean "latest"), else the highest installed
    /// version. Hooks only need *a* working npm, so any of these is fine.
    private static func bestNvmBin(home: String,
                                   versionDirs: [String],
                                   fileContents: (String) -> String?) -> String? {
        let root = home + "/.nvm/versions/node"
        let installed = versionDirs.filter { $0.hasPrefix("v") && $0.contains(".") }
        guard !installed.isEmpty else { return nil }
        if let alias = fileContents(home + "/.nvm/alias/default")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty, alias != "node", !alias.hasPrefix("lts") {
            let want = alias.hasPrefix("v") ? alias : "v" + alias
            let matches = installed.filter { $0 == want || $0.hasPrefix(want + ".") }
            if let best = matches.max(by: isVersionOlder) {
                return root + "/" + best + "/bin"
            }
        }
        return installed.max(by: isVersionOlder).map { root + "/" + $0 + "/bin" }
    }

    /// Numeric version ordering ("v9.1.0" < "v10.0.0") for nvm directory names —
    /// a plain string sort would rank v9 above v10.
    private static func isVersionOlder(_ a: String, _ b: String) -> Bool {
        let pa = a.dropFirst().split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.dropFirst().split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
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
        process.environment = GitShell.childEnvironment
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
                           ? "git \(Self.displayCommand(args)) failed with exit code \(result.exitCode)."
                           : message,
                           exitCode: result.exitCode)
        }
        return result
    }

    /// The command name for the synthesized failure message, with the leading
    /// `-C <worktree>` pair every GitClient call starts with stripped — without
    /// it the message read "git -C failed with exit code 128", which names no
    /// command at all. Only the subcommand itself is returned ("pull", not the
    /// full "pull --tags"): the message is the rare empty-stderr fallback, and
    /// the argument list adds noise to an error that already has little signal.
    private static func displayCommand(_ args: [String]) -> String {
        var argv = args
        // `while`, not `if`: git accepts repeated -C pairs, and the loop
        // handles them uniformly if one ever reaches this path.
        while argv.count >= 2, argv[0] == "-C" {
            argv.removeFirst(2)
        }
        return argv.first ?? ""
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
        process.environment = GitShell.childEnvironment
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
