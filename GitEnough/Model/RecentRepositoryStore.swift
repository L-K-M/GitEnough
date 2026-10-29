import Foundation

/// App-owned recent paths survive development builds whose ad-hoc signatures
/// cause macOS to reset its shared-file list. The system list is still updated
/// by the Mac UI for Dock and Finder integration.
public final class RecentRepositoryStore: ObservableObject {
    @Published public private(set) var urls: [URL]

    private static let storageKey = "recentRepositoryPaths.v1"
    private static let maximumCount = 10
    private let defaults: UserDefaults

    public init(defaults: UserDefaults, initialURLs: [URL] = []) {
        self.defaults = defaults
        let storedPaths = defaults.stringArray(forKey: Self.storageKey)
        let storedURLs = storedPaths?.map {
            URL(fileURLWithPath: $0)
        }
        urls = Self.uniqueFileURLs(storedURLs ?? initialURLs)
        if storedPaths != urls.map(\.path) { persist() }
    }

    public func noteOpened(_ url: URL) {
        guard url.isFileURL else { return }
        urls = Self.uniqueFileURLs([url] + urls)
        persist()
    }

    public func clear() {
        urls = []
        // An explicit empty array prevents an old system list from being
        // imported again after the user chooses Clear Menu.
        persist()
    }

    private func persist() {
        defaults.set(urls.map(\.path), forKey: Self.storageKey)
    }

    private static func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return Array(urls.filter { url in
            url.isFileURL && seen.insert(Repository.normalizedPath(url.path)).inserted
        }.prefix(maximumCount))
    }
}
