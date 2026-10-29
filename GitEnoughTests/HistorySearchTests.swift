import XCTest
@testable import GitEnough

final class HistorySearchTests: XCTestCase {
    private func commit(_ hash: String = "abcdef123456", subject: String = "Unrelated",
                        author: String = "Ada Lovelace", email: String = "ada@example.com",
                        decorations: [RefDecoration] = []) -> Commit {
        Commit(hash: hash, parents: [], author: author, email: email,
               date: nil, subject: subject, decorations: decorations)
    }

    func testEmptyOrWhitespaceQueryKeepsAllCommits() {
        let commits = [commit("a1"), commit("b2")]
        for query in ["", " \n\t "] {
            XCTAssertEqual(HistorySearch.filter(commits, query: query), commits)
        }
    }

    func testSubjectMatchingIgnoresCaseAndTrimsQuery() {
        let commits = [commit(subject: "Fix the layout engine")]
        XCTAssertEqual(HistorySearch.filter(commits, query: " FIX "), commits)
        XCTAssertTrue(HistorySearch.filter(commits, query: "printer").isEmpty)
    }

    func testMatchesAuthorName() {
        let commits = [commit(author: "Grace Hopper", email: "grace@navy.mil")]
        XCTAssertEqual(HistorySearch.filter(commits, query: "HOPPER"), commits)
        XCTAssertTrue(HistorySearch.filter(commits, query: "Ada").isEmpty)
    }

    func testMatchesAuthorEmail() {
        let commits = [commit(author: "Grace Hopper", email: "grace@navy.mil")]
        XCTAssertEqual(HistorySearch.filter(commits, query: "NAVY.MIL"), commits)
        XCTAssertTrue(HistorySearch.filter(commits, query: "example.com").isEmpty)
    }

    func testHashMatchingAcceptsOnlyPrefixes() {
        let commits = [commit()]
        XCTAssertEqual(HistorySearch.filter(commits, query: "ABCDEF1"), commits)
        XCTAssertEqual(HistorySearch.filter(commits, query: "abcdef123456"), commits)
        XCTAssertTrue(HistorySearch.filter(commits, query: "bcdef1").isEmpty)
        XCTAssertTrue(HistorySearch.filter(commits, query: "abcdef9").isEmpty)
        XCTAssertTrue(HistorySearch.filter(commits, query: "abcdef1234567").isEmpty)
    }

    func testMatchesLocalRemoteAndTagNames() {
        let commits = [commit(decorations: [
            RefDecoration(kind: .localBranch, name: "topic/interface"),
            RefDecoration(kind: .remoteBranch, name: "upstream/feature"),
            RefDecoration(kind: .tag, name: "v1.2.0")
        ])]
        for query in ["interface", "UPSTREAM", "v1.2"] {
            XCTAssertEqual(HistorySearch.filter(commits, query: query), commits)
        }
        XCTAssertTrue(HistorySearch.filter(commits, query: "v2.0").isEmpty)
    }

    func testFilterPreservesOrderAndReturnsOnlyMatches() {
        let commits = [
            commit("a1", subject: "Add widget"),
            commit("b2", subject: "Remove gadget"),
            commit("c3", subject: "Refactor widget tests")
        ]
        XCTAssertEqual(HistorySearch.filter(commits, query: "widget").map(\.hash), ["a1", "c3"])
        XCTAssertTrue(HistorySearch.filter(commits, query: "zzz").isEmpty)
        XCTAssertTrue(HistorySearch.filter([], query: "widget").isEmpty)
    }

    func testMatchingIgnoresDiacritics() {
        let commits = [commit(subject: "Add café support", author: "Müller")]
        for query in ["cafe", "café", "muller"] {
            XCTAssertEqual(HistorySearch.filter(commits, query: query), commits)
        }
    }
}
