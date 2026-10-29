import XCTest
@testable import GitEnough

final class RecentRepositoryStoreTests: XCTestCase {
    private var suite: String = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "GitEnough.RecentRepositoryTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testRecentPathsSurviveAnEmptySystemListInANewBuild() {
        let first = URL(fileURLWithPath: "/repos/first")
        let second = URL(fileURLWithPath: "/repos/second")
        let store = RecentRepositoryStore(defaults: defaults, initialURLs: [first])
        store.noteOpened(second)

        let newBuild = RecentRepositoryStore(defaults: defaults, initialURLs: [])
        XCTAssertEqual(newBuild.urls, [second, first])
    }

    func testClearPersistsWithoutResurrectingNativeEntriesOrChangingSidebarData() {
        let sidebar = Data("existing sidebar metadata".utf8)
        defaults.set(sidebar, forKey: "repositories.v1")
        let url = URL(fileURLWithPath: "/repos/first")
        let store = RecentRepositoryStore(defaults: defaults, initialURLs: [url])
        store.clear()

        let reopened = RecentRepositoryStore(defaults: defaults, initialURLs: [url])
        XCTAssertTrue(reopened.urls.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "repositories.v1"), sidebar)
    }

    func testReopeningMovesEquivalentPathsToTheFrontAndLimitsHistory() {
        let initial = (0..<12).map { URL(fileURLWithPath: "/repos/repo\($0)") }
        let store = RecentRepositoryStore(defaults: defaults, initialURLs: initial)
        XCTAssertEqual(store.urls.count, 10)
        let equivalent = URL(fileURLWithPath: "/repos/repo5/../repo5")
        store.noteOpened(equivalent)
        XCTAssertEqual(store.urls.first, equivalent)
        XCTAssertEqual(store.urls.count, 10)
        XCTAssertEqual(store.urls.filter { Repository.normalizedPath($0.path) == "/repos/repo5" }.count, 1)
        XCTAssertEqual(RecentRepositoryStore(defaults: defaults).urls, store.urls)
    }

    func testRecentRepositoriesIgnoreWebURLs() throws {
        let file = URL(fileURLWithPath: "/repos/working-copy")
        let web = try XCTUnwrap(URL(string: "https://example.invalid/repository"))
        let store = RecentRepositoryStore(defaults: defaults, initialURLs: [web, file])
        store.noteOpened(web)
        XCTAssertEqual(store.urls, [file])
    }
}
