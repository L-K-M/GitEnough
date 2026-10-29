import Foundation

/// Matches loaded history without changing its topological order.
enum HistorySearch {
    static func filter(_ commits: [Commit], query: String) -> [Commit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commits }
        let hashPrefix = query.lowercased()

        return commits.filter {
            // Check the cheap hash prefix before localized text matching.
            $0.hash.lowercased().hasPrefix(hashPrefix)
                || $0.subject.localizedStandardContains(query)
                || $0.author.localizedStandardContains(query)
                || $0.email.localizedStandardContains(query)
                || $0.decorations.contains { $0.name.localizedStandardContains(query) }
        }
    }
}
