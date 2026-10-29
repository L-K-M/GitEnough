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
- Open Foldover through the folder panel, then choose it from File > Open
  Recent in the same running build; verify its repository and history open.
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

## Context-menu regression

The original inconsistency was reproduced before the fix. These checks then
passed in the corrected running build using a disposable conflicted repository.

1. Use a disposable repository with two local branches, a remote branch without
   a matching local branch, and an existing stash entry.
2. Start a conflicting merge and leave it in progress. Open Branches and inspect
   the local and remote branch context menus: Check Out and Merge remain visible
   but disabled, matching the Branch menu and selected-branch footer.
3. Double-click another local branch. Verify the current branch and in-progress
   merge are unchanged.
4. Inspect the stash context menu: Apply, Pop and Drop remain visible but
   disabled, matching the Branch menu and selected-stash footer.
5. Abort the fixture merge. Verify the applicable branch and stash actions are
   enabled again and the stash contents remain unchanged.

The current branch, HEAD, merge head and stash patch were compared after the
double-click check; none changed. Aborting through the app restored the clean
working tree and preserved the stash. The review fixture was removed from the
sidebar afterward.

## Review decisions

The first completed automated review found no confirmed important defects.
The context-menu consistency issue and stale Xcode version in the CI guide
were corrected. Restoration uses the synchronously loaded repository list;
repository-add completions and window subscriptions already run on main.
Opening Clone and inspecting File verified that Open and Clone are disabled
while its sheet is key. Native NSSearchField clearing and native List selection
replace the removed custom controls. The suggestion to restore fixed 11-point
diff text conflicts with the requested readable system typography, so the
semantic monospaced style is retained. Other minor defensive and naming
suggestions are deferred.

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
- Clones now support Cancel/Escape and safe retry for new destinations. An
  existing empty destination is cloned in place; cancellation preserves any
  partial or concurrently added content and asks the user to review that folder.
- Generated-message replacements now use the initiating native text editor's
  named Undo/Redo history. Git operations continue to use explicit recovery
  commands and confirmations.
- SceneStorage restores window state when macOS restores a scene; a new window
  otherwise opens the last-used repository. Global Close windows when quitting
  preferences remain under the user's control.
- macOS can clear its shared-file list when development signatures change. The
  app now maintains its own recent paths alongside the system list, and Clear
  Menu clears both. Persistence, deduplication and clearing have isolated tests.
- VoiceOver speech and the full matrix of increased contrast, reduced
  transparency and reduced motion settings were not manually exercised.

## Follow-up checks

The follow-up adds automatic and manual repository groups, clone cancellation,
native generated-message undo, durable recent paths, one history-list width
measurement and source-warning cleanup. Automated coverage includes account
matching across forges, stable namespaces, safe clone cancellation, draft
replacement and isolated persistence. Hosted tests use a separate app identity.
Native editor tests exercise named undo/redo, standard key equivalents, later
typing, separate editor stacks and marked input. Grouping/store tests use UUID
preference suites; Git cancellation tests use disposable local transports.
Running-app verification uses a separate bundle identifier, preferences,
Keychain service and activity directory, with a loopback model stub. The normal
app's activity directory and existing preferences retain their paths.

Running-app clone checks passed with a local SSH transport deliberately waiting
for 30 seconds and ignoring TERM. Both Cancel Clone and Escape stopped the
transport and its sleep child, removed private staging and re-enabled the same
form. Retrying at the same destination succeeded. Existing empty folders and a
symlink destination cloned successfully; a nonempty destination was refused
without changing its user file. A file added concurrently during an existing-
folder clone survived cancellation, and the status correctly requested review
rather than promising an immediate retry. Physical directory identities and
cloned README bytes were compared after these checks.

Three recent clone paths remained available after rebuilding and changing the
development signature. Duplicate repository names now include their parent path
in Open Recent. Selecting the intended duplicate opened its correct working copy;
Clear Menu then emptied the menu and disabled its clear command.

The production preference export was compared after the isolated hosted run:
all 31 registrations and their order, stars, exclusions and original selection
were unchanged. Fixture activity entries were absent from production diagnostics.
The running app displayed Undo Generate Commit Message and Redo Generate Commit
Message, with working standard shortcuts. Later typing undid before generation;
a newer shared draft disabled another window's stale undo; a delayed response
kept newer typed text. Search and Settings retained their own native editing
undo. Command-Return committed from the native composer, cleared the successful
draft and left the disabled commit command inert. Tab and Shift-Tab moved out of
and back into the composer without inserting tabs.

A final focus check found that a parent window retains its text responder while
a sheet owns input. The composer now relinquishes its focused-scene command
object during key-window and sheet transitions, with a live action guard as
well. Regression tests cover retained responders and the sheet-begin notification
arriving before attachment. In the running app, Clone URL and Stash message Undo
changed only their own fields; dismissal restored composer Undo/Redo. Search and
Settings retained native Undo, and the background draft stayed unchanged.

Account mode combined Atlas, Harbor and Eclair's matching account namespace
under one header listing GitHub, GitLab and codeberg.org. Forge mode stayed
host-specific. Creating a manual group from an automatic account group switched
to and revealed the requested destination. Membership survived an app relaunch.

The long-name history fixture was inspected in compact and wide layouts. Subject,
ref, author and date columns stayed within their bounds, and the full accessible
metadata retained hidden ref names. Arrow selection and search worked, and the
system monospaced diff retained semantic colors and bold underlined changed
words. Browsing preserved the unstaged file bytes and Git index state.

## Follow-up review decisions

The first completed review contained no confirmed important defect. A runtime
Combine probe verified collection mutations emit publication, and the store loads
repositories before group assignments. Native disclosure navigation and manual
create/move/reload were exercised in the app. The replacement callback runs before
model publication and rejects a newer draft; both automated and running-app tests
cover that contract. Scene restoration runs in onAppear, not during body building.

Cancellation helpers are constructed only after successful process launch. Runtime
probes found PID zero before launch and the same positive PID after exit; Mac and
Linux transport tests verified process-group isolation and descendant cancellation.
The helper additionally refuses nonpositive/system PIDs and disarms after its first
signal. Only cloning currently supplies cancellation tokens, and late cancellation
after successful publication intentionally leaves success intact. Other minor
defensive suggestions are deferred; the readable system diff font is retained.

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
