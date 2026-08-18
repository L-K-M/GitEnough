import XCTest
@testable import GitEnough

/// Filesystem-level tests for watch-folder discovery.
final class RepoDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitEnoughDiscovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    func testFindsReposAtDepthOneAndTwoAndSkipsNoise() throws {
        let repoA = try makeRepo("repoA")                       // depth 1
        let repoB = try makeRepo("org/repoB")                   // depth 2
        let worktree = try makeRepo("worktree", gitAsFile: true) // .git as a file
        try makeRepo(".hidden/repoC")                           // hidden parent — skipped
        try makeRepo("node_modules/pkg")                        // package dir — skipped
        try makeRepo("org/repoB/inner")                         // below a repo boundary
        try makeRepo("a/b/c/repoD")                             // depth 3 — too deep

        let found = RepoDiscovery.findRepositories(in: root)
        XCTAssertEqual(Set(found.map(\.path)),
                       Set([repoA, repoB, worktree].map(\.path)))
    }

    func testRootItselfCountsAsRepository() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try makeRepo("other")

        let found = RepoDiscovery.findRepositories(in: root)
        XCTAssertEqual(found.map(\.path), [root.path, root.appendingPathComponent("other").path])
    }

    func testMaxDepthControlsHowDeepTheScanGoes() throws {
        let repoA = try makeRepo("repoA")
        try makeRepo("org/repoB")

        XCTAssertEqual(RepoDiscovery.findRepositories(in: root, maxDepth: 1).map(\.path),
                       [repoA.path])
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

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: repositoryKey)
        UserDefaults.standard.removeObject(forKey: excludedKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: repositoryKey)
        UserDefaults.standard.removeObject(forKey: excludedKey)
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
        XCTAssertNotNil(store.add(url: repoURL))
        XCTAssertEqual(store.repositories.count, 1)
        XCTAssertEqual(store.addDiscovered([repoURL]), 0)
        XCTAssertEqual(store.repositories.count, 1)
    }
}
