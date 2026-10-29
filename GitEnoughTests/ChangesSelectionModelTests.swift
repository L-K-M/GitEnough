#if canImport(AppKit) && !SWIFT_PACKAGE
import XCTest
@testable import GitEnough

final class ChangesSelectionModelTests: XCTestCase {
    private var repoURL: URL!

    override func setUpWithError() throws {
        guard GitShell.shared.isAvailable else { throw XCTSkip("git is not installed") }
        repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughSelection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        _ = try GitShell.shared.runChecked(["init", "-b", "main"], in: repoURL)
        try "first window contents\n".write(to: repoURL.appendingPathComponent("first.txt"),
                                            atomically: true, encoding: .utf8)
        try "second window contents\n".write(to: repoURL.appendingPathComponent("second.txt"),
                                             atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let repoURL { try FileManager.default.removeItem(at: repoURL) }
    }

    @MainActor
    func testWindowsKeepIndependentDiffsOnTheSameRepositoryQueue() async {
        let viewModel = RepoViewModel(repo: Repository(url: repoURL))
        let first = ChangesSelectionModel()
        let second = ChangesSelectionModel()
        first.select(selection("first.txt"), in: viewModel)
        second.select(selection("second.txt"), in: viewModel)
        await drain(viewModel)

        XCTAssertTrue(first.diff.contains("first window contents"))
        XCTAssertFalse(first.diff.contains("second window contents"))
        XCTAssertTrue(second.diff.contains("second window contents"))
        XCTAssertFalse(first.isLoading)
        XCTAssertFalse(second.isLoading)
    }

    @MainActor
    func testClearingSelectionRejectsAnOutstandingRead() async {
        let viewModel = RepoViewModel(repo: Repository(url: repoURL))
        let model = ChangesSelectionModel()
        model.select(selection("first.txt"), in: viewModel)
        model.select(nil, in: viewModel)
        await drain(viewModel)

        XCTAssertEqual(model.diff, "")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testRapidSelectionSkipsObsoleteQueuedReads() async {
        let viewModel = RepoViewModel(repo: Repository(url: repoURL))
        let blocked = expectation(description: "Repository queue held by earlier work")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        viewModel.queue.async {
            blocked.fulfill()
            release.wait()
        }
        await fulfillment(of: [blocked], timeout: 10)

        let model = ChangesSelectionModel()
        model.select(selection("first.txt"), in: viewModel)
        model.select(selection("second.txt"), in: viewModel)
        release.signal()
        await drain(viewModel)

        XCTAssertTrue(model.diff.contains("second window contents"))
        XCTAssertFalse(viewModel.activityLog.entries.contains {
            $0.arguments?.contains("first.txt") == true
        }, "A superseded selection should not delay new work with an unused git read")
    }

    @MainActor
    func testAReadFailureDoesNotPretendTheFileHasNoChanges() async {
        let missingRepository = repoURL.appendingPathComponent("missing-repository")
        let viewModel = RepoViewModel(repo: Repository(url: missingRepository))
        let model = ChangesSelectionModel()
        model.select(selection("first.txt"), in: viewModel)
        await drain(viewModel)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.diff, "")
        XCTAssertFalse(model.isLoading)
    }

    private func selection(_ path: String) -> ChangeSelection {
        ChangeSelection(file: FileChange(path: path, originalPath: nil,
                                         stagedStatus: nil, unstagedStatus: .untracked),
                        isStaged: false)
    }

    @MainActor
    private func drain(_ viewModel: RepoViewModel) async {
        let drained = expectation(description: "Repository reads applied on main")
        viewModel.queue.async {
            DispatchQueue.main.async { drained.fulfill() }
        }
        await fulfillment(of: [drained], timeout: 10)
    }
}
#endif
