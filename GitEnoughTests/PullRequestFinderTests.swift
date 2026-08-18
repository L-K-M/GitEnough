import XCTest
@testable import GitEnough

/// PullRequestFinder: the pure endpoint-building and response-parsing parts.
final class PullRequestFinderTests: XCTestCase {

    private let github = ForgeRepo(kind: .github, origin: URL(string: "https://github.com")!,
                                   owner: "acme", repo: "widget")
    private let forgejo = ForgeRepo(kind: .generic, origin: URL(string: "https://code.acme.dev")!,
                                    owner: "acme", repo: "widget")

    // MARK: - Endpoints

    func testGitHubLookupURL() throws {
        let url = try XCTUnwrap(PullRequestFinder.gitHubLookupURL(github, headBranch: "feature/x"))
        XCTAssertEqual(url.absoluteString,
                       "https://api.github.com/repos/acme/widget/pulls?state=open&head=acme:feature/x")
    }

    func testGitHubLookupURLEncodesBranch() throws {
        let url = try XCTUnwrap(PullRequestFinder.gitHubLookupURL(github, headBranch: "feature x"))
        XCTAssertTrue(url.absoluteString.hasSuffix("head=acme:feature%20x"))
    }

    func testForgejoLookupURL() throws {
        let url = try XCTUnwrap(PullRequestFinder.forgejoLookupURL(forgejo))
        XCTAssertEqual(url.absoluteString,
                       "https://code.acme.dev/api/v1/repos/acme/widget/pulls?state=open&limit=50")
    }

    // MARK: - Response parsing

    func testParseGitHubPullRequests() {
        let json = """
        [{"number": 7, "title": "Add graph", "html_url": "https://github.com/acme/widget/pull/7"}]
        """
        let pulls = PullRequestFinder.parseGitHubPullRequests(Data(json.utf8), forge: github)
        XCTAssertEqual(pulls, [PullRequest(number: 7, title: "Add graph",
                                           url: URL(string: "https://github.com/acme/widget/pull/7")!)])
    }

    func testParseGitHubPullRequestsEmptyArray() {
        XCTAssertEqual(PullRequestFinder.parseGitHubPullRequests(Data("[]".utf8), forge: github), [])
    }

    func testParseGitHubPullRequestsRejectsErrorBody() {
        // GitHub error responses are JSON objects, not arrays — e.g. private repos.
        let body = "{\"message\": \"Not Found\", \"documentation_url\": \"https://docs.github.com\"}"
        XCTAssertEqual(PullRequestFinder.parseGitHubPullRequests(Data(body.utf8), forge: github), [])
    }

    func testParseForgejoPullRequestsFiltersByHeadRef() {
        let json = """
        [
          {"number": 3, "title": "Other branch", "head": {"ref": "other"}},
          {"number": 12, "title": "Topic work", "head": {"ref": "topic"}}
        ]
        """
        let pulls = PullRequestFinder.parseForgejoPullRequests(Data(json.utf8), forge: forgejo,
                                                               headBranch: "topic")
        XCTAssertEqual(pulls.map(\.number), [12])
        XCTAssertEqual(pulls.first?.url.absoluteString,
                       "https://code.acme.dev/acme/widget/pulls/12")
    }

    func testParseForgejoPullRequestsWithoutHeadIsSkipped() {
        let json = """
        [{"number": 4, "title": "No head object"}]
        """
        XCTAssertEqual(PullRequestFinder.parseForgejoPullRequests(Data(json.utf8), forge: forgejo,
                                                                  headBranch: "main"), [])
    }

    func testParseForgejoPullRequestsRejectsErrorBody() {
        let body = "{\"message\": \"access denied\"}"
        XCTAssertEqual(PullRequestFinder.parseForgejoPullRequests(Data(body.utf8), forge: forgejo,
                                                                  headBranch: "main"), [])
    }
}
