import XCTest
@testable import GitEnough

final class SidebarGroupingTests: XCTestCase {
    private func repo(_ name: String) -> Repository {
        Repository(path: "/grouping/\(name)", name: name)
    }

    private func summary(_ remoteURL: String?, valid: Bool = true) -> RepoSummary {
        RepoSummary(branch: "main", isDirty: false, ahead: 0, behind: 0,
                    isValid: valid, groupingRemoteURL: remoteURL)
    }

    func testNoGroupingKeepsTheIncomingOrder() {
        let repos = [repo("Zulu"), repo("Alpha"), repo("Bravo")]
        let groups = SidebarGrouping.groups(for: repos, mode: .none)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].repositories, repos)
    }

    func testForgeGroupsUseTheHostWithoutNetworkGuessing() {
        let repos = [repo("GitHubSSH"), repo("GitLab"), repo("GitHubHTTPS"),
                     repo("SelfHosted"), repo("AnotherPort")]
        let summaries = [
            repos[0].path: summary("git@github.com:team/one.git"),
            repos[1].path: summary("https://gitlab.com/team/two.git"),
            repos[2].path: summary("https://GitHub.COM/team/three.git"),
            repos[3].path: summary("https://forge.example:3000/team/four.git"),
            repos[4].path: summary("https://forge.example:4000/team/five.git"),
        ]
        let groups = SidebarGrouping.groups(for: repos, mode: .forge, summaries: summaries)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.first { $0.id == "forge:github.com" }?.repositories,
                       [repos[0], repos[2]], "Within-group order must keep the incoming star/sort order")
        XCTAssertEqual(groups.first { $0.id == "forge:github.com" }?.title, "GitHub")
        XCTAssertNotNil(groups.first { $0.id == "forge:forge.example:3000" })
        XCTAssertNotNil(groups.first { $0.id == "forge:forge.example:4000" })
    }

    func testAccountGroupsCombineHostsButKeepCompleteNamespacesDistinct() {
        let repos = [repo("GitHub"), repo("GitLab"), repo("GitLabSubgroup"), repo("GitLabOther")]
        let summaries = [
            repos[0].path: summary("git@github.com:team/project.git"),
            repos[1].path: summary("https://gitlab.com/team/project.git"),
            repos[2].path: summary("ssh://git@gitlab.com/team/subgroup/project.git"),
            repos[3].path: summary("https://gitlab.com/other/subgroup/project.git"),
        ]
        let groups = SidebarGrouping.groups(for: repos, mode: .account, summaries: summaries)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first { $0.id == "account:owner:team" }?.subtitle, "GitHub, GitLab")
        XCTAssertEqual(groups.first { $0.id == "account:owner:team" }?.repositories,
                       Array(repos.prefix(2)))
        XCTAssertEqual(groups.first { $0.id == "account:owner:team/subgroup" }?.title,
                       "team/subgroup")
        XCTAssertNotNil(groups.first { $0.id == "account:owner:other/subgroup" })
    }

    func testGitHubAccountGroupingIgnoresOwnerCaseAndKeepsFirstDisplayName() {
        let repos = [repo("First"), repo("Second")]
        let groups = SidebarGrouping.groups(for: repos, mode: .account, summaries: [
            repos[0].path: summary("git@github.com:Acme/first.git"),
            repos[1].path: summary("https://github.com/acme/second.git"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "account:owner:acme")
        XCTAssertEqual(groups.first?.title, "Acme")
        XCTAssertEqual(groups.first?.subtitle, "GitHub")
        XCTAssertEqual(groups.first?.repositories, repos)
    }

    func testUnknownHostAccountGroupingMatchesOwnerCaseForPresentation() {
        let repos = [repo("First"), repo("Second")]
        let groups = SidebarGrouping.groups(for: repos, mode: .account, summaries: [
            repos[0].path: summary("git@forge.example:Acme/first.git"),
            repos[1].path: summary("https://forge.example/acme/second.git"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "account:owner:acme")
        XCTAssertEqual(groups.first?.title, "Acme")
        XCTAssertEqual(groups.first?.subtitle, "forge.example")
        XCTAssertEqual(groups.first?.repositories, repos)
    }

    func testAccountGroupsAggregateSortedUniqueForgesAcrossCaseVariants() {
        let repos = [repo("Codeberg"), repo("GitLab"), repo("GitHub"), repo("GitHubAgain")]
        let groups = SidebarGrouping.groups(for: repos, mode: .account, summaries: [
            repos[0].path: summary("https://codeberg.org/Acme/one.git"),
            repos[1].path: summary("git@gitlab.com:acme/two.git"),
            repos[2].path: summary("https://github.com/ACME/three.git"),
            repos[3].path: summary("git@github.com:Acme/four.git"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "account:owner:acme")
        XCTAssertEqual(groups.first?.title, "Acme")
        XCTAssertEqual(groups.first?.subtitle, "GitHub, GitLab, codeberg.org")
        XCTAssertEqual(groups.first?.repositories, repos)
    }

    func testAccountGroupingUsesTheFullDecodedOwnerNamespace() {
        let repos = [repo("First"), repo("Second"), repo("OtherNamespace")]
        let groups = SidebarGrouping.groups(for: repos, mode: .account, summaries: [
            repos[0].path: summary("https://forge.example/Team%20Space/Subgroup/one.git"),
            repos[1].path: summary("https://gitlab.com/team%20space/subgroup/two.git"),
            repos[2].path: summary("https://forge.example/other/Subgroup/three.git"),
        ])

        XCTAssertEqual(groups.count, 2)
        let matching = groups.first { $0.id == "account:owner:team space/subgroup" }
        XCTAssertEqual(matching?.title, "Team Space/Subgroup")
        XCTAssertEqual(matching?.repositories, Array(repos.prefix(2)))
        XCTAssertEqual(matching?.subtitle, "GitLab, forge.example")
        XCTAssertNotNil(groups.first { $0.id == "account:owner:other/subgroup" })
    }

    func testAccountNamedLocalDoesNotMergeWithRepositoriesWithoutARemote() {
        let repos = [repo("Hosted"), repo("Local")]
        let groups = SidebarGrouping.groups(for: repos, mode: .account, summaries: [
            repos[0].path: summary("https://github.com/local/one.git"),
            repos[1].path: summary(nil),
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.id == "account:owner:local" }?.repositories, [repos[0]])
        XCTAssertEqual(groups.first { $0.id == "account:local" }?.repositories, [repos[1]])
    }

    func testLocalUnavailableAndLoadingRepositoriesRemainReachable() {
        let repos = [repo("Local"), repo("Unsupported"), repo("Unavailable"), repo("Loading")]
        let groups = SidebarGrouping.groups(for: repos, mode: .forge, summaries: [
            repos[0].path: summary(nil),
            repos[1].path: summary("/local/mirror.git"),
            repos[2].path: summary(nil, valid: false),
        ])
        XCTAssertEqual(Set(groups.flatMap(\.repositories)), Set(repos))
        XCTAssertEqual(groups.first { $0.id == "forge:local" }?.repositories, [repos[0]])
        XCTAssertEqual(groups.first { $0.id == "forge:other" }?.repositories, [repos[1], repos[2]])
        XCTAssertEqual(groups.first { $0.id == "forge:loading" }?.repositories, [repos[3]])
    }

    func testFirstLetterSupportsAccentsAndNonLatinLetters() {
        let repos = [repo("Älan"), repo("apple"), repo("βeta"), repo("123"), repo("_misc")]
        let groups = SidebarGrouping.groups(for: repos, mode: .firstLetter)
        XCTAssertEqual(groups.first { $0.title == "A" }?.repositories, [repos[0], repos[1]])
        XCTAssertEqual(groups.first { $0.title == "Β" }?.repositories, [repos[2]])
        XCTAssertEqual(groups.last?.title, "#")
        XCTAssertEqual(groups.last?.repositories, [repos[3], repos[4]])
    }

    func testManualGroupsKeepCreationOrderEmptyGroupsAndUnknownAssignments() {
        let repos = [repo("Starred"), repo("Ordinary"), repo("Unassigned"), repo("StaleAssignment")]
        let first = ManualRepositoryGroup(name: "Work")
        let empty = ManualRepositoryGroup(name: "Empty")
        let last = ManualRepositoryGroup(name: "Personal")
        let groups = SidebarGrouping.groups(for: repos, mode: .manual,
                                             manualGroups: [first, empty, last], assignments: [
                                                repos[0].path: first.id,
                                                repos[1].path: first.id,
                                                repos[3].path: UUID(),
                                             ])
        XCTAssertEqual(groups.map(\.title), ["Work", "Empty", "Personal", "Ungrouped"])
        XCTAssertEqual(groups[0].repositories, Array(repos.prefix(2)))
        XCTAssertTrue(groups[1].repositories.isEmpty)
        XCTAssertEqual(groups[3].repositories, Array(repos.suffix(2)))
    }
}

final class ManualRepositoryGroupStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "GitEnough.ManualGroupTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        defaults = nil
        suite = nil
    }

    private func registeredStore() -> (RepoStore, Repository, Repository) {
        let store = RepoStore(defaults: defaults)
        let first = store.register(Repository(path: "/grouping/first", name: "First"))
        let second = store.register(Repository(path: "/grouping/second", name: "Second"))
        return (store, first, second)
    }

    func testCreateMoveRenameAndReloadKeepStableGroupIdentity() throws {
        let (store, first, second) = registeredStore()
        let group = try store.createGroup(named: "  Work  ", including: first)
        XCTAssertEqual(group.name, "Work")
        try store.move(second, toGroup: group)
        try store.renameGroup(group, to: "Projects")

        let restored = RepoStore(defaults: defaults)
        XCTAssertEqual(restored.manualGroups, [ManualRepositoryGroup(id: group.id, name: "Projects")])
        XCTAssertEqual(restored.manualGroup(for: first)?.id, group.id)
        XCTAssertEqual(restored.manualGroup(for: second)?.id, group.id)
    }

    func testDeletingAGroupPreservesRepositoriesStarsOrderAndExclusions() throws {
        let (store, first, second) = registeredStore()
        let removed = store.register(Repository(path: "/grouping/excluded", name: "Excluded"))
        store.remove(removed)
        store.toggleStar(first)
        store.markOpened(second)
        let group = try store.createGroup(named: "Work", including: first)
        try store.move(second, toGroup: group)
        let savedRepositories = defaults.data(forKey: "repositories.v1")
        let savedStars = defaults.stringArray(forKey: "starredRepositories.v1")
        let savedExclusions = defaults.stringArray(forKey: "excludedRepositories.v1")
        let savedRecency = defaults.data(forKey: "repoLastOpened.v1")
        let order = store.repositories

        store.deleteGroup(group)

        XCTAssertEqual(store.repositories, order)
        XCTAssertNil(store.manualGroup(for: first))
        XCTAssertNil(store.manualGroup(for: second))
        XCTAssertEqual(defaults.data(forKey: "repositories.v1"), savedRepositories)
        XCTAssertEqual(defaults.stringArray(forKey: "starredRepositories.v1"), savedStars)
        XCTAssertEqual(defaults.stringArray(forKey: "excludedRepositories.v1"), savedExclusions)
        XCTAssertEqual(defaults.data(forKey: "repoLastOpened.v1"), savedRecency)
        XCTAssertTrue(RepoStore(defaults: defaults).manualGroups.isEmpty)
        XCTAssertEqual(store.addDiscovered([removed.url]), 0)
    }

    func testGroupOperationsDoNotRewriteLegacyRepositoryPreferences() throws {
        let (store, first, second) = registeredStore()
        store.toggleStar(second)
        store.markOpened(first)
        let keys = ["repositories.v1", "starredRepositories.v1", "repoLastOpened.v1"]
        let before = keys.map { defaults.object(forKey: $0) as AnyObject? }
        let group = try store.createGroup(named: "Work")
        try store.move(first, toGroup: group)
        try store.renameGroup(group, to: "Renamed")
        store.deleteGroup(group)
        let after = keys.map { defaults.object(forKey: $0) as AnyObject? }
        for index in keys.indices {
            XCTAssertTrue(NSDictionary(dictionary: ["value": before[index] as Any])
                .isEqual(to: ["value": after[index] as Any]), keys[index])
        }
    }

    func testInvalidNamesAndMissingDestinationsLeaveStateUntouched() throws {
        let (store, first, _) = registeredStore()
        let group = try store.createGroup(named: "Work")
        XCTAssertThrowsError(try store.createGroup(named: "  \n ")) {
            XCTAssertEqual($0 as? RepositoryGroupError, .emptyName)
        }
        XCTAssertThrowsError(try store.createGroup(named: "work")) {
            XCTAssertEqual($0 as? RepositoryGroupError, .duplicateName)
        }
        let missing = ManualRepositoryGroup(name: "Missing")
        XCTAssertThrowsError(try store.move(first, toGroup: missing)) {
            XCTAssertEqual($0 as? RepositoryGroupError, .missingGroup)
        }
        let unlisted = Repository(path: "/grouping/not-registered", name: "Not Registered")
        XCTAssertThrowsError(try store.createGroup(named: "New", including: unlisted)) {
            XCTAssertEqual($0 as? RepositoryGroupError, .unregisteredRepository)
        }
        XCTAssertEqual(store.manualGroups, [group])
        XCTAssertTrue(store.manualGroupAssignments.isEmpty)
    }

    func testRemovingAndReaddingRepositoryDoesNotResurrectOldAssignment() throws {
        let (store, first, _) = registeredStore()
        let group = try store.createGroup(named: "Work", including: first)
        store.remove(first)
        XCTAssertNil(store.manualGroupAssignments[first.path])
        XCTAssertEqual(store.addDiscovered([first.url]), 0)
        let readded = store.register(first)
        XCTAssertNil(store.manualGroup(for: readded))
        XCTAssertEqual(store.manualGroups, [group])
    }

    func testEquivalentPathSpellingUsesTheRegisteredAssignment() throws {
        let (store, first, _) = registeredStore()
        let group = try store.createGroup(named: "Work")
        let equivalent = Repository(path: "/grouping/./first", name: "Equivalent")
        try store.move(equivalent, toGroup: group)
        XCTAssertEqual(store.manualGroup(for: first), group)
        XCTAssertEqual(RepoStore(defaults: defaults).manualGroup(for: first), group)
    }
}
