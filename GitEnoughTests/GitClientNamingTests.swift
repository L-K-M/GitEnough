import XCTest
@testable import GitEnough

/// Pure coverage for `GitClient.namingFiles`, the "a.txt, b.txt and 2 more"
/// fragment that `stageAll`'s refusal and the Stage All tooltip both build from.
/// It exists so the two cannot drift, which only holds while the one spelling is
/// itself correct — and its interesting case is a boundary, where an off-by-one
/// yields the absurd "and 0 more" rather than anything a reader would notice.
final class GitClientNamingTests: XCTestCase {

    func testFewerPathsThanTheLimitAreAllNamed() {
        XCTAssertEqual(GitClient.namingFiles(["a.txt"]), "a.txt")
        XCTAssertEqual(GitClient.namingFiles(["a.txt", "b.txt"]), "a.txt, b.txt")
    }

    /// The boundary. `paths.count == limit` must not produce a remainder clause.
    func testExactlyTheLimitAddsNoRemainder() {
        XCTAssertEqual(GitClient.namingFiles(["a.txt", "b.txt", "c.txt"]),
                       "a.txt, b.txt, c.txt")
    }

    func testBeyondTheLimitNamesTheFirstFewAndCountsTheRest() {
        XCTAssertEqual(GitClient.namingFiles(["a.txt", "b.txt", "c.txt", "d.txt"]),
                       "a.txt, b.txt, c.txt and 1 more")
        XCTAssertEqual(GitClient.namingFiles((1...9).map { "f\($0).txt" }),
                       "f1.txt, f2.txt, f3.txt and 6 more")
    }

    /// Both callers guard on a non-empty list, so this pins the shape rather
    /// than a reachable case: empty in, empty out — never a stray " and 0 more"
    /// or a leading separator that would render as "()" with punctuation in it.
    func testAnEmptyListNamesNothing() {
        XCTAssertEqual(GitClient.namingFiles([]), "")
    }

    /// The limit is a parameter, so a caller with a narrower tooltip can lower
    /// it; the remainder must count against *that* limit, not the default 3.
    func testTheLimitIsHonouredWhenTheCallerOverridesIt() {
        XCTAssertEqual(GitClient.namingFiles(["a.txt", "b.txt", "c.txt"], limit: 1),
                       "a.txt and 2 more")
    }
}
