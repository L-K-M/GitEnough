import XCTest
@testable import GitEnough

final class ChangeSelectionTests: XCTestCase {

    private let both = FileChange(path: "App.swift", originalPath: nil,
                                  stagedStatus: .modified, unstagedStatus: .modified)

    func testStagedAndUnstagedRowsHaveDifferentIdentity() {
        XCTAssertNotEqual(ChangeSelection(file: both, isStaged: true),
                          ChangeSelection(file: both, isStaged: false))
    }

    func testPartiallyStagedSelectionPreservesChosenSide() throws {
        let status = RepoStatus(staged: [both], unstaged: [both])

        XCTAssertTrue(try XCTUnwrap(
            ChangeSelection(file: both, isStaged: true).updated(for: status)).isStaged)
        XCTAssertFalse(try XCTUnwrap(
            ChangeSelection(file: both, isStaged: false).updated(for: status)).isStaged)
    }

    func testSelectionFollowsFileBetweenSectionsAndClearsWhenGone() throws {
        let selected = ChangeSelection(file: both, isStaged: true)
        let unstagedOnly = FileChange(path: "App.swift", originalPath: nil,
                                       stagedStatus: nil, unstagedStatus: .modified)

        let followed = try XCTUnwrap(selected.updated(
            for: RepoStatus(unstaged: [unstagedOnly])))
        XCTAssertFalse(followed.isStaged)
        XCTAssertNil(followed.updated(for: .empty))
    }
}
