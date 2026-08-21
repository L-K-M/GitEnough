import Foundation
import XCTest
@testable import GitEnough

final class AppStateSelectionTests: XCTestCase {
    private let repositoryKey = "repositories.v1"
    private let selectionKey = "selectedRepository"

    override func setUpWithError() throws {
        clearDefaults()
    }

    override func tearDownWithError() throws {
        clearDefaults()
    }

    func testInitializationRestoresRespelledRegisteredPath() throws {
        let repo = Repository(path: "/tmp/example/repo", name: "repo")
        try persistRepositories([repo])
        UserDefaults.standard.set("/tmp/example/./repo", forKey: selectionKey)

        let state = AppState()

        XCTAssertEqual(state.selectedRepoPath, repo.path)
        XCTAssertEqual(state.selectedRepository, repo)
        XCTAssertEqual(UserDefaults.standard.string(forKey: selectionKey), repo.path)
    }

    func testInitializationFallsBackWhenSavedPathIsMissing() throws {
        let repos = [
            Repository(path: "/tmp/first", name: "first"),
            Repository(path: "/tmp/second", name: "second")
        ]
        try persistRepositories(repos)
        UserDefaults.standard.set("/tmp/no-longer-registered", forKey: selectionKey)

        let state = AppState()

        XCTAssertEqual(state.selectedRepoPath, repos[0].path)
        XCTAssertEqual(state.selectedRepository, repos[0])
        XCTAssertEqual(UserDefaults.standard.string(forKey: selectionKey), repos[0].path)
    }

    func testInitializationFallsBackWhenNoSelectionWasSaved() throws {
        let repos = [
            Repository(path: "/tmp/first", name: "first"),
            Repository(path: "/tmp/second", name: "second")
        ]
        try persistRepositories(repos)

        let state = AppState()

        XCTAssertEqual(state.selectedRepoPath, repos[0].path)
        XCTAssertEqual(state.selectedRepository, repos[0])
        XCTAssertEqual(UserDefaults.standard.string(forKey: selectionKey), repos[0].path)
    }

    func testInitializationWithEmptyStoreClearsStaleSelection() {
        UserDefaults.standard.set("/tmp/no-longer-registered", forKey: selectionKey)

        let state = AppState()

        XCTAssertNil(state.selectedRepoPath)
        XCTAssertNil(state.selectedRepository)
        XCTAssertNil(UserDefaults.standard.string(forKey: selectionKey))
    }

    private func persistRepositories(_ repositories: [Repository]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(repositories),
                                  forKey: repositoryKey)
    }

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: repositoryKey)
        UserDefaults.standard.removeObject(forKey: selectionKey)
    }
}
