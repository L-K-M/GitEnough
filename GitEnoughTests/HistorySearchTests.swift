import XCTest
@testable import GitEnough

/// Tests for the History tab's commit matcher.
final class HistorySearchTests: XCTestCase {

    private func commit(_ hash: String,
                        subject: String,
                        author: String = "Ada Lovelace",
                        email: String = "ada@example.com",
                        decorations: [RefDecoration] = []) -> Commit {
        Commit(hash: hash, parents: [], author: author, email: email,
               date: nil, subject: subject, decorations: decorations)
    }

    func testEmptyQueryMatchesEverything() {
        let commits = [commit("a1", subject: "one"), commit("b2", subject: "two")]
        XCTAssertEqual(HistorySearch.filter(commits, query: ""), commits)
        XCTAssertEqual(HistorySearch.filter(commits, query: "   "), commits)
    }

    func testMatchesSubjectCaseInsensitively() {
        let c = commit("a1", subject: "Fix the layout engine")
        XCTAssertTrue(HistorySearch.matches(c, query: "layout"))
        XCTAssertTrue(HistorySearch.matches(c, query: "FIX"))
        XCTAssertFalse(HistorySearch.matches(c, query: "printer"))
    }

    func testMatchesAuthorAndEmail() {
        let c = commit("a1", subject: "unrelated", author: "Grace Hopper", email: "grace@navy.mil")
        XCTAssertTrue(HistorySearch.matches(c, query: "hopper"))
        XCTAssertTrue(HistorySearch.matches(c, query: "navy.mil"))
        XCTAssertFalse(HistorySearch.matches(c, query: "ada"))
    }

    func testMatchesHashPrefix() {
        let c = commit("abcdef123456", subject: "unrelated")
        XCTAssertTrue(HistorySearch.matches(c, query: "abcdef1"))
        XCTAssertTrue(HistorySearch.matches(c, query: "abcdef123456"))
        XCTAssertFalse(HistorySearch.matches(c, query: "abcdef9"))
    }

    func testMatchesDecorationNames() {
        let c = commit("a1", subject: "unrelated",
                       decorations: [RefDecoration(kind: .localBranch, name: "feature/ui"),
                                     RefDecoration(kind: .tag, name: "v1.2.0")])
        XCTAssertTrue(HistorySearch.matches(c, query: "ui"))
        XCTAssertTrue(HistorySearch.matches(c, query: "v1.2"))
        XCTAssertFalse(HistorySearch.matches(c, query: "v2.0"))
    }

    func testFilterPreservesOrderAndSubsets() {
        let commits = [
            commit("a1", subject: "Add widget"),
            commit("b2", subject: "Remove gadget"),
            commit("c3", subject: "Refactor widget tests", author: "Someone Else"),
        ]
        XCTAssertEqual(HistorySearch.filter(commits, query: "widget").map(\.hash), ["a1", "c3"])
        XCTAssertEqual(HistorySearch.filter(commits, query: "ada").count, 3)
        XCTAssertTrue(HistorySearch.filter(commits, query: "zzz").isEmpty)
    }

    func testDiacriticInsensitiveMatching() {
        let c = commit("a1", subject: "Add café support")
        XCTAssertTrue(HistorySearch.matches(c, query: "cafe"))
        XCTAssertTrue(HistorySearch.matches(c, query: "café"))
    }
}
