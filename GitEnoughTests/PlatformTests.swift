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
