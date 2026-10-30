#if canImport(AppKit) && !SWIFT_PACKAGE
import XCTest
@testable import GitEnough

@MainActor
final class RepositoryWindowStateTests: XCTestCase {
    func testWindowsNavigateIndependentlyAndShareRepositoryOperationQueue() throws {
        let suite = "GitEnough.WindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRepo = try repository(named: "first", under: root)
        let secondRepo = try repository(named: "second", under: root)
        let activity = GitActivityStore(fileURL: root.appendingPathComponent("activity.jsonl"))
        let backing = AppState(defaults: defaults, activityStore: activity)
        defer { activity.loadFromDisk() }
        backing.store.register(firstRepo)
        backing.store.register(secondRepo)
        let recents = RecentRepositoryStore(defaults: defaults)
        let firstWindow = RepositoryWindowState(appState: backing, recentRepositories: recents)
        let secondWindow = RepositoryWindowState(appState: backing, recentRepositories: recents)

        firstWindow.select(firstRepo)
        firstWindow.selectedTab = .changes
        firstWindow.inspectorVisible = false
        firstWindow.expandedSidebarGroupID = "manual:first"
        secondWindow.select(secondRepo)
        secondWindow.selectedTab = .branches
        secondWindow.expandedSidebarGroupID = "account:github.com/other"

        XCTAssertEqual(firstWindow.selectedRepository, firstRepo)
        XCTAssertEqual(firstWindow.selectedTab, .changes)
        XCTAssertFalse(firstWindow.inspectorVisible)
        XCTAssertEqual(firstWindow.expandedSidebarGroupID, "manual:first")
        XCTAssertEqual(secondWindow.selectedRepository, secondRepo)
        XCTAssertEqual(secondWindow.selectedTab, .branches)
        XCTAssertTrue(secondWindow.inspectorVisible)
        XCTAssertEqual(secondWindow.expandedSidebarGroupID, "account:github.com/other")
        XCTAssertEqual(defaults.string(forKey: AppState.selectedRepositoryKey), secondRepo.path)

        firstWindow.activate()
        XCTAssertEqual(backing.selectedRepository, firstRepo,
                       "Auto-fetch must follow the focused repository window")
        XCTAssertEqual(secondWindow.selectedRepository, secondRepo)

        let firstModel = try XCTUnwrap(firstWindow.activeViewModel)
        secondWindow.select(firstRepo)
        XCTAssertTrue(firstModel === secondWindow.activeViewModel,
                      "Windows must share one model and operation gate for a working copy")
        XCTAssertEqual(firstWindow.selectedTab, .changes)
        XCTAssertEqual(firstWindow.expandedSidebarGroupID, "manual:first")
        XCTAssertEqual(secondWindow.selectedTab, .branches)
        firstModel.queue.sync {}
        backing.viewModel(for: secondRepo).queue.sync {}
    }

    func testRestoredWindowUsesRegisteredPathAndRepairsRemovedRepository() throws {
        let suite = "GitEnough.WindowRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRepo = try repository(named: "first", under: root)
        let secondRepo = try repository(named: "second", under: root)
        let activity = GitActivityStore(fileURL: root.appendingPathComponent("activity.jsonl"))
        let backing = AppState(defaults: defaults, activityStore: activity)
        defer { activity.loadFromDisk() }
        backing.store.register(firstRepo)
        backing.store.register(secondRepo)
        let window = RepositoryWindowState(appState: backing,
                                           recentRepositories: RecentRepositoryStore(defaults: defaults))

        window.restore(path: firstRepo.path + "/.", tab: DetailTab.changes.rawValue,
                       inspectorVisible: false)
        XCTAssertEqual(window.selectedRepository, firstRepo)
        XCTAssertEqual(window.selectedTab, .changes)
        XCTAssertFalse(window.inspectorVisible)

        let firstModel = try XCTUnwrap(window.activeViewModel)
        window.remove(firstRepo)
        XCTAssertEqual(window.selectedRepository, secondRepo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstRepo.path),
                      "Removing a sidebar entry must not remove the working copy")
        firstModel.queue.sync {}
        backing.viewModel(for: secondRepo).queue.sync {}
    }

    func testOnlyExplicitSelectionRequestsRevealingTheRepositoryGroup() throws {
        let suite = "GitEnough.WindowRevealTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRepo = try repository(named: "first", under: root)
        let secondRepo = try repository(named: "second", under: root)
        let activity = GitActivityStore(fileURL: root.appendingPathComponent("activity.jsonl"))
        let backing = AppState(defaults: defaults, activityStore: activity)
        defer { activity.loadFromDisk() }
        backing.store.register(firstRepo)
        backing.store.register(secondRepo)
        let recents = RecentRepositoryStore(defaults: defaults)
        let window = RepositoryWindowState(appState: backing, recentRepositories: recents)
        let otherWindow = RepositoryWindowState(appState: backing, recentRepositories: recents)
        window.expandedSidebarGroupID = "manual:browsing-another-group"
        let initialRequest = window.repositorySelectionRequest

        window.restore(path: secondRepo.path, tab: DetailTab.history.rawValue, inspectorVisible: true)
        window.activate()
        otherWindow.select(firstRepo)
        XCTAssertEqual(window.selectedRepository, secondRepo)
        XCTAssertEqual(window.expandedSidebarGroupID, "manual:browsing-another-group")
        XCTAssertEqual(window.repositorySelectionRequest, initialRequest,
                       "Restoring, activating, and navigating another window must preserve the browsed group")

        window.select(secondRepo)
        let repeatedSelectionRequest = window.repositorySelectionRequest
        XCTAssertNotEqual(repeatedSelectionRequest, initialRequest,
                          "Explicitly choosing the current repository must still request its group")
        window.select(firstRepo)
        XCTAssertNotEqual(window.repositorySelectionRequest, repeatedSelectionRequest)
        backing.viewModel(for: firstRepo).queue.sync {}
        backing.viewModel(for: secondRepo).queue.sync {}
    }

    private func repository(named name: String, under root: URL) throws -> Repository {
        guard GitShell.shared.isAvailable else { throw XCTSkip("git is not installed") }
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try GitShell.shared.runChecked(["init", "-b", "main"], in: url)
        return Repository(url: url)
    }
}
#endif
