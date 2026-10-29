import Foundation

public struct GitCancellationError: Error, LocalizedError {
    public let retainedDirectory: URL?
    private let preservesExistingDirectory: Bool

    public init(retainedDirectory: URL? = nil) {
        self.retainedDirectory = retainedDirectory
        preservesExistingDirectory = false
    }

    public init(preservingExistingDirectory directory: URL) {
        retainedDirectory = directory
        preservesExistingDirectory = true
    }

    public var errorDescription: String? {
        if let retainedDirectory {
            if preservesExistingDirectory {
                return "Cloning was cancelled. Files in the existing folder at \(retainedDirectory.path) were kept. Review that folder or choose another destination before trying again."
            }
            return "Cloning was cancelled. A partial clone remains at \(retainedDirectory.path). You can remove that folder in Finder."
        }
        return "The Git operation was cancelled."
    }
}

/// One operation's cancellation request. Cancellation can arrive before launch,
/// while git runs, or between process exit and publishing the completed clone.
public final class GitCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var handlers: [UUID: () -> Void] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        guard !completed, !cancelled else { lock.unlock(); return }
        cancelled = true
        let callbacks = Array(handlers.values)
        lock.unlock()
        for callback in callbacks { callback() }
    }

    func checkCancellation() throws {
        if isCancelled { throw GitCancellationError() }
    }

    func register(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let shouldCancel = cancelled
        if !cancelled && !completed { handlers[id] = handler }
        lock.unlock()
        if shouldCancel { handler() }
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    /// Publishing a complete working copy is the final, non-cancellable step.
    /// A late click after this point must not report a successful clone as lost.
    func beginCompletion() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw GitCancellationError() }
        completed = true
    }
}
