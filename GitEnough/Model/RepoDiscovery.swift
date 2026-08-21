import Foundation

/// Scans a user-chosen "watch folder" for git repositories so they can be added
/// to the sidebar automatically (Settings → General → Repository discovery).
///
/// Walks directories depth-first up to `maxDepth` levels below `root`, skipping
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

        /// True when `url` is a working-copy repository the sidebar can actually
        /// open — a `.git` entry that is either a directory (with `core.bare`
        /// unset) or a linked-worktree gitdir file. A **bare** repository (no
        /// worktree) and a **submodule** (a `.git` file pointing into the
        /// parent's `modules/` store) both have a `.git` entry but can't be
        /// opened as repositories: the first has no files to show, the second
        /// is already covered by its parent's entry. Both used to be added to
        /// the sidebar and then sit there as dead "not a git repository" rows.
        func isUsableRepository(_ url: URL) -> Bool {
            let gitEntry = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory)
            guard exists else { return false }
            if isDirectory.boolValue {
                // A bare repo's `.git` is the repo itself; the config tells us.
                let configURL = gitEntry.appendingPathComponent("config")
                if let config = try? String(contentsOf: configURL, encoding: .utf8),
                   isBare(config) { return false }
            } else {
                // A `.git` file: linked worktrees point at a real worktree;
                // submodules point into the parent repo's modules store.
                if let gitdir = try? String(contentsOf: gitEntry, encoding: .utf8),
                   gitdir.contains("/.git/modules/") { return false }
            }
            return true
        }

        /// A cheap textual `core.bare` check on a git config file — discovery
        /// must never spawn git. Git writes this as `bare = true` under `[core]`;
        /// a false positive here only means the repo is offered in the sidebar
        /// where git itself will mark it invalid, never data loss.
        func isBare(_ config: String) -> Bool {
            var inCoreSection = false
            for rawLine in config.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    inCoreSection = line.lowercased().hasPrefix("[core")
                } else if inCoreSection, line.lowercased().hasPrefix("bare") {
                    return line.components(separatedBy: "=").dropFirst().joined(separator: "=")
                        .trimmingCharacters(in: .whitespaces).lowercased() == "true"
                }
            }
            return false
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
                if isUsableRepository(child) {
                    // Repository boundary: record it (canonicalized, so a
                    // symlinked watch folder can't produce duplicate sidebar
                    // entries next to git's own physically-resolved paths), and
                    // don't descend (submodules).
                    found.append(child.resolvingSymlinksInPath())
                } else if fileManager.fileExists(atPath: child.appendingPathComponent(".git").path) {
                    // Has a `.git` entry but isn't a usable repository (bare or
                    // submodule): still a boundary — don't descend into its
                    // internals looking for more repositories.
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
        if isUsableRepository(root) { found.append(root.resolvingSymlinksInPath()) }
        examine(root, depth: 0)
        return found
    }
}
