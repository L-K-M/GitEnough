import XCTest
@testable import GitEnough

/// Folder-name derivation for the clone sheet: what `git clone` itself would
/// call the destination folder.
final class CloneURLTests: XCTestCase {

    func testHTTPSWithURLSuffix() {
        XCTAssertEqual(CloneURL("https://github.com/owner/repo.git").suggestedFolderName,
                       "repo")
    }

    func testHTTPWithoutSuffix() {
        XCTAssertEqual(CloneURL("http://git.example.com/group/project").suggestedFolderName,
                       "project")
    }

    func testSSHSchemeForm() {
        XCTAssertEqual(CloneURL("ssh://git@github.com/owner/repo.git").suggestedFolderName,
                       "repo")
    }

    func testScpLikeFormWithUser() {
        // A naive "/" split yields the whole colon-joined string here.
        XCTAssertEqual(CloneURL("git@github.com:owner/repo.git").suggestedFolderName,
                       "repo")
    }

    func testScpLikeFormWithoutUser() {
        XCTAssertEqual(CloneURL("github.com:owner/repo.git").suggestedFolderName,
                       "repo")
    }

    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(CloneURL("https://github.com/owner/repo/").suggestedFolderName,
                       "repo")
    }

    func testLocalPath() {
        XCTAssertEqual(CloneURL("/Users/dev/code/GitEnough").suggestedFolderName,
                       "GitEnough")
        XCTAssertEqual(CloneURL("../neighbor/repo").suggestedFolderName, "repo")
    }

    func testBareName() {
        XCTAssertEqual(CloneURL("repo").suggestedFolderName, "repo")
    }

    func testUnderivableNamesAreNil() {
        XCTAssertNil(CloneURL("").suggestedFolderName)
        XCTAssertNil(CloneURL("   ").suggestedFolderName)
        XCTAssertNil(CloneURL("https://github.com/owner/.git").suggestedFolderName)
        XCTAssertNil(CloneURL("/").suggestedFolderName)
    }
}
