import XCTest
// dup/dup2/STDIN_FILENO for the inherited-stdin regression test. Same
// conditional import Platform/ProcessRunner.swift uses.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import GitEnough

/// PATH augmentation for git child processes: apps launched from Finder get
/// launchd's bare PATH, and git hooks (husky, lint-staged) calling npm would
/// die with "command not found" without the well-known tool locations.
final class GitShellEnvironmentTests: XCTestCase {

    private let home = "/Users/test"

    private func augmented(base: String = "/usr/bin:/bin",
                           existingDirs: Set<String> = [],
                           nvmVersions: [String] = [],
                           files: [String: String] = [:]) -> String {
        GitShell.augmentedPATH(base: base,
                               home: home,
                               directoryExists: { existingDirs.contains($0) },
                               nvmVersionDirs: { nvmVersions },
                               fileContents: { files[$0] })
    }

    func testExistingToolDirectoriesAreAppended() {
        let path = augmented(existingDirs: ["/opt/homebrew/bin", home + "/.bun/bin"])
        XCTAssertEqual(path, "/usr/bin:/bin:/opt/homebrew/bin:\(home)/.bun/bin")
    }

    func testMissingDirectoriesAreSkipped() {
        XCTAssertEqual(augmented(), "/usr/bin:/bin")
    }

    func testDirectoriesAlreadyOnPathAreNotDuplicated() {
        let path = augmented(base: "/opt/homebrew/bin:/usr/bin:/bin",
                             existingDirs: ["/opt/homebrew/bin"])
        XCTAssertEqual(path, "/opt/homebrew/bin:/usr/bin:/bin")
    }

    func testLatestNvmVersionWinsByDefault() {
        // A string sort would rank "v9.11.2" above "v10.2.0"; numeric ordering
        // must pick v10.
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v10.2.0/bin"],
                             nvmVersions: ["v9.11.2", "v10.2.0"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v10.2.0/bin"))
    }

    func testNvmDefaultAliasSelectsMatchingVersion() {
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v18.20.4/bin"],
                             nvmVersions: ["v18.20.4", "v22.11.0"],
                             files: [home + "/.nvm/alias/default": "18\n"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v18.20.4/bin"))
    }

    func testNvmNodeAliasMeansLatest() {
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v22.11.0/bin"],
                             nvmVersions: ["v18.20.4", "v22.11.0"],
                             files: [home + "/.nvm/alias/default": "node"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v22.11.0/bin"))
    }

    func testNvmAliasPointingAtUninstalledVersionFallsBackToLatest() {
        // default=20 with only v18/v22 installed must not strand the user with
        // no node at all — fall back to the highest installed version.
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v22.11.0/bin"],
                             nvmVersions: ["v18.20.4", "v22.11.0"],
                             files: [home + "/.nvm/alias/default": "20"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v22.11.0/bin"))
    }

    func testStrayEntriesInNvmVersionsDirectoryAreIgnored() {
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v20.1.0/bin"],
                             nvmVersions: [".cache", "v20.1.0"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v20.1.0/bin"))
    }

    func testRepositoryRoutingEnvironmentIsRemoved() {
        let unsafe = [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE", "GIT_REPLACE_REF_BASE",
            "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES",
            "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_CONFIG",
            "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
            "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0",
            "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS",
            "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
        ]
        let input = Dictionary(uniqueKeysWithValues: unsafe.map { ($0, "hostile") })

        let result = GitShell.sanitizedEnvironment(input)

        XCTAssertTrue(result.isEmpty)
    }

    func testUserWideConfigurationAndAuthenticationEnvironmentIsPreserved() {
        let input = [
            "PATH": "/custom/bin:/usr/bin",
            "HOME": home,
            "GIT_CONFIG_GLOBAL": home + "/.gitconfig-work",
            "GIT_CONFIG_SYSTEM": "/etc/gitconfig",
            "GIT_SSH_COMMAND": "ssh -F ~/.ssh/work-config",
            "SSH_AUTH_SOCK": "/tmp/agent.sock",
            "HTTPS_PROXY": "http://localhost:8080",
        ]

        XCTAssertEqual(GitShell.sanitizedEnvironment(input), input)
    }

    // MARK: - Child stdin

    /// The digest git itself would produce for `contents`, so these tests assert
    /// "the child read exactly these bytes" rather than "SHA-1 of these bytes is
    /// this constant". `hash-object` uses the *effective* object format, so a
    /// machine with `GIT_DEFAULT_HASH=sha256` would fail a hardcoded SHA-1
    /// expectation for a reason that has nothing to do with stdin.
    private func expectedHash(of contents: String) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try contents.write(to: file, atomically: true, encoding: .utf8)
        // `--no-filters`, because `hash-object <file>` runs the attributes
        // machinery — CRLF conversion included — while `--stdin` hashes raw
        // bytes with no path to look filters up for. A machine with a global
        // `core.attributesFile` saying `* text=auto` would make the two digests
        // differ for a reason that has nothing to do with stdin. Same class of
        // environment skew as the `GIT_DEFAULT_HASH` one this helper exists for.
        return try GitShell.shared.runChecked(
            ["hash-object", "--no-filters", "--", file.path], in: nil)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every git child gets `/dev/null` on stdin. Without it Foundation's
    /// `Process` hands the child *our* fd 0 — the launching terminal's tty when
    /// the app is started from a shell — and a git command that asks a question
    /// blocks forever on a terminal nobody is watching, with the question itself
    /// invisible because it goes to the captured stdout.
    ///
    /// `git hash-object --stdin` reads stdin to EOF and prints the hash of what
    /// it read, so matching the empty file's digest says the child saw EOF.
    ///
    /// On its own that is **not** a regression test: CI runs with the runner's
    /// own stdin already at EOF, so an inherited fd 0 hashes empty too and this
    /// passes with or without the fix. `testAnInheritedStdinWouldBeVisible`
    /// below is the one that can actually fail; this one pins the ordinary case.
    func testGitChildrenSeeAnEmptyStdin() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }
        let result = try GitShell.shared.run(["hash-object", "--stdin"], in: nil)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       try expectedHash(of: ""),
                       "the child must read an empty stdin, not the parent's")
    }

    /// The regression test with teeth: put **non-empty** bytes on the test
    /// runner's own fd 0, so inheriting it is distinguishable from `/dev/null`.
    ///
    /// Without this, every stdin assertion in this file passes whether or not
    /// `GitShell.run` sets `standardInput` — CI runs with stdin already at EOF,
    /// so an inherited descriptor hashes empty exactly like the null device
    /// does. The failure would only appear from an interactive terminal, and
    /// there it manifests as a hang rather than a red test.
    ///
    /// `dup2` a file of sentinel bytes over fd 0 for the duration of one call
    /// and restore it afterwards. With the fix, the child hashes empty; without
    /// it, the child hashes the sentinel and both assertions below fail.
    ///
    /// fd 0 is process-global, so this is only safe while nothing else in the
    /// same process spawns a child during that window. XCTest runs the methods
    /// of a class serially, and Xcode's test parallelism forks separate runner
    /// *processes* — separate descriptor tables, so that is safe too. What is
    /// not is in-process parallelism: swift-testing parallelizes by default, so
    /// a port of this file has to mark this test serialized.
    func testAnInheritedStdinWouldBeVisible() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }
        let sentinelText = "SENTINEL-\(UUID().uuidString)\n"
        // Both digests computed before fd 0 is touched, to keep that window to
        // the single call under test.
        let emptyHash = try expectedHash(of: "")
        let sentinelHash = try expectedHash(of: sentinelText)
        XCTAssertNotEqual(emptyHash, sentinelHash, "precondition: the two differ")

        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnough-stdin-\(UUID().uuidString)")
        try sentinelText.write(to: sentinel, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let reader = try FileHandle(forReadingFrom: sentinel)
        defer { try? reader.close() }

        let savedStdin = dup(STDIN_FILENO)
        try XCTSkipIf(savedStdin < 0, "cannot duplicate this runner's stdin")
        // Restored before anything else runs: leaving the suite's fd 0 pointing
        // at a deleted temp file would be a very confusing thing to debug.
        defer {
            // Closed only if the restore took. A failed `dup2` would otherwise
            // leave fd 0 on the sentinel — about to be deleted — *and* drop the
            // last reference to the runner's real stdin, which is the opposite
            // of what this defer is for.
            if dup2(savedStdin, STDIN_FILENO) >= 0 { close(savedStdin) }
        }
        // Skip, not assert, and for the reason the `dup` above already skips:
        // an assertion records a failure and keeps going, so a failed `dup2`
        // would leave fd 0 at the runner's own stdin and the two hash checks
        // below would compare against an empty stdin and pass — green
        // assertions next to one red setup line, with the discriminating power
        // of the test silently gone for that run.
        guard dup2(reader.fileDescriptor, STDIN_FILENO) >= 0 else {
            throw XCTSkip("could not place the sentinel on fd 0")
        }

        let result = try GitShell.shared.run(["hash-object", "--stdin"], in: nil)
        // First, because every other failure here reads as a stdin failure: git
        // failing to launch leaves `stdout` empty, `hashed` becomes "", and the
        // assertion below fails saying the child read the parent's fd 0 — which
        // it did not, having never run at all.
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let hashed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(hashed, emptyHash,
                       "the child must read /dev/null, not the parent's fd 0")
        XCTAssertNotEqual(hashed, sentinelHash,
                          "the child read the sentinel — standardInput is not being set")
    }

    /// `runChecked` without a `stdin:` delegates to `run`, so it must inherit the
    /// null device. Pins the delegation itself: giving `runChecked` its own
    /// `Process` — the one refactor that would silently reopen this — fails here.
    func testRunCheckedWithoutStdinAlsoSeesAnEmptyStdin() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }
        let result = try GitShell.shared.runChecked(["hash-object", "--stdin"], in: nil)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       try expectedHash(of: ""))
    }

    /// The explicit-stdin path still delivers its payload. `runWithStdin` is the
    /// only other `Process` in this file and assigns its own pipe, so between
    /// this test and the two above, both spawn sites are covered.
    func testRunWithStdinStillDeliversItsPayload() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }
        let result = try GitShell.shared.runChecked(
            ["hash-object", "--stdin"], in: nil, stdin: "hello\n")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       try expectedHash(of: "hello\n"))
    }
}
