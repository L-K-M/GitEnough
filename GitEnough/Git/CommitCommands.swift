import Foundation

/// Pure builders for the shell commands the history context menu puts on the
/// pasteboard — unit-tested, since the user pastes these straight into a
/// terminal.
enum CommitCommands {

    /// The paste-ready `git cherry-pick '<hash>'` command, or nil for a hash
    /// that isn't clean ASCII hex. `%H` can't produce anything else, but the
    /// shell-safety invariant is enforced here rather than assumed from the
    /// parser: trimmed, hex-validated (ASCII-strict — isHexDigit alone also
    /// accepts fullwidth variants), and single-quoted.
    static func cherryPickCommand(forHash rawHash: String) -> String? {
        let hash = rawHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "git cherry-pick '\(hash)'"
    }
}
