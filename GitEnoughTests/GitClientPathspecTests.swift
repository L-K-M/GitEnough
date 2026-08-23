import XCTest
@testable import GitEnough

/// Pure coverage for the pathspec boundary shared by every path-taking
/// GitClient operation. Git still interprets pathspec syntax after `--`, so the
/// literal magic prefix must be the outermost part of every returned argument.
final class GitClientPathspecTests: XCTestCase {

    func testLiteralPathspecPreservesGitMetacharactersAsFilenameText() {
        for path in ["star*.txt", "question?.txt", "bracket[1].txt",
                     ":(glob)magic*.txt"] {
            XCTAssertEqual(GitClient.literalPathspec(path), ":(literal)\(path)")
        }
    }
}
