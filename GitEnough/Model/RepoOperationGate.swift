import Foundation

/// Main-thread admission state for repository mutations. The serial Git queue
/// prevents process overlap, while this gate prevents semantically conflicting
/// user actions from silently piling up on that queue.
struct RepoOperationGate {
    private(set) var activeID: UUID?

    var isActive: Bool { activeID != nil }

    mutating func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        activeID = id
        return id
    }

    /// Only the admitted operation may release the gate. A late/stale
    /// completion cannot make a newer operation appear idle.
    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}
