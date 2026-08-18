import XCTest
@testable import GitEnough

/// PATH augmentation for git child processes: apps launched from Finder get
/// launchd's bare PATH, and git hooks (husky, lint-staged) calling npm would
/// die with "command not found" without the well-known tool locations.
final class GitShellEnvironmentTests: XCTestCase {

    private let home = "/Users/test"

    private func augmented(base: String = "/usr/bin:/bin",
                           existingDirs: Set<String> = [],
                           nvmVersions: [String] = [],
                           files: [String: String] = [:]) -> String {
        GitShell.augmentedPATH(base: base,
                               home: home,
                               directoryExists: { existingDirs.contains($0) },
                               nvmVersionDirs: { nvmVersions },
                               fileContents: { files[$0] })
    }

    func testExistingToolDirectoriesAreAppended() {
        let path = augmented(existingDirs: ["/opt/homebrew/bin", home + "/.bun/bin"])
        XCTAssertEqual(path, "/usr/bin:/bin:/opt/homebrew/bin:\(home)/.bun/bin")
    }

    func testMissingDirectoriesAreSkipped() {
        XCTAssertEqual(augmented(), "/usr/bin:/bin")
    }

    func testDirectoriesAlreadyOnPathAreNotDuplicated() {
        let path = augmented(base: "/opt/homebrew/bin:/usr/bin:/bin",
                             existingDirs: ["/opt/homebrew/bin"])
        XCTAssertEqual(path, "/opt/homebrew/bin:/usr/bin:/bin")
    }

    func testLatestNvmVersionWinsByDefault() {
        // A string sort would rank "v9.11.2" above "v10.2.0"; numeric ordering
        // must pick v10.
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v10.2.0/bin"],
                             nvmVersions: ["v9.11.2", "v10.2.0"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v10.2.0/bin"))
    }

    func testNvmDefaultAliasSelectsMatchingVersion() {
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v18.20.4/bin"],
                             nvmVersions: ["v18.20.4", "v22.11.0"],
                             files: [home + "/.nvm/alias/default": "18\n"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v18.20.4/bin"))
    }

    func testNvmNodeAliasMeansLatest() {
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v22.11.0/bin"],
                             nvmVersions: ["v18.20.4", "v22.11.0"],
                             files: [home + "/.nvm/alias/default": "node"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v22.11.0/bin"))
    }

    func testStrayEntriesInNvmVersionsDirectoryAreIgnored() {
        let path = augmented(existingDirs: [home + "/.nvm/versions/node/v20.1.0/bin"],
                             nvmVersions: [".cache", "v20.1.0"])
        XCTAssertTrue(path.hasSuffix(":" + home + "/.nvm/versions/node/v20.1.0/bin"))
    }
}
