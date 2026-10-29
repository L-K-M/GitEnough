import Foundation

/// Repository snapshots and mutations share a queue even before a working copy
/// has an open window. The lock only protects queue lookup, never Git work.
final class RepositoryOperationQueues: @unchecked Sendable {
    static let shared = RepositoryOperationQueues()

    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]

    private init() {}

    func queue(for repo: Repository) -> DispatchQueue {
        let path = repo.normalizedPath
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[path] { return queue }
        let queue = DispatchQueue(label: "gitenough.repo.\(repo.name)", qos: .userInitiated)
        queues[path] = queue
        return queue
    }
}
