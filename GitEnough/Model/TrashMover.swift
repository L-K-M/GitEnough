import Foundation

/// Moves repository-relative paths to the Trash while preserving partial success.
///
/// Each item is attempted even when an earlier move fails. Any failures are
/// reported together after the final attempt so callers can refresh from disk
/// and display the repository's actual resulting state.
enum TrashMover {
    struct Failure: Equatable {
        let path: String
        let reason: String
    }

    struct MoveError: Error, LocalizedError, Equatable {
        let failures: [Failure]

        var errorDescription: String? {
            if failures.count == 1, let failure = failures.first {
                return "Couldn’t move \(quoted(failure.path)) to the Trash: \(failure.reason)"
            }

            let details = failures
                .map { "• \(quoted($0.path)): \($0.reason)" }
                .joined(separator: "\n")
            return "Couldn’t move \(failures.count) items to the Trash:\n\(details)"
        }

        private func quoted(_ path: String) -> String {
            "“\(path)”"
        }
    }

    static func move(paths: [String], from root: URL) throws {
        try move(paths: paths, from: root) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Injectable overload used by unit tests without invoking the platform
    /// Trash service.
    static func move(paths: [String],
                     from root: URL,
                     moveItem: (URL) throws -> Void) throws {
        var failures: [Failure] = []

        for path in paths {
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
