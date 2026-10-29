import XCTest
@testable import GitEnough

/// Intent can outlive the snapshot that supplied it: another window can change
/// the stash, and typing can continue while a commit waits for a hook or queue.
final class RepoViewModelIntentTests: XCTestCase {
    private var directory: URL!
    private var client: GitClient!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        guard GitShell.shared.isAvailable else { throw XCTSkip("git is not installed") }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughIntentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        client = GitClient(worktree: directory)
        _ = try git(["init", "-b", "main"])
        _ = try git(["config", "user.name", "Intent Test"])
        _ = try git(["config", "user.email", "intent@example.invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try write("base\n")
        try client.stage(paths: ["payload.txt"])
        try client.commit(message: "Initial")
        suite = "GitEnough.IntentTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suite)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testDropTargetsCapturedStashAfterIndicesShiftWithDuplicateMessages() throws {
        let entries = try threeStashes()
        let target = entries[1]
        let model = makeViewModel()
        try client.stashDrop(index: 0)

        model.stashDrop(target)
        waitForOperations(on: model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try client.stashList().count, 1)
        XCTAssertEqual(try git(["show", "stash@{0}:payload.txt"]), "oldest\n")
    }

    func testPopTargetsCapturedStashAfterIndicesShiftWithDuplicateMessages() throws {
        let entries = try threeStashes()
        let target = entries[1]
        let model = makeViewModel()
        try client.stashDrop(index: 0)

        model.stashApply(target, pop: true)
        waitForOperations(on: model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("payload.txt"),
                                  encoding: .utf8), "middle\n")
        XCTAssertEqual(try client.stashList().count, 1)
        XCTAssertEqual(try git(["show", "stash@{0}:payload.txt"]), "oldest\n")
    }

    func testRemovedStashCannotDeleteTheEntryThatTookItsIndex() throws {
        let entries = try threeStashes()
        let target = entries[1]
        let model = makeViewModel()
        try client.stashDrop(index: target.index)
        let before = try git(["stash", "list", "--format=%H"])

        model.stashDrop(target)
        waitForOperations(on: model)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try git(["stash", "list", "--format=%H"]), before)
    }

    func testRemovedStashCannotApplyTheEntryThatTookItsIndex() throws {
        let entries = try threeStashes()
        let target = entries[1]
        let model = makeViewModel()
        try client.stashDrop(index: target.index)
        let before = try git(["stash", "list", "--format=%H"])

        model.stashApply(target, pop: true)
        waitForOperations(on: model)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try git(["stash", "list", "--format=%H"]), before)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("payload.txt"),
                                  encoding: .utf8), "base\n")
    }

    func testNewDraftSurvivesSuccessfulCommitWhileOperationIsQueued() throws {
        try write("committed change\n")
        try client.stage(paths: ["payload.txt"])
        let model = makeViewModel()
        let releaseQueue = DispatchSemaphore(value: 0)
        model.queue.async { releaseQueue.wait() }
        model.draftCommitMessage = "Commit this message"

        model.commit()
        XCTAssertTrue(model.isBusy)
        model.draftCommitMessage = "Keep the next draft"
        releaseQueue.signal()
        waitForOperations(on: model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try client.commitDetail("HEAD")?.subject, "Commit this message")
        XCTAssertEqual(model.draftCommitMessage, "Keep the next draft")
        let restored = RepoViewModel(repo: Repository(url: directory), defaults: defaults)
        XCTAssertEqual(restored.draftCommitMessage, "Keep the next draft")
    }

    func testUneditedDraftClearsAfterSuccessfulCommit() throws {
        try write("committed change\n")
        try client.stage(paths: ["payload.txt"])
        let model = makeViewModel()
        model.draftCommitMessage = "Commit this message"

        model.commit()
        waitForOperations(on: model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try client.commitDetail("HEAD")?.subject, "Commit this message")
        XCTAssertEqual(model.draftCommitMessage, "")
        let restored = RepoViewModel(repo: Repository(url: directory), defaults: defaults)
        XCTAssertEqual(restored.draftCommitMessage, "")
    }

    private func threeStashes() throws -> [StashEntry] {
        for content in ["oldest", "middle", "newest"] {
            try write(content + "\n")
            try client.stashPush(message: "Same message", includeUntracked: false)
        }
        return try client.stashList()
    }

    private func makeViewModel() -> RepoViewModel {
        let model = RepoViewModel(repo: Repository(url: directory), defaults: defaults)
        model.refresh()
        waitForOperations(on: model)
        return model
    }

    private func waitForOperations(on model: RepoViewModel) {
        let finished = expectation(description: "Repository operation applied")
        model.queue.async { DispatchQueue.main.async { finished.fulfill() } }
        wait(for: [finished], timeout: 10)
    }

    private func write(_ content: String) throws {
        try content.write(to: directory.appendingPathComponent("payload.txt"),
                          atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: [String]) throws -> String {
        try GitShell.shared.runChecked(arguments, in: directory).stdout
    }
}
