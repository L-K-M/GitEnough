import Foundation

/// Moves repository-relative paths to the Trash while preserving partial success.
///
/// Each item is attempted even when an earlier move fails. Any failures are
/// reported together after the final attempt so callers can refresh from disk
/// and display the repository's actual resulting state.
public enum TrashMover {
    public struct Failure: Equatable {
        public let path: String
        public let reason: String
    }

    public struct MoveError: Error, LocalizedError, Equatable {
        public let failures: [Failure]

        public var errorDescription: String? {
            if failures.count == 1, let failure = failures.first {
                return "Couldn’t move \(quoted(failure.path)) to the Trash: \(failure.reason)"
            }

            let details = failures.prefix(5)
                .map { "• \(quoted($0.path)): \($0.reason)" }
                .joined(separator: "\n")
            let omittedCount = failures.count - min(failures.count, 5)
            let suffix = omittedCount > 0 ? "\n…and \(omittedCount) more" : ""
            return "Couldn’t move \(failures.count) items to the Trash:\n\(details)\(suffix)"
        }

        private func quoted(_ path: String) -> String {
            "“\(path)”"
        }
    }

    public static func move(paths: [String], from root: URL) throws {
        try move(paths: paths, from: root) { url in
            try Platform.moveToTrash(url)
        }
    }

    /// Injectable overload used by unit tests without invoking the platform
    /// Trash service.
    public static func move(paths: [String],
                     from root: URL,
                     moveItem: (URL) throws -> Void) throws {
        var failures: [Failure] = []

        for path in paths {
            let components = path.components(separatedBy: "/")
            guard !path.hasPrefix("/"), !components.contains("..") else {
                failures.append(Failure(path: path,
                                        reason: "Path escapes the repository root"))
                continue
            }

            do {
                try moveItem(root.appendingPathComponent(path))
            } catch {
                failures.append(Failure(path: path, reason: error.localizedDescription))
            }
        }

        if !failures.isEmpty {
            throw MoveError(failures: failures)
        }
    }
}
