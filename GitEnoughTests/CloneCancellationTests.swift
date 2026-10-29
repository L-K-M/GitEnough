import XCTest
@testable import GitEnough

final class CloneCancellationTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    override func setUpWithError() throws {
        guard GitShell.shared.isAvailable else { throw XCTSkip("git is not installed") }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughCloneTests-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try GitShell.shared.runChecked(["init", "-b", "main"], in: source)
        _ = try GitShell.shared.runChecked(["config", "user.name", "Clone Test"], in: source)
        _ = try GitShell.shared.runChecked(["config", "user.email", "clone@example.invalid"], in: source)
        _ = try GitShell.shared.runChecked(["config", "commit.gpgsign", "false"], in: source)
        try "preserved content\n".write(to: source.appendingPathComponent("file.txt"),
                                        atomically: true, encoding: .utf8)
        _ = try GitShell.shared.runChecked(["add", "file.txt"], in: source)
        _ = try GitShell.shared.runChecked(["commit", "-m", "Initial"], in: source)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCancelledBeforeLaunchCreatesNoWorkingCopy() throws {
        let target = root.appendingPathComponent("cancelled")
        let cancellation = GitCancellationToken()
        cancellation.cancel()

        XCTAssertThrowsError(try GitClient.clone(source.path, into: target,
                                                cancellation: cancellation)) {
            XCTAssertTrue($0 is GitCancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCancelStopsIgnoringTransportAndDescendantThenAllowsRetry() throws {
        let fixture = try slowTransport()
        let target = root.appendingPathComponent("retry")
        let cancellation = GitCancellationToken()
        let outcome = Outcome()
        let finished = expectation(description: "Clone finished")
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.result = Result {
                try GitClient.clone("ssh://fixture.invalid/source", into: target,
                                    cancellation: cancellation, environmentOverrides: fixture)
            }
            finished.fulfill()
        }
        waitForTransport()

        let start = Date()
        cancellation.cancel()
        wait(for: [finished], timeout: 6)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2,
                          "Cancellation must stop descendants that ignore TERM")
        XCTAssertTrue(outcome.error is GitCancellationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("finished").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".GitEnough-Clone-") })

        try GitClient.clone(source.path, into: target, cancellation: GitCancellationToken())
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8),
                       "preserved content\n")
    }

    func testCancellationNeverDeletesAnExistingDestination() throws {
        let target = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let document = target.appendingPathComponent("user.txt")
        try "Keep me".write(to: document, atomically: true, encoding: .utf8)
        let cancellation = GitCancellationToken()
        cancellation.cancel()

        XCTAssertThrowsError(try GitClient.clone(source.path, into: target, cancellation: cancellation))
        XCTAssertThrowsError(try GitClient.clone(source.path, into: target,
                                                cancellation: GitCancellationToken())) {
            XCTAssertFalse($0 is GitCancellationError)
        }
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "Keep me")
    }

    func testCancelAfterCompletedCloneDoesNotChangeSuccessfulOutcome() throws {
        let target = root.appendingPathComponent("completed")
        let cancellation = GitCancellationToken()
        try GitClient.clone(source.path, into: target, cancellation: cancellation)

        cancellation.cancel()

        XCTAssertFalse(cancellation.isCancelled)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8),
                       "preserved content\n")
    }

    func testCancelAfterGitExitStopsDescendantHoldingOutputPipe() throws {
        let script = root.appendingPathComponent("orphan.sh")
        try """
        #!/bin/sh
        trap '' TERM
        /bin/sleep 3 &
        printf '%s\\n' "$!" > "$GITENOUGH_CLONE_FIXTURE/ready"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        let cancellation = GitCancellationToken()
        let outcome = Outcome()
        let finished = expectation(description: "Git and inherited output pipe finished")
        let directory = try XCTUnwrap(root)
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.result = Result {
                _ = try GitShell.shared.runChecked(
                    ["-c", #"alias.cancel-fixture=!/bin/sh "$GITENOUGH_CLONE_FIXTURE/orphan.sh""#,
                     "cancel-fixture"], in: nil,
                    environmentOverrides: ["GITENOUGH_CLONE_FIXTURE": directory.path],
                    cancellation: cancellation)
            }
            finished.fulfill()
        }
        waitForTransport()
        // The alias and git have exited, but the sleep inherited their output
        // pipe. Cancelling only a still-running root process would now do nothing.
        Thread.sleep(forTimeInterval: 0.15)
        let start = Date()

        cancellation.cancel()
        wait(for: [finished], timeout: 5)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(outcome.error is GitCancellationError)
    }

    func testDestinationCreatedDuringCloneIsNotOverwritten() throws {
        let fixture = try slowTransport()
        let target = root.appendingPathComponent("created-meanwhile")
        let outcome = Outcome()
        let finished = expectation(description: "Clone publication refused")
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.result = Result {
                try GitClient.clone("ssh://fixture.invalid/source", into: target,
                                    cancellation: GitCancellationToken(), environmentOverrides: fixture)
            }
            finished.fulfill()
        }
        waitForTransport()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let document = target.appendingPathComponent("user.txt")
        try "Keep me".write(to: document, atomically: true, encoding: .utf8)

        wait(for: [finished], timeout: 6)

        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "Keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".GitEnough-Clone-") })
    }

    func testLegacyCallerCanCloneIntoAnExistingEmptyDirectory() throws {
        let target = root.appendingPathComponent("legacy-empty")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

        try GitClient.clone(source.path, into: target)

        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8),
                       "preserved content\n")
    }

    func testCancellableCloneIntoExistingEmptyDirectoryPreservesItsIdentity() throws {
        let target = root.appendingPathComponent("existing-empty")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let before = try FileManager.default.attributesOfItem(atPath: target.path)
        let cancellation = GitCancellationToken()

        try GitClient.clone(source.path, into: target, cancellation: cancellation)
        cancellation.cancel()

        XCTAssertFalse(cancellation.isCancelled)
        let after = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.posixPermissions] as? NSNumber, after[.posixPermissions] as? NSNumber)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8),
                       "preserved content\n")
    }

    func testCancellableCloneIntoSymlinkToExistingEmptyDirectoryPreservesLink() throws {
        let real = root.appendingPathComponent("real-empty")
        let target = root.appendingPathComponent("linked-empty")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: real)
        let before = try FileManager.default.attributesOfItem(atPath: real.path)

        try GitClient.clone(source.path, into: target, cancellation: GitCancellationToken())

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), real.path)
        let after = try FileManager.default.attributesOfItem(atPath: real.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("file.txt"), encoding: .utf8),
                       "preserved content\n")
    }

    func testCancellableCloneIntoExistingDirectoryKeepsConcurrentUserDataOnCancel() throws {
        let fixture = try slowTransport()
        let target = root.appendingPathComponent("existing-cancel")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let before = try FileManager.default.attributesOfItem(atPath: target.path)
        let cancellation = GitCancellationToken()
        let outcome = Outcome()
        let finished = expectation(description: "Existing-directory clone cancelled")
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.result = Result {
                try GitClient.clone("ssh://fixture.invalid/source", into: target,
                                    cancellation: cancellation, environmentOverrides: fixture)
            }
            finished.fulfill()
        }
        waitForTransport()
        let document = target.appendingPathComponent("file.txt")
        try "Concurrent user data".write(to: document, atomically: true, encoding: .utf8)

        cancellation.cancel()
        wait(for: [finished], timeout: 6)

        XCTAssertTrue(outcome.error is GitCancellationError)
        XCTAssertEqual((outcome.error as? GitCancellationError)?.retainedDirectory, target)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "Concurrent user data")
        let after = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertTrue(outcome.error?.localizedDescription.contains("existing folder") == true)
    }

    private func slowTransport() throws -> [String: String] {
        let script = root.appendingPathComponent("transport.sh")
        try """
        #!/bin/sh
        trap '' TERM
        /bin/sleep 3 &
        printf '%s\\n' "$!" > "$GITENOUGH_CLONE_FIXTURE/ready"
        wait
        touch "$GITENOUGH_CLONE_FIXTURE/finished"
        exec "$GITENOUGH_CLONE_GIT" upload-pack "$GITENOUGH_CLONE_SOURCE"
        """.write(to: script, atomically: true, encoding: .utf8)
        return [
            "GIT_SSH_COMMAND": #"/bin/sh "$GITENOUGH_CLONE_FIXTURE/transport.sh""#,
            "GIT_SSH_VARIANT": "ssh",
            "GITENOUGH_CLONE_FIXTURE": root.path,
            "GITENOUGH_CLONE_SOURCE": source.path,
            "GITENOUGH_CLONE_GIT": try XCTUnwrap(GitShell.shared.gitURL).path,
        ]
    }

    private func waitForTransport() {
        let ready = expectation(description: "Transport and descendant started")
        let marker = root.appendingPathComponent("ready")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Void, Error>?

        var result: Result<Void, Error>? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }

        var error: Error? {
            if case .failure(let error) = result { return error }
            return nil
        }
    }
}
