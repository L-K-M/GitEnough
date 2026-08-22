import Foundation
import XCTest
@testable import GitEnough

final class AppStateSelectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "GitEnough.AppStateSelectionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    func testInitializationRestoresRespelledRegisteredPath() {
        let repo = Repository(path: "/tmp/example/repo", name: "repo")
        seedRepositories([repo])
        defaults.set("/tmp/example/./repo", forKey: AppState.selectedRepositoryKey)

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.selectedRepoPath, repo.path)
        XCTAssertEqual(state.selectedRepository, repo)
        XCTAssertEqual(defaults.string(forKey: AppState.selectedRepositoryKey), repo.path)
    }

    func testInitializationFallsBackWhenSavedPathIsMissing() {
        let repos = [
            Repository(path: "/tmp/first", name: "first"),
            Repository(path: "/tmp/second", name: "second")
        ]
        seedRepositories(repos)
        defaults.set("/tmp/no-longer-registered", forKey: AppState.selectedRepositoryKey)

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.selectedRepoPath, repos[0].path)
        XCTAssertEqual(state.selectedRepository, repos[0])
        XCTAssertEqual(defaults.string(forKey: AppState.selectedRepositoryKey), repos[0].path)
    }

    func testInitializationFallsBackWhenNoSelectionWasSaved() {
        let repos = [
            Repository(path: "/tmp/first", name: "first"),
            Repository(path: "/tmp/second", name: "second")
        ]
        seedRepositories(repos)

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.selectedRepoPath, repos[0].path)
        XCTAssertEqual(state.selectedRepository, repos[0])
        XCTAssertEqual(defaults.string(forKey: AppState.selectedRepositoryKey), repos[0].path)
    }

    func testInitializationWithEmptyStoreClearsStaleSelection() {
        defaults.set("/tmp/no-longer-registered", forKey: AppState.selectedRepositoryKey)

        let state = AppState(defaults: defaults)

        XCTAssertNil(state.selectedRepoPath)
        XCTAssertNil(state.selectedRepository)
        XCTAssertNil(defaults.string(forKey: AppState.selectedRepositoryKey))
    }

    private func seedRepositories(_ repositories: [Repository]) {
        let store = RepoStore(defaults: defaults)
        // register inserts at the front, so reverse the fixtures to preserve
        // their declared order for first-repository fallback assertions.
        for repository in repositories.reversed() {
            store.register(repository)
        }
    }
}
