import Foundation
import XCTest
@testable import GitEnough

/// PullRequestFinder: endpoint building, response parsing, and (via a stubbed
/// URLProtocol) the probe routing and HTTP-status handling of `get()`.
final class PullRequestFinderTests: XCTestCase {

    private let github = ForgeRepo(kind: .github, origin: URL(string: "https://github.com")!,
                                   owner: "acme", repo: "widget")
    private let forgejo = ForgeRepo(kind: .generic, origin: URL(string: "https://code.acme.dev")!,
                                    owner: "acme", repo: "widget")
    private let gitlab = ForgeRepo(kind: .gitlab, origin: URL(string: "https://gitlab.com")!,
                                   owner: "group/sub", repo: "project")

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

    func testGitLabLookupURLEncodesProjectPath() throws {
        // Nested groups: every "/" of the project path becomes %2F.
        let url = try XCTUnwrap(PullRequestFinder.gitLabLookupURL(gitlab, headBranch: "feature/x"))
        XCTAssertEqual(url.absoluteString,
                       "https://gitlab.com/api/v4/projects/group%2Fsub%2Fproject/merge_requests"
                       + "?state=opened&source_branch=feature/x")
    }

    // MARK: - Response parsing

    func testParseGitHubPullRequestsVerifiesHeadRefAndHeadRepo() {
        let json = """
        [{"number": 7, "title": "Add graph", "head": {"ref": "add-graph",
                                                    "repo": {"full_name": "acme/widget"}}},
         {"number": 9, "title": "Different branch", "head": {"ref": "other",
                                                          "repo": {"full_name": "acme/widget"}}},
         {"number": 11, "title": "Stranger's fork", "head": {"ref": "add-graph",
                                                         "repo": {"full_name": "someone/fork"}}}]
        """
        let pulls = PullRequestFinder.parseGitHubPullRequests(Data(json.utf8), forge: github,
                                                              headBranch: "add-graph")
        XCTAssertEqual(pulls.map(\.number), [7])
        XCTAssertEqual(pulls.first?.url.absoluteString,
                       "https://github.com/acme/widget/pull/7")
    }

    func testParseGitHubPullRequestsWithoutHeadIsSkipped() {
        let json = """
        [{"number": 7, "title": "No head object"}]
        """
        XCTAssertEqual(PullRequestFinder.parseGitHubPullRequests(Data(json.utf8), forge: github,
                                                                 headBranch: "add-graph"), [])
    }

    func testParseGitHubPullRequestsEmptyArray() {
        XCTAssertEqual(PullRequestFinder.parseGitHubPullRequests(Data("[]".utf8), forge: github,
                                                                 headBranch: "x"), [])
    }

    func testParseGitHubPullRequestsRejectsErrorBody() {
        // GitHub error responses are JSON objects, not arrays — e.g. private repos.
        let body = "{\"message\": \"Not Found\", \"documentation_url\": \"https://docs.github.com\"}"
        XCTAssertEqual(PullRequestFinder.parseGitHubPullRequests(Data(body.utf8), forge: github,
                                                                 headBranch: "x"), [])
    }

    func testParseForgejoPullRequestsFiltersByHeadRefAndHeadRepo() {
        // Fork PRs appear in the same list; their head ref is just the fork's
        // branch name. Only a head on *this* repo may be opened.
        let json = """
        [
          {"number": 3, "title": "Stranger's fork", "head": {"ref": "topic",
                                                             "repo": {"full_name": "someone/fork"}}},
          {"number": 12, "title": "Topic work", "head": {"ref": "topic",
                                                         "repo": {"full_name": "acme/widget"}}},
          {"number": 13, "title": "Other branch", "head": {"ref": "other",
                                                           "repo": {"full_name": "acme/widget"}}}
        ]
        """
        let pulls = PullRequestFinder.parseForgejoPullRequests(Data(json.utf8), forge: forgejo,
                                                               headBranch: "topic")
        XCTAssertEqual(pulls.map(\.number), [12])
        XCTAssertEqual(pulls.first?.url.absoluteString,
                       "https://code.acme.dev/acme/widget/pulls/12")
    }

    func testParseForgejoPullRequestsHeadRepoNameCaseInsensitive() {
        let json = """
        [{"number": 12, "title": "Topic work", "head": {"ref": "topic",
                                                       "repo": {"full_name": "Acme/Widget"}}}]
        """
        let pulls = PullRequestFinder.parseForgejoPullRequests(Data(json.utf8), forge: forgejo,
                                                               headBranch: "topic")
        XCTAssertEqual(pulls.map(\.number), [12])
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

    func testParseGitLabMergeRequestsUsesIIDAndSourceBranch() {
        let json = """
        [{"id": 999999, "iid": 7, "title": "Add graph", "source_branch": "add-graph",
          "source_project_id": 42, "target_project_id": 42},
         {"id": 888888, "iid": 8, "title": "Other", "source_branch": "other",
          "source_project_id": 42, "target_project_id": 42}]
        """
        let pulls = PullRequestFinder.parseGitLabMergeRequests(Data(json.utf8), forge: gitlab,
                                                               headBranch: "add-graph")
        XCTAssertEqual(pulls.map(\.number), [7]) // iid, not id
        XCTAssertEqual(pulls.first?.url.absoluteString,
                       "https://gitlab.com/group/sub/project/-/merge_requests/7")
    }

    func testParseGitLabMergeRequestsSkipsForkSources() {
        // MRs from forks target this project and share source-branch names; a
        // differing source_project_id marks them as strangers'.
        let json = """
        [{"iid": 5, "title": "Stranger's fork", "source_branch": "topic",
          "source_project_id": 77, "target_project_id": 42},
         {"iid": 6, "title": "Topic work", "source_branch": "topic",
          "source_project_id": 42, "target_project_id": 42}]
        """
        let pulls = PullRequestFinder.parseGitLabMergeRequests(Data(json.utf8), forge: gitlab,
                                                               headBranch: "topic")
        XCTAssertEqual(pulls.map(\.number), [6])
    }

    func testParseGitLabMergeRequestsLenientWhenProjectIdsAbsent() {
        let json = """
        [{"iid": 7, "title": "Add graph", "source_branch": "add-graph"}]
        """
        let pulls = PullRequestFinder.parseGitLabMergeRequests(Data(json.utf8), forge: gitlab,
                                                               headBranch: "add-graph")
        XCTAssertEqual(pulls.map(\.number), [7])
    }

    func testParseGitLabMergeRequestsRejectsErrorBody() {
        let body = "{\"message\": \"404 Project Not Found\"}"
        XCTAssertEqual(PullRequestFinder.parseGitLabMergeRequests(Data(body.utf8), forge: gitlab,
                                                                  headBranch: "x"), [])
    }

    // MARK: - Probe routing via a stubbed URLProtocol

    private func stubbedFinder() -> PullRequestFinder {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PullRequestFinder(session: URLSession(configuration: configuration))
    }

    func testGitLabKindHitsGitLabEndpoint() async {
        let mr = "[{\"iid\": 7, \"title\": \"Add graph\", \"source_branch\": \"add-graph\"}]"
        var hitGitLab = false
        MockURLProtocol.handler = { request in
            hitGitLab = request.url!.absoluteString.contains("/api/v4/")
            return (MockURLProtocol.ok(request.url!), Data(mr.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let pull = await stubbedFinder().findOpenPullRequest(for: gitlab, headBranch: "add-graph")
        XCTAssertEqual(pull?.number, 7)
        XCTAssertTrue(hitGitLab)
    }

    func testGenericHostTriesForgejoThenGitLab() async {
        let mr = "[{\"iid\": 5, \"title\": \"Topic\", \"source_branch\": \"topic\"}]"
        let probed: NSMutableArray = []
        MockURLProtocol.handler = { request in
            let url = request.url!
            if url.absoluteString.contains("/api/v1/") {
                probed.add("forgejo")
                return (MockURLProtocol.notFound(url), Data("{}".utf8))
            }
            probed.add("gitlab")
            return (MockURLProtocol.ok(url), Data(mr.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let generic = ForgeRepo(kind: .generic, origin: URL(string: "https://git.acme.dev")!,
                                owner: "acme", repo: "widget")
        let pull = await stubbedFinder().findOpenPullRequest(for: generic, headBranch: "topic")
        XCTAssertEqual(pull?.number, 5)
        // The GitLab hit flips the URL shape to merge_requests.
        XCTAssertEqual(pull?.url.absoluteString,
                       "https://git.acme.dev/acme/widget/-/merge_requests/5")
        XCTAssertEqual(probed as? [String], ["forgejo", "gitlab"])
    }

    func testNon200YieldsNothing() async {
        MockURLProtocol.handler = { request in
            (MockURLProtocol.notFound(request.url!), Data("{}".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let generic = ForgeRepo(kind: .generic, origin: URL(string: "https://git.acme.dev")!,
                                owner: "acme", repo: "widget")
        let pull = await stubbedFinder().findOpenPullRequest(for: generic, headBranch: "topic")
        XCTAssertNil(pull)
    }
}

/// Minimal URLProtocol stub: answers from `handler`, records nothing (the tests
/// assert via the handler). Test-only; lives here because the app target must
/// stay free of test scaffolding.
final class MockURLProtocol: URLProtocol {

    /// Set before each test; returns (response, body) for a request.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func ok(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    static func notFound(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
