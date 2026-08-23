// Subscribes to `$messageGenerationError` and chains Combine operators over it.
// The Linux shim in GitEnough/Platform/ deliberately implements only the sliver
// of Combine the model layer needs — ObservableObject, @Published and a
// fan-out publisher — not per-property publishers or an operator library, so
// this one runs on macOS only. The behaviour it covers is model-level, not UI,
// and is exercised on both platforms through generateCommitMessage()'s other
// tests; only this publisher-based observation is macOS-bound.
#if canImport(Combine)
import Combine
import XCTest
@testable import GitEnough

final class RepoViewModelCommitMessageTests: XCTestCase {

    func testStagedDiffReadFailureIsSurfaced() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughMissing-\(UUID().uuidString)")
        let viewModel = RepoViewModel(repo: Repository(url: missing))
        let errorAppeared = expectation(description: "staged-diff error appears")
        var observedError: String?
        let observation = viewModel.$messageGenerationError
            .compactMap { $0 }
            .first()
            .sink { error in
                observedError = error
                errorAppeared.fulfill()
            }

        viewModel.generateCommitMessage()

        wait(for: [errorAppeared], timeout: 3)
        XCTAssertTrue(observedError?.hasPrefix("Couldn’t read staged changes:") == true)
        XCTAssertFalse(viewModel.isGeneratingMessage)
        withExtendedLifetime(observation) {}
    }
}
#endif
