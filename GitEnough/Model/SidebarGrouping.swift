import Foundation

/// Grouping changes presentation only; it never changes repository identity or
/// the stored order used by the ungrouped sidebar.
public enum SidebarGroupingMode: String, CaseIterable, Identifiable {
    case none
    case forge
    case account
    case firstLetter
    case manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "No Grouping"
        case .forge: return "Forge"
        case .account: return "Account"
        case .firstLetter: return "First Letter"
        case .manual: return "Manual Groups"
        }
    }
}

public struct ManualRepositoryGroup: Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    public var sidebarID: String { "manual:\(id.uuidString)" }
}

public struct SidebarRepositoryGroup: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public var repositories: [Repository]
    public let manualGroupID: UUID?
}

public enum RepositoryGroupError: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case missingGroup
    case unregisteredRepository

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the group."
        case .duplicateName: return "A group with that name already exists. Choose a different name."
        case .missingGroup: return "This group no longer exists. Choose another group."
        case .unregisteredRepository: return "This repository is no longer in GitEnough. Add it again before assigning a group."
        }
    }
}

/// Pure grouping of an already filtered and sorted repository sequence. Buckets
/// preserve incoming order, including the starred-first order chosen by the UI.
public enum SidebarGrouping {
    public static let ungroupedID = "manual:ungrouped"

    public static func groups(for repositories: [Repository],
                              mode: SidebarGroupingMode,
                              summaries: [String: RepoSummary] = [:],
                              manualGroups: [ManualRepositoryGroup] = [],
                              assignments: [String: UUID] = [:]) -> [SidebarRepositoryGroup] {
        if mode == .none {
            return [SidebarRepositoryGroup(id: "none:all", title: "Repositories", subtitle: nil,
                                           repositories: repositories, manualGroupID: nil)]
        }
        if mode == .manual {
            return manualBuckets(repositories, groups: manualGroups, assignments: assignments)
        }

        var buckets: [String: SidebarRepositoryGroup] = [:]
        for repository in repositories {
            let key = automaticKey(for: repository, mode: mode, summary: summaries[repository.path])
            if buckets[key.id] == nil {
                buckets[key.id] = SidebarRepositoryGroup(id: key.id, title: key.title,
                                                         subtitle: key.subtitle,
                                                         repositories: [], manualGroupID: nil)
            }
            buckets[key.id]?.repositories.append(repository)
        }
        return buckets.values.sorted { left, right in
            let fallbackIDs: Set<String> = ["\(mode.rawValue):other", "\(mode.rawValue):local",
                                            "\(mode.rawValue):loading", "letter:#"]
            let leftIsFallback = fallbackIDs.contains(left.id)
            let rightIsFallback = fallbackIDs.contains(right.id)
            if leftIsFallback != rightIsFallback { return !leftIsFallback }
            let titleOrder = left.title.localizedStandardCompare(right.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return left.id < right.id
        }
    }

    private struct GroupKey {
        let id: String
        let title: String
        var subtitle: String? = nil
    }

    private static func automaticKey(for repository: Repository,
                                     mode: SidebarGroupingMode,
                                     summary: RepoSummary?) -> GroupKey {
        if mode == .firstLetter {
            let name = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let initial = name.first.map(String.init) ?? ""
            let letter = initial.folding(options: .diacriticInsensitive,
                                         locale: Locale(identifier: "en_US_POSIX")).uppercased()
            let title = initial.first?.isLetter == true ? letter : "#"
            return GroupKey(id: "letter:\(title)", title: title)
        }

        let prefix = mode.rawValue
        guard let summary else {
            return GroupKey(id: "\(prefix):loading", title: "Loading Repository Information…")
        }
        guard summary.isValid else {
            return GroupKey(id: "\(prefix):other", title: "Other Repositories")
        }
        guard let remoteURL = summary.groupingRemoteURL, !remoteURL.isEmpty else {
            return GroupKey(id: "\(prefix):local", title: "Local Repositories")
        }
        guard let forge = ForgeRepo.parse(remoteURL: remoteURL),
              let host = forge.origin.host else {
            return GroupKey(id: "\(prefix):other", title: "Other Repositories")
        }
        var authority = host.lowercased()
        if let port = forge.origin.port,
           !(forge.origin.scheme == "https" && port == 443),
           !(forge.origin.scheme == "http" && port == 80) {
            authority += ":\(port)"
        }
        let forgeName = authority == "github.com" ? "GitHub"
            : authority == "gitlab.com" ? "GitLab" : authority
        if mode == .forge {
            return GroupKey(id: "forge:\(authority)", title: forgeName)
        }
        let owner = forge.owner.removingPercentEncoding ?? forge.owner
        return GroupKey(id: "account:\(authority)/\(forge.owner)", title: owner, subtitle: forgeName)
    }

    private static func manualBuckets(_ repositories: [Repository],
                                      groups: [ManualRepositoryGroup],
                                      assignments: [String: UUID]) -> [SidebarRepositoryGroup] {
        let knownIDs = Set(groups.map(\.id))
        var result = groups.map {
            SidebarRepositoryGroup(id: $0.sidebarID, title: $0.name, subtitle: nil,
                                   repositories: [], manualGroupID: $0.id)
        }
        var ungrouped: [Repository] = []
        for repository in repositories {
            if let id = assignments[repository.path], knownIDs.contains(id),
               let index = result.firstIndex(where: { $0.manualGroupID == id }) {
                result[index].repositories.append(repository)
            } else {
                ungrouped.append(repository)
            }
        }
        if !ungrouped.isEmpty {
            result.append(SidebarRepositoryGroup(id: ungroupedID, title: "Ungrouped", subtitle: nil,
                                                repositories: ungrouped, manualGroupID: nil))
        }
        return result
    }
}
