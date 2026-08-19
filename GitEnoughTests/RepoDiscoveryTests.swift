import XCTest
@testable import GitEnough

/// Filesystem-level tests for watch-folder discovery.
final class RepoDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        // temporaryDirectory sits behind /var → /private/var, and
        // contentsOfDirectory returns physically-resolved child paths. Create the
        // directory FIRST, then canonicalize — resolvingSymlinksInPath can't
        // resolve a path that doesn't exist yet.
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughDiscovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = raw.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates `relativePath` and a `.git` entry inside it (directory by default,
    /// or a file — a linked worktree's `.git`).
    @discardableResult
    private func makeRepo(_ relativePath: String, gitAsFile: Bool = false) throws -> URL {
        let dir = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = dir.appendingPathComponent(".git")
        if gitAsFile {
            try "gitdir: /elsewhere\n".write(to: git, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        }
        return dir
    }

    private func makeDir(_ relativePath: String) throws -> URL {
        let dir = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func canonicalPaths(_ urls: [URL]) -> Set<String> {
        Set(urls.map { $0.resolvingSymlinksInPath().path })
    }

    func testFindsReposAtDepthOneAndTwoAndSkipsNoise() throws {
        let repoA = try makeRepo("repoA")                       // depth 1
        let repoB = try makeRepo("org/repoB")                   // depth 2
        let worktree = try makeRepo("worktree", gitAsFile: true) // .git as a file
        try makeRepo(".hidden/repoC")                           // hidden parent — skipped
        try makeRepo("node_modules/pkg")                        // package dir — skipped
        try makeRepo("org/repoB/inner")                         // below a repo boundary
        try makeRepo("a/b/c/repoD")                             // depth 3 — too deep

        XCTAssertEqual(canonicalPaths(RepoDiscovery.findRepositories(in: root)),
                       canonicalPaths([repoA, repoB, worktree]))
    }

    func testRootItselfCountsAsRepository() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try makeRepo("other")

        XCTAssertEqual(canonicalPaths(RepoDiscovery.findRepositories(in: root)),
                       canonicalPaths([root, root.appendingPathComponent("other")]))
    }

    func testMaxDepthControlsHowDeepTheScanGoes() throws {
        let repoA = try makeRepo("repoA")
        try makeRepo("org/repoB")

        XCTAssertEqual(RepoDiscovery.findRepositories(in: root, maxDepth: 1)
            .map { $0.resolvingSymlinksInPath().path },
                       [repoA.resolvingSymlinksInPath().path])
        XCTAssertEqual(RepoDiscovery.findRepositories(in: root, maxDepth: 0), [])
    }

    func testVisitedDirectoryCapIsRespected() throws {
        for index in 0..<50 {
            try makeDir("dir\(index)")
        }
        // An absurdly small cap must not blow up or spin; it just finds little.
        let found = RepoDiscovery.findRepositories(in: root, maxDepth: 2, maxVisitedDirectories: 3)
        XCTAssertTrue(found.isEmpty)
    }
}

/// Tests the sidebar store's discovery bookkeeping: dedupe, and the "removal
/// sticks" exclusion list.
final class RepoStoreTests: XCTestCase {

    private let repositoryKey = "repositories.v1"
    private let excludedKey = "excludedRepositories.v1"
    private let lastOpenedKey = "repoLastOpened.v1"
    private let starredKey = "starredRepositories.v1"

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: repositoryKey)
        UserDefaults.standard.removeObject(forKey: excludedKey)
        UserDefaults.standard.removeObject(forKey: lastOpenedKey)
        UserDefaults.standard.removeObject(forKey: starredKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: repositoryKey)
        UserDefaults.standard.removeObject(forKey: excludedKey)
        UserDefaults.standard.removeObject(forKey: lastOpenedKey)
        UserDefaults.standard.removeObject(forKey: starredKey)
    }

    func testDiscoveryAddsEachRepositoryOnlyOnce() {
        let store = RepoStore()
        let url = URL(fileURLWithPath: "/tmp/some/repo")
        XCTAssertEqual(store.addDiscovered([url]), 1)
        XCTAssertEqual(store.repositories.map(\.path), [url.path])
        // Second discovery pass of the same folder is a no-op.
        XCTAssertEqual(store.addDiscovered([url]), 0)
        XCTAssertEqual(store.repositories.count, 1)
        // And it survives a store reload.
        let reloaded = RepoStore()
        XCTAssertEqual(reloaded.repositories.map(\.path), [url.path])
    }

    func testRemovalSticksForDiscoveredRepositories() {
        let store = RepoStore()
        let url = URL(fileURLWithPath: "/tmp/some/repo")
        _ = store.addDiscovered([url])
        store.remove(store.repositories[0])
        XCTAssertTrue(store.repositories.isEmpty)

        // Discovery must not resurrect it…
        XCTAssertEqual(store.addDiscovered([url]), 0)
        XCTAssertTrue(store.repositories.isEmpty)

        // …not even for a reloaded store.
        XCTAssertTrue(RepoStore().repositories.isEmpty)
        XCTAssertEqual(RepoStore().addDiscovered([url]), 0)
    }

    func testManualAddOverridesRemovalExclusion() throws {
        guard GitShell.shared.isAvailable else {
            throw XCTSkip("git is not installed on this machine")
        }
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }
        _ = try GitShell.shared.runChecked(["init", "-b", "main"], in: repoURL)

        // Removed once (so discovery won't touch it)…
        let store = RepoStore()
        store.addDiscovered([repoURL])
        store.remove(store.repositories[0])

        // …but an explicit add re-includes the path for future discovery.
        // (Validation is AppState's job now — GitClient.isRepository/topLevel —
        // RepoStore registers the validated root via register(_:).)
        let registered = store.register(Repository(url: repoURL))
        XCTAssertEqual(store.repositories.count, 1)
        XCTAssertEqual(store.repositories[0], registered)
        XCTAssertEqual(store.addDiscovered([repoURL]), 0)
        XCTAssertEqual(store.repositories.count, 1)
    }

    func testMarkOpenedPersistsTimestamps() throws {
        let store = RepoStore()
        let repo = Repository(path: "/tmp/repo", name: "repo")
        XCTAssertNil(store.lastOpenedAt[repo.path])
        store.markOpened(repo)
        XCTAssertNotNil(store.lastOpenedAt[repo.path])
        // Survives a store reload.
        XCTAssertNotNil(RepoStore().lastOpenedAt[repo.path])
    }

    func testManualAddInsertsAtTopOfUnstarredBlock() {
        let store = RepoStore()
        _ = store.register(Repository(path: "/tmp/a", name: "a"))
        _ = store.register(Repository(path: "/tmp/b", name: "b"))
        // Newest first — a manual add is something the user just did and is
        // looking for; a bottom-of-the-list append reads as "didn't appear".
        XCTAssertEqual(store.repositories.map(\.name), ["b", "a"])

        // Starring pins above new additions too.
        store.toggleStar(store.repositories.last!)   // a
        _ = store.register(Repository(path: "/tmp/c", name: "c"))
        XCTAssertEqual(store.repositories.map(\.name), ["a", "c", "b"])
    }

    func testStarringPersistsAcrossReload() {
        let store = RepoStore()
        let repo = Repository(path: "/tmp/repo", name: "repo")
        _ = store.register(repo)
        XCTAssertFalse(store.isStarred(repo))

        store.toggleStar(repo)
        XCTAssertTrue(store.isStarred(repo))
        XCTAssertTrue(RepoStore().isStarred(repo))   // survives a store reload

        store.toggleStar(repo)
        XCTAssertFalse(store.isStarred(repo))
        XCTAssertFalse(RepoStore().isStarred(repo))
    }

    func testMoveVisibleAppliesDragAndKeepsStarredFirst() {
        let store = RepoStore()
        _ = store.register(Repository(path: "/tmp/a", name: "a"))
        _ = store.register(Repository(path: "/tmp/b", name: "b"))
        _ = store.register(Repository(path: "/tmp/c", name: "c"))
        // Store order is [c, b, a] (manual adds insert at top); star "a".
        store.toggleStar(store.repositories.last!)

        // The visible list pins "a" first: [a, c, b]. Drag "b" to the top.
        let visible = [
            Repository(path: "/tmp/a", name: "a"),
            Repository(path: "/tmp/c", name: "c"),
            Repository(path: "/tmp/b", name: "b"),
        ]
        store.moveVisible(visible, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        // "b" wins the unstarred block, but the starred "a" still pins above it.
        XCTAssertEqual(store.repositories.map(\.name), ["a", "b", "c"])

        // The reordered list survives a reload.
        XCTAssertEqual(RepoStore().repositories.map(\.name), ["a", "b", "c"])
    }

    func testMoveVisibleIgnoresMismatchedVisibleList() {
        let store = RepoStore()
        _ = store.register(Repository(path: "/tmp/a", name: "a"))
        _ = store.register(Repository(path: "/tmp/b", name: "b"))
        // A visible list that isn't a permutation of the store (e.g. filtered)
        // must not corrupt the manual order — the sidebar only attaches onMove
        // when unfiltered, and this guard keeps that promise honest.
        store.moveVisible([Repository(path: "/nope", name: "nope")],
                          fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertEqual(Set(store.repositories.map(\.name)), ["a", "b"])
    }
}
