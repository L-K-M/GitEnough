import Foundation

/// Pure parsers for git command output. Everything here is deterministic and free of
/// side effects so it can be exhaustively unit-tested (see GitEnoughTests).
enum GitParsers {

    // Field/record separators used by the custom --pretty formats in GitClient.
    static let fieldSep = "\u{1F}"
    static let recordSep = "\u{1E}"

    private static let iso = ISO8601DateFormatter()

    static func parseDate(_ raw: String) -> Date? {
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    // MARK: - git log

    /// Parses records of `%H %P %an %ae %aI %D %s` joined by \x1F, separated by \x1E.
    static func parseLog(_ output: String) -> [Commit] {
        var commits: [Commit] = []
        for record in output.components(separatedBy: recordSep) {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.components(separatedBy: fieldSep)
            guard fields.count >= 7 else { continue }
            let hash = fields[0]
            let parents = fields[1].split(separator: " ").map(String.init)
            commits.append(Commit(
                hash: hash,
                parents: parents,
                author: fields[2],
                email: fields[3],
                date: parseDate(fields[4]),
                subject: fields[6],
                decorations: parseDecorations(fields[5])
            ))
        }
        return commits
    }

    /// Parses `%D` output: "HEAD -> main, origin/main, tag: v1.0".
    static func parseDecorations(_ raw: String) -> [RefDecoration] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var decorations: [RefDecoration] = []
        for part in trimmed.components(separatedBy: ", ") {
            if part.hasPrefix("HEAD -> ") {
                decorations.append(RefDecoration(kind: .head, name: "HEAD"))
                let branch = String(part.dropFirst("HEAD -> ".count))
                decorations.append(RefDecoration(kind: .localBranch, name: branch))
            } else if part == "HEAD" {
                decorations.append(RefDecoration(kind: .head, name: "HEAD"))
            } else if part.hasPrefix("tag: ") {
                decorations.append(RefDecoration(kind: .tag, name: String(part.dropFirst(5))))
            } else if part.contains("/") {
                decorations.append(RefDecoration(kind: .remoteBranch, name: part))
            } else {
                decorations.append(RefDecoration(kind: .localBranch, name: part))
            }
        }
        return decorations
    }

    // MARK: - git status --porcelain=v2 --branch

    static func parseStatus(_ output: String) -> RepoStatus {
        var status = RepoStatus()
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("# branch.oid ") {
                status.headHash = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.head = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let ab = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in ab {
                    if part.hasPrefix("+"), let value = Int(part.dropFirst()) { status.ahead = value }
                    if part.hasPrefix("-"), let value = Int(part.dropFirst()) { status.behind = value }
                }
            } else if line.hasPrefix("1 ") {
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let fields = splitLimit(line, maxSplits: 8)
                guard fields.count == 9 else { continue }
                apply(change: makeChange(path: fields[8], originalPath: nil, xy: fields[1]),
                      to: &status)
            } else if line.hasPrefix("2 ") {
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><TAB><origPath>
                let fields = splitLimit(line, maxSplits: 9)
                guard fields.count == 10 else { continue }
                let paths = fields[9].components(separatedBy: "\t")
                let path = unquoteGitPath(paths[0])
                let original = paths.count > 1 ? unquoteGitPath(paths[1]) : nil
                apply(change: makeChange(path: path, originalPath: original, xy: fields[1]),
                      to: &status)
            } else if line.hasPrefix("u ") {
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let fields = splitLimit(line, maxSplits: 10)
                guard fields.count == 11 else { continue }
                let change = FileChange(path: unquoteGitPath(fields[10]),
                                        originalPath: nil,
                                        stagedStatus: .unmerged,
                                        unstagedStatus: .unmerged)
                status.conflicted.append(change)
            } else if line.hasPrefix("? ") {
                let change = FileChange(path: unquoteGitPath(String(line.dropFirst(2))),
                                        originalPath: nil,
                                        stagedStatus: nil,
                                        unstagedStatus: .untracked)
                status.unstaged.append(change)
            }
            // "! <path>" (ignored) is intentionally skipped; we pass --untracked-files=normal
            // but never --ignored.
        }
        return status
    }

    /// Splitting that preserves a path containing spaces in the last field:
    /// splits on single spaces at most `maxSplits` times.
    private static func splitLimit(_ line: String, maxSplits: Int) -> [String] {
        var fields: [String] = []
        var rest = Substring(line)
        while fields.count < maxSplits, let space = rest.firstIndex(of: " ") {
            fields.append(String(rest[..<space]))
            rest = rest[rest.index(after: space)...]
        }
        fields.append(String(rest))
        return fields
    }

    private static func makeChange(path: String, originalPath: String?, xy: String) -> FileChange {
        let chars = Array(xy)
        let x = chars.count > 0 ? chars[0] : "."
        let y = chars.count > 1 ? chars[1] : "."
        return FileChange(path: unquoteGitPath(path),
                          originalPath: originalPath,
                          stagedStatus: FileChange.Status(rawValue: String(x)),
                          unstagedStatus: FileChange.Status(rawValue: String(y)))
    }

    private static func apply(change: FileChange, to status: inout RepoStatus) {
        if change.stagedStatus != nil { status.staged.append(change) }
        if change.unstagedStatus != nil { status.unstaged.append(change) }
    }

    // MARK: - git for-each-ref

    /// Parses lines of `%(refname) \x1F %(refname:short) \x1F %(upstream) \x1F
    /// %(upstream:track) \x1F %(HEAD)`.
    static func parseBranches(_ output: String) -> [Branch] {
        var branches: [Branch] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let fields = line.components(separatedBy: fieldSep)
            guard fields.count >= 5 else { continue }
            let refname = fields[0]
            let isRemote = refname.hasPrefix("refs/remotes/")
            guard refname.hasPrefix("refs/heads/") || isRemote else { continue }
            let name = branchDisplayName(for: refname)
            // Skip the remote HEAD symref (e.g. "origin/HEAD") — it's not a real branch.
            if isRemote && name.hasSuffix("/HEAD") { continue }
            var ahead = 0, behind = 0
            let track = fields[3]
            if track.hasPrefix("[") && track.hasSuffix("]") {
                for part in track.dropFirst().dropLast().components(separatedBy: ", ") {
                    if part.hasPrefix("ahead ") { ahead = Int(part.dropFirst(6)) ?? 0 }
                    if part.hasPrefix("behind ") { behind = Int(part.dropFirst(7)) ?? 0 }
                }
            }
            branches.append(Branch(
                name: name,
                refName: refname,
                isRemote: isRemote,
                isHead: fields[4] == "*",
                upstream: fields[2].isEmpty ? nil : branchDisplayName(for: fields[2]),
                ahead: ahead,
                behind: behind
            ))
        }
        return branches
    }

    /// Strips only a namespace that identifies a branch. Unlike
    /// `%(refname:short)`, this cannot grow an ambiguous `heads/` prefix merely
    /// because a tag happens to use the same display name.
    private static func branchDisplayName(for refname: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where refname.hasPrefix(prefix) {
            return String(refname.dropFirst(prefix.count))
        }
        // Tolerate the older short-upstream fixture format.
        return refname
    }

    // MARK: - git remote -v

    static func parseRemotes(_ output: String) -> [Remote] {
        var seen = Set<String>()
        var remotes: [Remote] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            // "origin\thttps://github.com/L-K-M/GitEnough.git (fetch)"
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { continue }
            let name = parts[0]
            guard !seen.contains(name) else { continue }
            let url = parts[1]
                .replacingOccurrences(of: " (fetch)", with: "")
                .replacingOccurrences(of: " (push)", with: "")
            seen.insert(name)
            remotes.append(Remote(name: name, url: url))
        }
        return remotes
    }

    // MARK: - git stash list --format=%gd%x1F%gs

    static func parseStash(_ output: String) -> [StashEntry] {
        var entries: [StashEntry] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let fields = line.components(separatedBy: fieldSep)
            guard fields.count >= 2 else { continue }
            // %gd → "stash@{0}"; %gs → "WIP on main: abc123 subject"
            guard let index = Int(fields[0]
                    .replacingOccurrences(of: "stash@{", with: "")
                    .replacingOccurrences(of: "}", with: "")) else { continue }
            // %gs is either "WIP on <branch>: <hash> <subject>" (no -m given) or
            // "On <branch>: <message>" (custom message given).
            var branch = ""
            var message = fields[1]
            var isWIP = false
            var rest: String?
            if message.hasPrefix("WIP on ") {
                rest = String(message.dropFirst("WIP on ".count))
                isWIP = true
            } else if message.hasPrefix("On ") {
                rest = String(message.dropFirst("On ".count))
            }
            if let rest, let colon = rest.firstIndex(of: ":") {
                branch = String(rest[..<colon])
                message = String(rest[rest.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if isWIP {
                    // Drop the leading short hash the WIP subject embeds ("abc123 subject").
                    let pieces = message.split(separator: " ", maxSplits: 1)
                    if pieces.count == 2 { message = String(pieces[1]) }
                }
            }
            entries.append(StashEntry(index: index, branch: branch, message: message))
        }
        return entries
    }

    // MARK: - git diff-tree --name-status

    /// Parses `A\tpath` / `M\tpath` / `R100\told\tnew` lines.
    static func parseNameStatus(_ output: String) -> [CommitFile] {
        var files: [CommitFile] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let fields = line.components(separatedBy: "\t")
            guard let first = fields.first, let letter = first.first else { continue }
            let status = FileChange.Status(rawValue: String(letter)) ?? .modified
            if status == .renamed || status == .copied {
                guard fields.count >= 3 else { continue }
                files.append(CommitFile(status: status,
                                        path: unquoteGitPath(fields[2]),
                                        originalPath: unquoteGitPath(fields[1])))
            } else {
                guard fields.count >= 2 else { continue }
                files.append(CommitFile(status: status,
                                        path: unquoteGitPath(fields[1]),
                                        originalPath: nil))
            }
        }
        return files
    }

    // MARK: - git show (commit detail header)

    /// Parses `%H %an %ae %aI %P %s %b` (fields joined by \x1F, %b last, record ended
    /// by \x1E) followed by the --name-status block.
    static func parseCommitDetail(_ output: String) -> CommitDetail? {
        guard let recordEnd = output.firstIndex(of: Character(recordSep)) else { return nil }
        let header = output[..<recordEnd]
        let rest = output[output.index(after: recordEnd)...]
        let fields = header.components(separatedBy: fieldSep)
        guard fields.count >= 7 else { return nil }
        return CommitDetail(
            hash: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
            author: fields[1],
            email: fields[2],
            date: parseDate(fields[3]),
            parents: fields[4].split(separator: " ").map(String.init),
            subject: fields[5].trimmingCharacters(in: .whitespacesAndNewlines),
            body: fields[6].trimmingCharacters(in: .whitespacesAndNewlines),
            files: parseNameStatus(String(rest))
        )
    }

    // MARK: - C-quoted paths

    /// git wraps paths containing quotes, backslashes, or bytes outside plain
    /// printable ASCII in double quotes with C-style escapes — with the default
    /// `core.quotepath=true` that includes every non-ASCII path ("ä" becomes
    /// "\303\244"). Works on raw UTF-8 bytes and decodes at the end, so
    /// multi-byte sequences survive intact. Unquoted paths pass through unchanged.
    static func unquoteGitPath(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return raw }
        let utf8 = Array(raw.dropFirst().dropLast().utf8)
        let backslash: UInt8 = 0x5C
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8.count)
        var i = 0
        while i < utf8.count {
            let byte = utf8[i]
            if byte != backslash {
                bytes.append(byte)
                i += 1
                continue
            }
            guard i + 1 < utf8.count else { break }
            let escaped = utf8[i + 1]
            switch escaped {
            case 0x6E: bytes.append(0x0A); i += 2   // \n
            case 0x74: bytes.append(0x09); i += 2   // \t
            case 0x72: bytes.append(0x0D); i += 2   // \r
            case 0x5C: bytes.append(0x5C); i += 2   // \\
            case 0x22: bytes.append(0x22); i += 2   // \"
            case 0x27: bytes.append(0x27); i += 2   // \'
            case 0x61: bytes.append(0x07); i += 2   // \a
            case 0x62: bytes.append(0x08); i += 2   // \b
            case 0x66: bytes.append(0x0C); i += 2   // \f
            case 0x76: bytes.append(0x0B); i += 2   // \v
            case 0x30...0x37:
                // git emits octal escapes as exactly three digits (\ooo).
                if i + 3 < utf8.count,
                   (0x30...0x37).contains(utf8[i + 2]),
                   (0x30...0x37).contains(utf8[i + 3]) {
                    let value = Int(escaped - 0x30) * 64
                        + Int(utf8[i + 2] - 0x30) * 8
                        + Int(utf8[i + 3] - 0x30)
                    bytes.append(UInt8(truncatingIfNeeded: value))
                    i += 4
                } else {
                    bytes.append(escaped)
                    i += 2
                }
            default:
                bytes.append(escaped)
                i += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
