import XCTest
@testable import GitEnough

final class CommitMessageReplacementTests: XCTestCase {
    func testInverseRestoresOriginalAndRejectsANewerDraft() {
        let original = "My original draft 🐾\n\nWith its explanation."
        let generated = "fix: Keep the generated message"
        let replacement = CommitMessageReplacement(previousMessage: original, message: generated)

        XCTAssertEqual(replacement.replacing(original), generated)
        XCTAssertEqual(replacement.inverse.replacing(generated), original)
        XCTAssertEqual(replacement.inverse.inverse, replacement)
        XCTAssertNil(replacement.replacing("A newer manual draft"))
        XCTAssertNil(replacement.inverse.replacing("A newer shared draft"))
    }
}

#if canImport(Combine)
import Combine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RepoViewModelGeneratedReplacementTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        guard GitShell.shared.isAvailable else { throw XCTSkip("git is not installed") }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughGeneratedUndo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try GitShell.shared.runChecked(["init", "-b", "main"], in: directory)
        try "fixture staged content\n".write(to: directory.appendingPathComponent("payload.txt"),
                                            atomically: true, encoding: .utf8)
        try GitClient(worktree: directory).stage(paths: ["payload.txt"])
        suite = "GitEnough.GeneratedUndoTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suite)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        GeneratedMessageProtocol.handler = nil
    }

    func testAcceptedGenerationDeliversOneUndoableReplacement() throws {
        let model = RepoViewModel(repo: Repository(url: directory), defaults: defaults)
        let original = "Keep my original draft 🐾"
        model.draftCommitMessage = original
        let generated = "fix: Use the fixture message"
        let delivered = expectation(description: "Generated text delivered")
        let observation = model.$draftCommitMessage.filter { $0 == generated }.first()
            .sink { _ in delivered.fulfill() }
        let generator = fixtureGenerator(message: generated)
        var replacements: [CommitMessageReplacement] = []

        model.generateCommitMessage(using: generator) { replacements.append($0) }
        wait(for: [delivered], timeout: 5)

        XCTAssertEqual(model.draftCommitMessage, generated)
        XCTAssertEqual(replacements,
                       [CommitMessageReplacement(previousMessage: original, message: generated)],
                       "Replacing a draft must also deliver its inverse to the initiating editor")
        withExtendedLifetime(observation) {}
    }

    func testTypingDuringASlowGenerationKeepsTheNewerDraft() throws {
        try assertPendingGenerationPreservesDraft { model in
            model.draftCommitMessage = "The newer manual draft"
            return "The newer manual draft"
        }
    }

    func testBeginningMarkedInputCancelsGenerationBeforeTheSharedDraftChanges() throws {
        try assertPendingGenerationPreservesDraft { model in
            model.beginCommitMessageEditing()
            return "Original draft"
        }
    }

    func testAnAcceptedCallbackCannotLoseANewerDraft() throws {
        let model = RepoViewModel(repo: Repository(url: directory), defaults: defaults)
        model.draftCommitMessage = "Original draft"
        let delivered = expectation(description: "Accepted replacement callback")
        model.generateCommitMessage(using: fixtureGenerator(message: "Generated")) { _ in
            model.draftCommitMessage = "A newer callback draft"
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(model.draftCommitMessage, "A newer callback draft")
    }

    private func assertPendingGenerationPreservesDraft(edit: (RepoViewModel) -> String) throws {
        let model = RepoViewModel(repo: Repository(url: directory), defaults: defaults)
        model.draftCommitMessage = "Original draft"
        let requested = expectation(description: "Fixture request started")
        let verified = expectation(description: "Returned message checked against staged content")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let observation = model.$activityEntries.filter { entries in
            entries.count == 3 && entries.allSatisfy { !$0.isRunning }
        }.first().sink { _ in verified.fulfill() }
        let generator = fixtureGenerator(message: "Must not replace newer typing") {
            requested.fulfill()
            release.wait()
        }
        var replacements: [CommitMessageReplacement] = []
        model.generateCommitMessage(using: generator) { replacements.append($0) }
        wait(for: [requested], timeout: 5)

        let expectedDraft = edit(model)
        release.signal()
        wait(for: [verified], timeout: 5)
        let drained = expectation(description: "Final verification applied")
        model.queue.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)

        XCTAssertEqual(model.draftCommitMessage, expectedDraft)
        XCTAssertTrue(replacements.isEmpty)
        XCTAssertFalse(model.isGeneratingMessage)
        withExtendedLifetime(observation) {}
    }

    private func fixtureGenerator(message: String, beforeResponse: (() -> Void)? = nil) -> CommitMessageGenerator {
        GeneratedMessageProtocol.handler = { stub in
            beforeResponse?()
            let data = try JSONSerialization.data(withJSONObject:
                ["choices": [["message": ["content": message]]]])
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(stub.request.url),
                                                        statusCode: 200, httpVersion: nil, headerFields: nil))
            stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            stub.client?.urlProtocol(stub, didLoad: data)
            stub.client?.urlProtocolDidFinishLoading(stub)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeneratedMessageProtocol.self]
        return CommitMessageGenerator(
            configuration: LLMConfiguration(provider: .custom, baseURL: "https://fixture.invalid/v1", model: "fixture"),
            apiKeyProvider: { "fixture-key" }, session: URLSession(configuration: configuration))
    }
}

private final class GeneratedMessageProtocol: URLProtocol {
    static var handler: ((GeneratedMessageProtocol) throws -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { try Self.handler?(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
#endif
