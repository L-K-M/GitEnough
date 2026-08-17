import XCTest
@testable import GitEnough

/// Tests for the LLM commit-message plumbing that doesn't need the network:
/// message cleanup, prompt assembly, and endpoint URL joining.
final class CommitMessageGeneratorTests: XCTestCase {

    func testCleanMessageStripsCodeFence() {
        let raw = "```\nfeat: add the thing\n\n- does x\n```"
        XCTAssertEqual(CommitMessageGenerator.cleanGeneratedMessage(raw),
                       "feat: add the thing\n\n- does x")
    }

    func testCleanMessageStripsLanguageTaggedFence() {
        let raw = "```text\nfix: repair the thing\n```"
        XCTAssertEqual(CommitMessageGenerator.cleanGeneratedMessage(raw),
                       "fix: repair the thing")
    }

    func testCleanMessageStripsLabelAndQuotes() {
        XCTAssertEqual(CommitMessageGenerator.cleanGeneratedMessage("Commit message: \"fix: x\""),
                       "fix: x")
    }

    func testCleanMessagePassesThroughPlainText() {
        XCTAssertEqual(CommitMessageGenerator.cleanGeneratedMessage("fix: plain"),
                       "fix: plain")
    }

    func testPromptContainsStatDiffAndBranch() {
        let prompt = CommitMessageGenerator.prompt(diffStat: " 1 file changed",
                                                   diff: "diff --git …",
                                                   branch: "main")
        XCTAssertTrue(prompt.contains("1 file changed"))
        XCTAssertTrue(prompt.contains("diff --git …"))
        XCTAssertTrue(prompt.contains("main"))
        XCTAssertTrue(prompt.contains("```diff"))
    }

    func testPromptTruncatesHugeDiffs() {
        let huge = String(repeating: "x", count: CommitMessageGenerator.maxDiffCharacters + 100)
        let prompt = CommitMessageGenerator.prompt(diffStat: "", diff: huge, branch: nil)
        XCTAssertTrue(prompt.contains("[diff truncated]"))
        XCTAssertLessThan(prompt.count, CommitMessageGenerator.maxDiffCharacters + 500)
    }

    func testChatCompletionsURLJoining() {
        var config = LLMConfiguration(provider: .zai,
                                      baseURL: "https://api.z.ai/api/coding/paas/v4/",
                                      model: "glm-4.6")
        XCTAssertEqual(config.chatCompletionsURL?.absoluteString,
                       "https://api.z.ai/api/coding/paas/v4/chat/completions")

        config.baseURL = "  "
        XCTAssertNil(config.chatCompletionsURL)
    }
}
