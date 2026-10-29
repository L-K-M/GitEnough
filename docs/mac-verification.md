# Mac interface verification

Target: macOS 26 Tahoe, Xcode 26 or newer. No third-party dependencies,
new document format, preferences migration, or older-release appearance path.

References: Finder for independent windows, opening folders and list selection;
Xcode for source-control navigation, a resizable inspector and selection commands;
Apple's [Mac Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
and [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).
System toolbars, sidebars, sheets and popovers provide the material. Reading
surfaces keep semantic opaque backgrounds.

## Build and automated checks

Use the numbered commands in the README from a fresh checkout. The direct Xcode
build needs no `lkm-build` installation. CI and release jobs use macOS 26 and
Xcode 26.0.1, independently of the developer machine's newer SDK.

New app-target regression coverage checks independent window navigation over
one shared repository model/operation queue, restoring normalized registered
paths, nondestructive sidebar removal, independent commit and file reads,
stale read rejection, queued read cancellation, and read-error recovery.
The shared core suite checks Git parsers, index/worktree handling, merge and
rebase recovery, draft preservation, operation gates, ignore/discard safety,
branches, stashes, forge URL handling, and activity history.

## Running-app checks

The original app was built and inspected before editing. Repeated Debug builds
were launched and inspected through the native macOS UI on macOS 27.0.1 with
Xcode 27.1. Disposable local repositories named Atlas and Harbor, and a local
bare remote, were used for all mutation checks; existing working copies were
only displayed.

- Open an existing repository using Command-O, the attached folder panel and
  Go to Folder; open a second working copy in a new Command-N window.
- Keep Atlas in Changes while Harbor is in Branches; closing one window keeps
  the other window's repository and mode. Repository menu commands disable
  while Settings is the active window.
- Clone a `file://` Git remote in its dedicated sheet: choose the parent folder,
  press Return, and verify the new working copy opens with its history and
  tracking branch. URL editing has initial focus; Clone is the default button.
- Select staged/unstaged files and stage/unstage with Option-Command-S/U;
  the selected path follows the file between lists and the diff's side label
  changes with it. The commit command uses the same safety gate from its button
  and menu.
- Edit a commit draft, use Edit > Undo and Redo, quit and relaunch, and verify
  the draft survives. A deliberately failing pre-commit hook displays its
  error while preserving both draft and staged content; removing that fixture
  hook and committing succeeds and clears the draft only on success.
- Create and check out a branch with Shift-Command-B and Return, then check out
  an existing selected branch through the Branch menu. Existing context actions
  remain available, including the force-delete and merge choices.
- Search history with Command-F (repeating it selects the existing query),
  clear with Escape, and use Tab and arrow keys
  to select commits and update details. Toggle the inspector with
  Option-Command-I. Parent navigation and file selection retain the same Git
  read ordering as mutations.
- Fetch an incoming commit from a local bare remote and pull it through the
  toolbar; commit a staged change and push through the split toolbar button.
  Verify the pushed subject directly at the remote. Stash an untracked note
  using the menu and Include untracked files, then Pop through the selected
  stash footer; verify its contents are unchanged.
- Switch History/Changes/Branches repeatedly and verify the sidebar and
  mode-selector positions stay fixed; the selector has no extra shared glass
  background. Resize the repository sidebar through its native divider.
- Use the repository state filter and its visible “show all” recovery link;
  Shift-Command-F focuses repository search. The filter/sort controls are now
  next to the repository list.
- Enter fullscreen using the window control and leave it using View > Exit
  Full Screen. Toolbar, sidebar and branch controls remain reachable.
- Close the last window and verify the app process remains running; reopening
  the app creates a workspace. The standard Settings tabs fit their forms;
  visiting AI Settings makes no provider request.

## Capability and data preservation

All existing commands retain a surface: local open/clone/drop/discovery;
repository stars, sorting and filters; history graph/search/pagination and
parent navigation; copying hash/subject/path/cherry-pick command; branch/tag
creation, detached checkout, cherry-pick/revert and all reset modes;
staging/unstaging/ignore/discard/Trash, amend and generated messages;
local/remote branches, merge/rename/delete and stash operations;
fetch/pull/push/publish/force-with-lease and pull requests;
conflict tools, ours/theirs/mark-resolved and sequencer continue/abort/skip;
all Settings and persistent Git Activity controls.

Repository contents and Git's on-disk formats are unchanged. Opening, browsing,
window switching and quitting do not save or transform working-tree files.
Staging and commits remain explicit Git operations. Harbor's existing staged,
unstaged and untracked files and index status were compared after browsing,
branch creation/checkout, switching windows and relaunch; all were unchanged. Existing repository lists,
stars, discovery exclusions, preferences, drafts, activity JSONL and Keychain
entries keep their existing keys and locations. There is no Save/Save As
lifecycle for a repository folder; commit drafts autosave separately.

## Limits

- The local GUI host runs macOS 27; Tahoe compilation and tests are delegated
  to the macOS 26 CI job. No macOS 27 API is intentionally used.
- Live AI generation and authenticated hosted remotes were not exercised in
  the GUI. Their existing core behavior and credential handling are retained.
- Clone is asynchronous but the existing Git process runner has no cancellation
  handle. Its sheet remains open until completion or an error.
- Native text undo is verified. Git operations use explicit Git recovery
  commands and confirmations; generated-message replacement has no separately
  named Undo operation.
- SceneStorage restores window state when macOS restores a scene; a new window
  otherwise opens the last-used repository. Global Close windows when quitting
  preferences remain under the user's control.
- VoiceOver speech and the full matrix of increased contrast, reduced
  transparency and reduced motion settings were not manually exercised.

## Preference-test incident

The initial hosted run exposed an existing `RepoStoreTests` isolation bug: it
cleared the production sidebar preference keys. The observed 31 repository
entries, their order, empty stars/exclusions, and original selection were
restored; you confirmed that no repositories had been excluded. Previous
recent-order timestamps could not be recovered. Git working copies and Git
history were unaffected. Those tests now use per-test UUID preference suites,
with a cross-suite preservation regression. App-state tests also inject
temporary activity files. Subsequent hosted runs are checked against a backup
of the production sidebar preferences.
