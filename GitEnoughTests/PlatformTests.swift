import XCTest
@testable import GitEnough

/// The platform seam below the UI: running helper processes, resolving PATH,
/// and the XDG directory rules the Linux build follows.
final class ProcessRunnerTests: XCTestCase {

    // MARK: - Running

    func testCapturesStandardOutputAndExitCode() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hello"])
        XCTAssertEqual(result.standardOutput, "hello\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
    }

    func testFeedsStandardInputToTheChild() throws {
        // The stdin path is what keeps the API key out of the process listing:
        // secret-tool reads it here rather than from an argument.
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), [],
                                           input: Data("sk-secret".utf8))
        XCTAssertEqual(result.standardOutput, "sk-secret")
    }

    func testSurvivesOutputLargerThanAPipeBuffer() throws {
        // 1 MiB is well past the 64 KiB pipe buffer: a reader that waited for
        // exit before draining would deadlock here.
        let payload = String(repeating: "a", count: 1 << 20)
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), [],
                                           input: Data(payload.utf8))
        XCTAssertEqual(result.stdout.count, payload.utf8.count)
    }

    func testReportsFailureExitCodeAndStandardError() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                           ["-c", "echo boom >&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.stderr, "boom")
    }

    func testAChildThatExitsWithoutReadingStdinDoesNotKillUs() throws {
        // Writing past the pipe buffer to a child that is already gone raises
        // SIGPIPE, whose default action kills the whole test process (exit 141)
        // rather than failing the write. Without the ignore ProcessRunner
        // installs, this case takes the app down with it.
        let payload = Data(repeating: 0x41, count: 1 << 20)
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                           ["-c", "exit 0"], input: payload)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testMissingExecutableThrowsRatherThanTrapping() {
        XCTAssertThrowsError(
            try ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), []))
    }

    // MARK: - Timeout

    /// Without a bound, a helper that never exits never returns — which is not
    /// hypothetical: `secret-tool` blocks for the life of the process when the
    /// item it is asked for lives in a locked keyring and the session has no
    /// prompter to unlock it. `sleep` stands in for that here because it is the
    /// same shape and needs no desktop.
    func testATimeoutEndsTheWaitOnAChildThatNeverExits() {
        let start = Date()
        XCTAssertThrowsError(
            try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                  ["-c", "sleep 60"], timeout: 0.5)
        ) { error in
            guard case ProcessRunner.RunError.timedOut(let name, let seconds) = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
            XCTAssertEqual(name, "sh")
            XCTAssertEqual(seconds, 0.5)
        }
        // The point is the promptness, not just the throw: a call that threw
        // after the child finished anyway would pass the check above.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10,
                          "the timeout returned, but only after the child was done")
    }

    func testATimeoutKillsTheChildRatherThanLeavingItRunning() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitenough-timeout-\(UUID().uuidString)")
        // The child writes the marker only if it survives its sleep.
        XCTAssertThrowsError(
            try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                  ["-c", "sleep 2; touch '\(marker.path)'"],
                                  timeout: 0.3))

        Thread.sleep(forTimeInterval: 3)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the timed-out child outlived the call that gave up on it")
    }

    func testAChildThatBeatsItsTimeoutIsUnaffected() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"),
                                           ["quick"], timeout: 30)
        XCTAssertEqual(result.standardOutput, "quick\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    /// A timeout has to bound the whole call, not just the child's lifetime.
    /// `sh` backgrounds a long `sleep` — which inherits the stdout and stderr
    /// pipes — then execs `echo` and is done in milliseconds. The pipes stay
    /// open behind it, so a drain that waits for EOF waits forever.
    ///
    /// Measured on Linux (corelibs-foundation, Swift 6.2.1): all three
    /// grandchild shapes below leave `Process` itself reporting the child as
    /// still running, so the bound that actually fires is the one on the child,
    /// not the one on the drain. The drain bound is depth for the platforms
    /// where `terminationHandler` fires on process death alone. Either way the
    /// contract this pins is the same: with a timeout set, `run` comes back.
    func testATimeoutBoundsTheWholeCallNotJustTheChild() {
        for script in ["sleep 300 & exec echo done",
                       "setsid sleep 300 & exec echo done",
                       "setsid sh -c 'sleep 300' & exec echo done"] {
            let start = Date()
            _ = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                       ["-c", script], timeout: 1)
            XCTAssertLessThan(Date().timeIntervalSince(start), 15,
                              "run() never returned for: \(script)")
        }
    }

    /// `Int(0.5)` is 0, and "did not finish within 0 seconds" reads as a bug in
    /// the timeout rather than a report of it.
    func testSubSecondTimeoutsAreNotReportedAsZero() {
        let message = ProcessRunner.RunError
            .timedOut("secret-tool", seconds: 0.5).errorDescription
        XCTAssertEqual(message, "secret-tool did not finish within 0.5 seconds.")

        let whole = ProcessRunner.RunError
            .timedOut("secret-tool", seconds: 60).errorDescription
        XCTAssertEqual(whole, "secret-tool did not finish within 60 seconds.")
    }

    /// A drain that overruns is not the child overrunning, and saying so with
    /// the caller's timeout would name a bound that never fired: a 60 s keyring
    /// call that gives up on a 2 s drain would claim it waited 60.
    func testADrainOverrunIsNotReportedAsTheChildOverrunning() {
        let message = ProcessRunner.RunError
            .outputNeverEnded("secret-tool", seconds: 2).errorDescription

        XCTAssertEqual(message, "secret-tool finished, but its output never ended — "
                           + "gave up after 2 seconds. Something it started is still "
                           + "holding its pipes open.")
        XCTAssertFalse(message?.contains("did not finish") ?? true,
                       "the child did finish; only its output did not")
    }

    // MARK: - PATH lookup

    func testFindsACommandOnTheSearchPath() {
        XCTAssertEqual(ProcessRunner.which("sh", searchPath: "/nowhere:/bin")?.path,
                       "/bin/sh")
    }

    func testUnknownCommandResolvesToNil() {
        XCTAssertNil(ProcessRunner.which("gitenough-not-a-real-tool",
                                         searchPath: "/bin:/usr/bin"))
    }

    func testAPathIsUsedAsGivenRatherThanSearched() {
        XCTAssertEqual(ProcessRunner.which("/bin/sh", searchPath: "/nowhere")?.path,
                       "/bin/sh")
        XCTAssertNil(ProcessRunner.which("./missing", searchPath: "/bin"))
    }

    func testEmptySearchPathEntriesAreSkipped() {
        // "::" in a PATH means "the current directory" to some shells; treating
        // it as one would make lookups depend on the working directory.
        XCTAssertEqual(ProcessRunner.which("sh", searchPath: "::/bin::")?.path, "/bin/sh")
    }

    func testDefaultSearchPathHasNoDuplicateEntries() {
        let entries = ProcessRunner.defaultSearchPath.split(separator: ":").map(String.init)
        XCTAssertEqual(entries.count, Set(entries).count, ProcessRunner.defaultSearchPath)
    }

    func testARepeatedDirectoryIsLookedUpOnceAndKeepsItsPlace() {
        // A PATH that repeats an entry is ordinary (shell rc files, CI images);
        // the search must not inherit the duplicate.
        XCTAssertEqual(ProcessRunner.which("sh", searchPath: "/bin:/usr/bin:/bin")?.path,
                       "/bin/sh")
    }
}

final class PlatformDirectoryTests: XCTestCase {

    func testXDGVariableWinsWhenAbsolute() {
        let url = Platform.xdgDirectory(variable: "XDG_CONFIG_HOME", fallback: "/.config",
                                        environment: ["XDG_CONFIG_HOME": "/custom/config"],
                                        home: "/home/ada")
        XCTAssertEqual(url.path, "/custom/config")
    }

    func testRelativeOrMissingXDGVariableFallsBackToHome() {
        XCTAssertEqual(
            Platform.xdgDirectory(variable: "XDG_CONFIG_HOME", fallback: "/.config",
                                  environment: [:], home: "/home/ada").path,
            "/home/ada/.config")
        XCTAssertEqual(
            Platform.xdgDirectory(variable: "XDG_CONFIG_HOME", fallback: "/.config",
                                  environment: ["XDG_CONFIG_HOME": "config"],
                                  home: "/home/ada").path,
            "/home/ada/.config")
    }

    func testApplicationSupportDirectoryIsAbsolute() {
        // Foundation's search-path lookup returns nothing on Linux; the XDG
        // fallback must still produce a usable directory rather than "/".
        let url = Platform.applicationSupportDirectory
        XCTAssertTrue(url.path.hasPrefix("/"))
        XCTAssertGreaterThan(url.path.count, 1)
    }
}

final class MergeToolCatalogueTests: XCTestCase {

    func testEveryKnownToolHasADetectionRule() {
        for tool in MergeTool.known {
            XCTAssertFalse(tool.gitName.isEmpty)
            XCTAssertFalse(
                tool.executablePaths.isEmpty && tool.executableNames.isEmpty
                    && tool.bundleIdentifiers.isEmpty,
                "\(tool.name) can never be detected")
        }
    }

    func testGitToolIdentifiersAreUnique() {
        // `installed` is keyed by gitName through Identifiable; a duplicate
        // would make two rows fight over one selection.
        let names = MergeTool.known.map(\.gitName)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testDetectionRejectsAToolThatIsNowhere() {
        let phantom = MergeTool(name: "Phantom", gitName: "phantom",
                                executablePaths: ["/nonexistent/phantom"],
                                executableNames: ["gitenough-not-a-real-tool"])
        XCTAssertFalse(phantom.isInstalled)
    }

    func testDetectionFindsAToolPresentOnDisk() {
        let real = MergeTool(name: "Shell", gitName: "shell",
                             executablePaths: ["/bin/sh"])
        XCTAssertTrue(real.isInstalled)
    }
}
