import Foundation

/// Case- and diacritic-insensitive matching for the History tab's search field.
/// Pure so the matcher is exhaustively unit-tested; the view only feeds it the
/// query and the loaded commits.
enum HistorySearch {

    /// A commit matches when the query matches its subject, author name, email,
    /// hash (or any prefix of it), or any decoration name (branch, remote
    /// branch, tag). An empty or whitespace-only query matches everything.
    static func matches(_ commit: Commit, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return fields(commit).contains { $0.localizedStandardContains(trimmed) }
    }

    /// The commits matching `query`, in their original (newest-first) order.
    static func filter(_ commits: [Commit], query: String) -> [Commit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commits }
        return commits.filter { matches($0, query: trimmed) }
    }

    private static func fields(_ commit: Commit) -> [String] {
        var fields = [commit.subject, commit.author, commit.email, commit.hash]
        fields.append(contentsOf: commit.decorations.map(\.name))
        return fields
    }
}
