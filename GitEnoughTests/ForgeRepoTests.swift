import XCTest
@testable import GitEnough

/// ForgeRepo: remote-URL parsing and the per-forge website URL shapes.
final class ForgeRepoTests: XCTestCase {

    // MARK: - Parsing

    func testParseHTTPS() throws {
        let forge = try XCTUnwrap(ForgeRepo.parse(remoteURL: "https://github.com/L-K-M/GitEnough.git"))
        XCTAssertEqual(forge.kind, .github)
        XCTAssertEqual(forge.origin.absoluteString, "https://github.com")
        XCTAssertEqual(forge.owner, "L-K-M")
        XCTAssertEqual(forge.repo, "GitEnough")
    }

    func testParseSCPFormMatchesHTTPS() throws {
        let https = try XCTUnwrap(ForgeRepo.parse(remoteURL: "https://github.com/L-K-M/GitEnough.git"))
        let scp = try XCTUnwrap(ForgeRepo.parse(remoteURL: "git@github.com:L-K-M/GitEnough.git"))
        XCTAssertEqual(https, scp)
    }

    func testParseSSHWithUserAndPortDropsPort() throws {
        let forge = try XCTUnwrap(ForgeRepo.parse(remoteURL: "ssh://git@forge.example:2222/acme/widget.git"))
        XCTAssertEqual(forge.kind, .generic)
        XCTAssertEqual(forge.origin.absoluteString, "https://forge.example")
        XCTAssertEqual(forge.owner, "acme")
        XCTAssertEqual(forge.repo, "widget")
    }

    func testParseHTTPWithPortKeepsPort() throws {
        let forge = try XCTUnwrap(ForgeRepo.parse(remoteURL: "http://gitea.local:3000/acme/widget"))
        XCTAssertEqual(forge.kind, .generic)
        XCTAssertEqual(forge.origin.absoluteString, "http://gitea.local:3000")
    }

    func testParseHTTPSWithUsername() throws {
        let forge = try XCTUnwrap(ForgeRepo.parse(remoteURL: "https://deploy@github.com/acme/web.git"))
        XCTAssertEqual(forge.kind, .github)
        XCTAssertEqual(forge.owner, "acme")
        XCTAssertEqual(forge.repo, "web")
    }

    func testParseGitLabNestedGroups() throws {
        let forge = try XCTUnwrap(ForgeRepo.parse(remoteURL: "https://gitlab.com/group/sub/project.git"))
        XCTAssertEqual(forge.kind, .gitlab)
        XCTAssertEqual(forge.owner, "group/sub")
        XCTAssertEqual(forge.repo, "project")
    }

    func testParseTrailingSlash() throws {
        let forge = try XCTUnwrap(ForgeRepo.parse(remoteURL: "https://github.com/acme/web/"))
        XCTAssertEqual(forge.repo, "web")
    }

    func testParseUppercaseHost() throws {
        // Hostnames are case-insensitive; remotes copied by hand carry mixed case.
        let https = try XCTUnwrap(ForgeRepo.parse(remoteURL: "https://GitHub.COM/acme/web.git"))
        XCTAssertEqual(https.kind, .github)
        XCTAssertEqual(https.origin.absoluteString, "https://github.com")
        XCTAssertEqual(https.repo, "web")
        let scp = try XCTUnwrap(ForgeRepo.parse(remoteURL: "git@GitLab.com:group/sub/project.git"))
        XCTAssertEqual(scp.kind, .gitlab)
        XCTAssertEqual(scp.origin.absoluteString, "https://gitlab.com")
    }

    func testParseStripsUppercaseGitSuffix() throws {
        let forge = try XCTUnwrap(ForgeRepo.parse(remoteURL: "https://github.com/acme/web.GIT"))
        XCTAssertEqual(forge.repo, "web")
    }

    func testParseRejectsNonForges() {
        for url in ["", "/local/path", "relative/path", "file:///srv/git/x.git",
                    "ftp://host/owner/repo.git", "https://github.com",
                    "https://github.com/justrepo", "git@github.com:.git"] {
            XCTAssertNil(ForgeRepo.parse(remoteURL: url), "should not parse: \(url)")
        }
    }

    // MARK: - URL shapes

    private func github() -> ForgeRepo {
        ForgeRepo(kind: .github, origin: URL(string: "https://github.com")!,
                  owner: "acme", repo: "widget")
    }

    func testPullRequestURLs() {
        XCTAssertEqual(github().pullRequestURL(number: 7).absoluteString,
                       "https://github.com/acme/widget/pull/7")
        XCTAssertEqual(github().assumingForgejo().pullRequestURL(number: 7).absoluteString,
                       "https://github.com/acme/widget/pulls/7")
        XCTAssertEqual(
            ForgeRepo(kind: .gitlab, origin: URL(string: "https://gitlab.com")!,
                      owner: "group/sub", repo: "project")
                .pullRequestURL(number: 5).absoluteString,
            "https://gitlab.com/group/sub/project/-/merge_requests/5")
        // A self-hosted GitLab discovered via its API takes MR shapes too.
        XCTAssertEqual(
            ForgeRepo(kind: .generic, origin: URL(string: "https://git.acme.dev")!,
                      owner: "acme", repo: "widget")
                .assumingGitLab().pullRequestURL(number: 5).absoluteString,
            "https://git.acme.dev/acme/widget/-/merge_requests/5")
        XCTAssertEqual(
            ForgeRepo(kind: .generic, origin: URL(string: "https://git.acme.dev")!,
                      owner: "acme", repo: "widget")
                .assumingGitLab().newPullRequestURL(base: "main", head: "topic").absoluteString,
            "https://git.acme.dev/acme/widget/-/merge_requests/new"
            + "?merge_request%5Bsource_branch%5D=topic"
            + "&merge_request%5Btarget_branch%5D=main")
        // Unknown hosts get GitHub-style paths as the best guess.
        XCTAssertEqual(
            ForgeRepo(kind: .generic, origin: URL(string: "https://host.example")!,
                      owner: "acme", repo: "widget")
                .pullRequestURL(number: 3).absoluteString,
            "https://host.example/acme/widget/pull/3")
    }

    func testNewPullRequestURLGitHubAndForgejo() {
        XCTAssertEqual(
            github().newPullRequestURL(base: "main", head: "feature/x").absoluteString,
            "https://github.com/acme/widget/compare/main...feature/x?expand=1")
        XCTAssertEqual(
            github().assumingForgejo().newPullRequestURL(base: "main", head: "feature/x").absoluteString,
            "https://github.com/acme/widget/compare/main...feature/x?expand=1")
    }

    func testNewPullRequestURLEncodesSpaces() {
        XCTAssertEqual(
            github().newPullRequestURL(base: "main", head: "feature x").absoluteString,
            "https://github.com/acme/widget/compare/main...feature%20x?expand=1")
    }

    func testNewPullRequestURLGitLab() {
        let gitlab = ForgeRepo(kind: .gitlab, origin: URL(string: "https://gitlab.com")!,
                               owner: "group/sub", repo: "project")
        XCTAssertEqual(
            gitlab.newPullRequestURL(base: "main", head: "topic 2").absoluteString,
            "https://gitlab.com/group/sub/project/-/merge_requests/new"
            + "?merge_request%5Bsource_branch%5D=topic%202"
            + "&merge_request%5Btarget_branch%5D=main")
    }

    func testWebURL() {
        XCTAssertEqual(github().webURL.absoluteString, "https://github.com/acme/widget")
    }
}
