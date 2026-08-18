import Foundation

/// Scans a user-chosen "watch folder" for git repositories so they can be added
/// to the sidebar automatically (Settings → General → Repository discovery).
///
/// Walks directories breadth-first up to `maxDepth` levels below `root`, skipping
/// hidden folders, macOS user folders and package-manager build trees, and stops
/// at repository boundaries (a repo's submodules/nested trees are not separate
/// sidebar entries). Purely file-system based: a directory counts as a repository
/// when it contains a `.git` entry — a directory, or a file for linked worktrees.
/// No git invocation, so a scan is cheap enough to run every minute.
enum RepoDiscovery {

    /// Directory names never descended into (hidden folders are skipped wholesale).
    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", "vendor", "build", "Build", "dist", "out",
        "DerivedData", "Pods", "target", "Library", "Applications",
        "Movies", "Music", "Pictures", "Public",
    ]

    /// Finds repositories under `root`.
    ///
    /// - Parameter maxDepth: how many directory levels below `root` to examine.
    ///   2 covers `~/code` and `~/code/org` layouts.
    /// - Parameter maxVisitedDirectories: safety cap against pathological trees.
    static func findRepositories(in root: URL,
                                 maxDepth: Int = 2,
                                 maxVisitedDirectories: Int = 4000) -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        var visited = 0

        func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        func isRepository(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
        }

        /// Examines `directory`'s children (which live at `depth + 1`): each child
        /// is checked for being a repository, and non-repositories are descended
        /// into only while there are still levels left below `maxDepth`.
        func examine(_ directory: URL, depth: Int) {
            guard depth < maxDepth, visited < maxVisitedDirectories else { return }
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isDirectory(child) else { continue }
                visited += 1
                guard visited < maxVisitedDirectories else { return }
                if isRepository(child) {
                    // Repository boundary: record it, don't descend (submodules).
                    found.append(child)
                } else {
                    let name = child.lastPathComponent
                    // Defensive: skipsHiddenFiles already excludes dot-dirs.
                    guard !name.hasPrefix("."), !skippedDirectoryNames.contains(name) else { continue }
                    examine(child, depth: depth + 1)
                }
            }
        }

        guard isDirectory(root) else { return [] }
        // The watch folder itself may be a repository — count it, and still
        // examine its children so sibling repositories aren't missed.
        if isRepository(root) { found.append(root) }
        examine(root, depth: 0)
        return found
    }
}
