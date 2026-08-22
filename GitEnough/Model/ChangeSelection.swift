/// The selected row in the Changes tab.
///
/// A partially staged path appears in both sections. Its side is part of the
/// identity because the two rows intentionally request different patches.
struct ChangeSelection: Equatable {
    let file: FileChange
    let isStaged: Bool

    /// Follows a file when staging moves it between sections, preserves the
    /// chosen side while both exist, and clears a path that disappeared.
    func updated(for status: RepoStatus) -> ChangeSelection? {
        let staged = status.staged.first { $0.path == file.path }
        let unstaged = status.unstaged.first { $0.path == file.path }
        switch (staged, unstaged) {
        case (nil, nil):
            return nil
        case (nil, let unstaged?):
            return ChangeSelection(file: unstaged, isStaged: false)
        case (let staged?, nil):
            return ChangeSelection(file: staged, isStaged: true)
        case (let staged?, let unstaged?):
            return ChangeSelection(file: isStaged ? staged : unstaged,
                                   isStaged: isStaged)
        }
    }
}
