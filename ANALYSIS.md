# GitEnough — Analysis & Backlog (ANALYSIS.md)

A living, shovel-ready backlog for GitEnough: every entry below is a concrete,
self-contained task with suggested approach and test plan, ready for an LLM (or
human) to pick up. This document consolidates four independent full-codebase
reviews (`glm.md`, `kimi.md`, `fable.md`, and `flash.md`, each kept unedited on
its review branch as the record) with everything learned while implementing the
first three waves of fixes.
**Maintenance rule:** when an entry ships, delete it here (the git history
preserves it); when a new issue is found, add it with the same level of
concreteness.

Effort: **S** ≤ ~30 min · **M** half a day · **L** multi-day.

---

## Status snapshot (do not re-implement)

Wave 1 (PRs #1–#35) is fully **merged**. Wave 2 from the fable review is
**open (reviewed, unmerged) as PRs** — check before starting anything
overlapping:

| PR | Covers |
|----|--------|
| #36 | Stale-diff resurrection race in selectFile/selectCommitFile (generation tokens) + loading spinner in the Changes diff pane |
| #37 | `Remote.displayHost` strips only a trailing `.git` (was mangling `user.github.io` and `.git`-containing hostnames) |
| #38 | `GitParsers.parseDate` formatter data race (configure-once) |
| #39 | Cherry-pick/revert merge commits via `--mainline` (per-parent menu items; 1-based precondition) |
| #40 | `[gone]` upstream parsed + "upstream gone" badge in Branches |
| #41 | Commit-detail load-failure state (kills the eternal spinner; real git error in the pane; superseded-load guard) |
| #42 | Unpushed-commit markers: hollow graph dots from `rev-list @{upstream}..HEAD` |
| #43 | Force Push (with lease) as a Push split-button + confirmation |
| #44 | Stash reachable with staged-only changes (button moved to a list footer, disabled mid-op/mid-merge) — flash review B-NEW-1 |
| #45 | Watch-folder discovery skips bare repos and submodules (`.git/modules/` + `core.bare` checks, pure FS) — flash review B-NEW-2 |
| #46 | Settings window sizes to content instead of clipping the AI tab — flash review B-NEW-3 |
| #47 | History filter matches branch/tag/remote ref names (cheapest predicate first) — flash review M-NEW-1 |
| #48 | `GitShell` synthesized failure message names the real subcommand (was "git -C failed…") — flash review B-NEW-4 |
| #49 | "New Branch…" button in the Branches tab's local-branches header — flash review M-NEW-5 |
| #50 | Squash / no-fast-forward merge options in the merge dialog |
| #51 | Error banner: expandable long output + copy button |
| #52 | Relative dates tick via per-minute TimelineView |
| #53 | Copy Name on branch rows; Copy Hash and Subject on commits; shared `NSPasteboard.copyString` |
| #54 | Per-repo commit-draft persistence (restore on launch, cleanup on repo removal, injectable defaults) |
| #55 | Empty states: zero-commit History, empty Remote Branches section |

Verified non-issues, kept for the record (don't re-audit):
- **Graph width never includes trailing free lanes** — every lane is either
  occupied (drawn to the last row) or was claimed by a node, so `columnCount`
  never exceeds `maxNodeColumn + 1`.
- **The GLM-review workflow's `pull_request_target` gate**
  (`.github/workflows/zai-code-review.yml`) correctly restricts the privileged
  job to same-repo branches.
- **TimelineView minute-boundary alignment** (suggested in #52's review) does
  not help: relative-date rollovers are anchored at each commit's own second,
  not wall-clock minutes, and the staleness bound is <60 s either way.

---

## Bugs & correctness

### F4 · Menu commands ignore the busy/remoteless state their comment claims — S
`AppCommands.swift` says "items are disabled when no repository is selected or
the model is busy", but every item only checks `active == nil`. ⇧⌘P with no
remote pushes into an error banner; shortcuts fire mid-operation and queue
duplicate network ops (mostly harmless thanks to the serial queue, but
inconsistent with the toolbar, which does disable). **Fix:** disable on
`isBusy`/`remotes.isEmpty` like the toolbar. Note SwiftUI `Commands` only
re-evaluate on observed changes — the VM's `isBusy` isn't observed by
`AppCommands`, so this needs the active VM's state published through
`appState` (or an `@ObservedObject` hop) to actually update.

### F5 · Untracked-file discard swallows Trash failures — S
`RepoViewModel.discard` wraps `trashItem` in `try?`. On volumes without a
Trash (network mounts, some external disks) the discard silently does
nothing — the row stays, no error. **Fix:** collect failures and set
`errorMessage` ("Couldn't move X to the Trash — …").

### F7 · Clone bypasses the activity log and can't be seen or cancelled — S/M
`GitClient.clone` is static and calls `GitShell.shared` directly, so the one
operation most likely to run for minutes never appears in the activity
log/status bar, has no progress, and no cancel. At minimum route it through an
activity-log-carrying client; real progress is M9/M12 territory.

### F8 · `--tags` on pull/fetch hard-fails when a remote moved a tag — S
`GitClient.pull` hardcodes `--tags` and `fetch` passes `--all --prune --tags`.
With `--tags`, a tag the remote re-pointed (nightly/`latest`-style tags are
routinely moved) makes git exit non-zero with `! [rejected] … (would clobber
existing tag)` — the whole Pull/Fetch surfaces as a failure banner even though
the branch update succeeded. Default tag-following (no flag) doesn't have this
failure mode. **Fix:** drop `--tags` from `pull` entirely and reconsider it on
`fetch` (or keep it and special-case the clobber message into a gentle notice).

### F12 · `refreshSummaries` can clobber fresher live summaries — S
`AppState.refreshSummaries` snapshots all repos, computes summaries on a
detached task, then **replaces the whole `store.summaries` dict**. A
`onStatusChange` live update (e.g. a commit finishing) that lands while the
pass is still running is overwritten by the pass's older data — the sidebar
dirty-dot can briefly resurrect. **Fix:** merge per-key instead of wholesale
assignment, or timestamp summaries and keep the newer one.

### B12 · Merge-tool concurrency guard is racy and over-strict — S
`RepoViewModel.openMergeTool` refuses a second tool while one is open, but the
`mergeToolActivity == nil` check isn't atomic (double-click race), and refusing
is unnecessary — FileMerge/Kaleidoscope happily open multiple windows.
**Fix:** track open tools in a `Set<String>` of paths (main-thread guarded),
drop the blanket refusal, keep one refresh per tool exit.

### F45 · Conflicted-file rows show no diff — S
`ConflictRow` in `ChangesView` offers Ours/Theirs/Merge Tool but selecting a
conflicted file shows nothing in the diff pane (`selectFile` only serves the
staged/unstaged lists). Facing 20 conflicted files, there is no way to even
*see* the conflict markers in-app before picking a side. **Fix:** make
`ConflictRow` selectable and serve the plain `git diff` output for the path
(the conflict diff already renders fine through `DiffView`); Q7's ghost
preview builds on the same path. (flash review B-NEW-10.)

### G8 · Detached-HEAD "Publish" semantics unclear — S
`push -u origin HEAD` in detached HEAD does something surprising (creates/uses a
remote branch literally derived from HEAD's state; git's behavior differs by
version). **Fix:** disable Publish while `status.isDetached`, tooltip explains;
optionally offer "Create branch at HEAD…" from the same menu.
Test: integration — bare remote + detached HEAD, assert the UI path is guarded
(unit-test the `canPublish` predicate).

### B15 · `/usr/bin/git` CLT stub can false-positive the availability check — S
Without the Xcode CLT, `/usr/bin/git` exists and is "executable" — it's a shim
that pops a GUI install dialog when invoked. `GitShell.findGit` treats it as
available, and the first real invocation may block on that dialog instead of
failing fast. **Fix:** probe with a short-timeout `git --version` at launch, or
at least document the limitation next to `findGit`.

### B16 · GPG pinentry can hang commits — S
`GIT_TERMINAL_PROMPT=0` does not suppress GPG's GUI pinentry, so users with
`commit.gpgsign=true` can see commits block until the dialog times out.
**Fix:** detect the hang class in the error path and surface a hint ("commit
signing prompted for a passphrase"), or a Settings troubleshooting note. Do NOT
silently disable signing (`-c commit.gpgsign=false` only behind a user toggle).

### P3 · `onChange(of: viewModel.commits.map(\.hash))` maps all hashes per render — S
`HistoryView` builds a full hash array on every body evaluation just to detect
"selection vanished", and `commitRows` re-materializes
`Array(visible.enumerated())` (300+ tuples) per pass. Fine at one page,
degrades after several "Load more"s. **Fix:** compare a cheap derived value
(count + first/last hash) in the `onChange`, and let `ForEach` iterate indices
directly. Note: while a filter is active, `visibleCommits` also re-runs the
full predicate over every loaded commit on *every* body evaluation — including
pure selection changes (each row tap). Memoize on `(activeFilter, commits)`.
(flash review P-NEW-2.)

### F46 · `DiffView.ParseCache` compares the whole diff string per render — S
The memoized parse (from #30) is keyed by `key == diff` — an O(n) equality
over up to 4 000 lines on every body evaluation (the parent re-renders on
every snapshot while the repo is dirty). Cheap relative to the parse it
avoids, but it is the hottest path in the app (2.5 s watcher × dirty repo).
**Fix:** key the cache on a hash, or have the view model publish a monotonically
increasing diff revision alongside the string. (flash review P-NEW-1.)

---

## Robustness / architecture

### G1 · No cancellation or timeout for git operations — M
`fetch`/`pull`/`push`/`clone` have no timeout; a fetch over a dead VPN blocks
the repo's serial queue for minutes — spinner spins, every op queues behind it,
no Cancel. **Fix (incremental):**
1. GitShell: keep a registry `processID → Process` for running ops; add
   `cancel(tag:)` that SIGTERMs (SIGKILL after grace).
2. RepoViewModel: tag network `perform`s, expose `cancelActive()`; toolbar
   spinner becomes a Cancel button while busy.
3. Optionally a default timeout (configurable) for network ops.
Tests: integration — spawn a `sleep`-style fake remote (a shell script remote
that hangs), assert cancel returns within a second and the queue drains.

### G2 · Unbounded background polling for every repo ever opened — M
`AppState.viewModels` keeps every `RepoViewModel` (and its 2.5 s `RepoWatcher`)
alive forever; 20 repos → 20 timers forever. Additionally each watcher runs its
signature stat calls on the VM's **git serial queue**, so a wedged git op also
stops change detection for that repo. **Fix:** pause watchers for repos that
aren't selected (resume on select/activation), or evict view models not
visited within a TTL (keep scroll cache cheap to rebuild); move the signature
polling off the repo queue while at it (pure stat calls don't need
serialization with git). Careful: the summary live-update wiring (main) must
survive eviction.

### G3 · Snapshot refresh runs 6 sequential process spawns — M
`collectSnapshot` = status → branches → remotes → stash → merge-state probes →
log, in sequence. All are read-only (`status` is `--no-optional-locks`).
**Fix:** run the cheap ones concurrently (TaskGroup, windowed), then history;
or coalesce — `for-each-ref` already yields what `remote -v` mostly gives.
Measure first on a big repo (flutter/flutter) — target: refresh < 300 ms warm.

### G5 · Watcher misses deep worktree edits (design note) — S/M
`RepoWatcher.signature` watches `.git` internals + worktree *root* mtime; edits
in subdirectories don't tick it (covered only by app activation). Options:
FSEvents-based watching (correct, more code), or a manual "Files changed
outside GitEnough" refresh affordance in the status bar. Decide deliberately;
document whichever trade-off ships.

### G6 · No RepoStoreTests — S
`AGENTS.md` promises `RepoStoreTests` ("removal sticks") but only
`RepoDiscoveryTests` exists. Add `GitEnoughTests/RepoStoreTests.swift`:
persistence round-trip, exclusion contract (remove → discovery can't resurrect →
manual register re-includes), `register` dedupe. Inject UserDefaults via a
suite (the store uses `.standard` directly today — consider an init parameter
while at it; #54 already introduced that pattern in `RepoViewModel`). Related
small item: `RepoStore` encodes the full repo list synchronously on the main
thread on every star/reorder/register — harmless at 20 repos, noticeable at
hundreds; fold a fix in here.

### G7 · Dead code: `GraphPalette.colorIndex(forLane:)` — S
Unused since layout switched to its own `nextColor` counter. Delete, or wire it
up if a lane-stable coloring is ever wanted (see A5 below for the useful version
of that idea).

### P2 · Full `--topo-order` log on every refresh; pagination restarts from zero — M/L
`git log --topo-order` walks essentially the whole history to order it, and
`loadMoreHistory` re-fetches `skip=0 … limit=n+1` and re-lays the entire graph
per page. **Fix:** cache commits between refreshes; when loading more, append
with `--skip=<loaded>` (commits are append-only in topo order for a stable ref
set — note the ref set CAN change, so validate head hashes before appending and
fall back to a full reload on mismatch). Consider `--topo-order` only for the
visible page. Test: GraphLayout equivalence of append-layout vs full layout
(the algorithm must produce identical lanes for a prefix-stable input; property
test with random DAGs).

### G9 · `RepoViewModel` is the riskiest untested code (+ small races) — M
The async/queue choreography has no tests, and three small issues compound it:
(1) `perform` sets `isBusy = false` when the *first* of two queued ops finishes
(spinner flicker — use an operation counter); (2) `Snapshot` reads the
main-thread `@Published canLoadMoreHistory` from the repo queue when
`includeHistory == false`, and `historyLimit` is likewise written on main
(`loadMoreHistory`) while `collectSnapshot` reads it on the queue (benign Int
races — capture locally); (3) `AppState.viewModel(for:)` is called inside
`ContentView.body` and from menu evaluation, so VMs are created and git work
starts as a view-body side effect (derive a `selectedViewModel` from
`selectedRepository` + explicit start).
**Fix:** introduce a test seam (injectable `GitShell`/`GitClient`) and cover the
perform → snapshot → apply contract, then fix 1–3 with tests watching them.
The seam also unblocks the state-machine cleanup suggested in #41's review
(collapse `selectedCommitDetail`/`…Failed`/`…ErrorMessage` into one
load-state enum) and view-model tests for #36/#41's generation guards.
Also: consolidate duplicated formatting helpers (`RelativeDateText`,
`Remote.displayHost`, sidebar/settings path abbreviation) into one
`Formatters` file, and finish adopting `NSPasteboard.copyString` (#53) at the
remaining inline call sites (`CommitDetailView`, `ChangesView`, `SidebarView`,
`ActivityHistoryView`).

---

## Missing features (ranked)

### M2 · Blame view — M
The last classic read-only git view missing. `git blame --porcelain -- path`
parses cleanly (header lines + "\t<line>" bodies). Plan: `BlameParser` (pure,
tested like `GitParsers`), `GitClient.fileBlame(path:)`, a `BlameView` (rows
with author/date/commit chip, monospaced text), entry points from Changes file
context menu and CommitDetail files. Reblame-on-click (blame from parent) is a
nice follow-up.

### F15 · Delete / prune remote branches — S/M
Remote branch rows offer checkout and merge only. Missing: "Delete on Remote…"
(`git push <remote> --delete <branch>`, destructive confirmation) and a
"Prune stale remote branches" action (`git remote prune <remote>`). Pairs with
#40's upstream-gone badge — a natural follow-up is in-app remediation on the
badge itself (context menu: "Re-publish" = `push --set-upstream`, "Unset
Upstream" = `branch --unset-upstream`), which #40's review also suggested.
Test: integration with a bare remote.

### F16 · Multi-select in the Changes lists — M
The file lists are single-click rows; staging 10 of 12 files means 10 round
trips. `List(selection: Set<…>)` + bulk Stage/Unstage/Discard on the selection
(the VM APIs already take arrays). Pairs with a "Discard All…" action for the
unstaged section.

### F18 · Branch list has no filter and the picker no search — S
A repo with 100+ branches makes both `BranchesView` and the toolbar picker
unusable. Add the same debounced filter-field pattern HistoryView already has
(reuse its filter bar), and consider sectioning the picker (current, recent,
all).

### F19 · "Open file at this commit" / save patch — S/M
`CommitDetailView` file rows: no way to view the file's content at that commit
(`git show hash:path` → temp file → Quick Look or editor) nor to export a
patch (`git format-patch -1 hash` / copy the loaded file diff). Two small,
high-leverage archaeology features. Add "Copy Diff" alongside (the diff pane
and the commit-detail file list both lack it — the Changes list has Copy Path
and Open in External Editor, the detail list only has Finder/Copy Path).
(flash review M-NEW-3.)

### F47 · Diffstat bars in the commit-detail file list — S
The commit-detail file list shows status + path only. A tiny per-file `+N −M`
(from `git show --numstat` — one more pure, testable parse) or GitHub-style
diffstat bar makes archaeology much faster at a glance. (flash review M-NEW-4.)

### F20 · Check for Updates (zero-dep) — S/M
The app ships DMGs via GitHub Releases but has no update check. A manual
"Check for Updates…" menu item hitting
`api.github.com/repos/L-K-M/GitEnough/releases/latest` (unauthenticated, like
PullRequestFinder) + compare against `CFBundleShortVersionString` + link to the
download keeps the zero-dependency rule and closes the loop with the release
pipeline.

### M4-remainder · Tag management beyond creation — S
#17 added create-from-commit. Still missing: delete tag (context menu on the
chip in history or a Tags section in Branches), and a Tags list per repo
(`for-each-ref refs/tags` — extend `branches()` or add `tags()`).

### M7 · File history (log of one path) — S/M
`git log --follow --format=<same as log()> -- path` → reuse `parseLog` and the
existing history list UI in a sheet or the CommitDetail pane. Entry: "History"
in file context menus (Changes + CommitDetail). `--follow` makes renames
transparent. Test: integration — rename a file mid-history, assert continuity.

### M8 · Stash preview — S
Stash rows have no diff. `git stash show --stat -p stash@{n}` → render in the
existing `DiffView` on selection in the Branches tab (mini split or sheet).
Test: parser-free (reuse diff pipeline); integration assert on staged content.

### M9 · Network operation progress — M
Only a spinner today. `git fetch --progress` writes
`Receiving objects: 45% (…)` to stderr; parse the last percentage line
periodically (GitShell currently buffers — needs incremental stderr reading via
`readabilityHandler`) and surface in the status bar / toolbar. Pairs with G1's
cancel work.

### M11 · Per-repo identity override — S
View/set `user.name`/`user.email` per repo (Settings sheet or Repository menu):
`git config --local`. Show current values in the commit box tooltip. Common
"wrong email" pain point.

### M12 · Clone options — S
Add `--depth` (shallow) toggle and `--recurse-submodules` to the clone sheet;
default the destination to the last-used parent folder (UserDefaults), show
estimated progress (M9 dependency).

### M13 · Compare branches — M
Clicking a branch shows only ahead/behind counts. A compare view: pick A vs B →
two lists (`git log A..B` and `B..A`) reusing the history list row component.
Natural as a Branches-tab detail pane or a sheet from the branch context menu.

### M14-remainder · Amend/fixup from history context menu — S
On HEAD row: "Amend staged changes into this commit". On any commit:
"Create fixup commit" (`commit --fixup=<hash>` — pairs with a future rebase).
#15 covered the commit-box warning; the context-menu actions remain.

### M15 · Minimal interactive rebase — L
Squash/drop/reorder the last unpushed commits. Honest scope: even
"squash last N into one" (`reset --soft` + recommit) and "drop unpushed commit"
are valuable without a full todo-editor UI. Guard everything on
"commits not on any remote" (#42's `unpushedCommitHashes()` is exactly that
predicate). This is the flagship follow-up after the basics; design first,
then implement.

### M16 · Submodule awareness — M/L
`Submodule` diff lines parse as meta only. Add: dirty-state indicator for
submodules in status, "Update Submodules" (`submodule update --init --recursive`)
in the Repository menu, and don't offer stage/discard on submodule paths (or
handle them via `submodule` subcommands).

### M18 · Pull rescue for dirty trees (autostash) — S
`git pull` with a dirty tree fails with git's raw message. Offer "Stash, pull,
pop" as a one-click recovery in the error path, or make
`pull --rebase --autostash` a Settings option (one flag). Pairs naturally with a
split-button Pull menu (Pull / Pull (Rebase) / Pull (Autostash)) in the toolbar
— #43 already turned Push into exactly this kind of split button to copy from.

### M19 · Hunk / line-level staging — L
The power feature (`git add -p` semantics via `git apply --cached` with a
constructed patch). Hunk checkboxes in `DiffView`, patch reassembly in a pure,
exhaustively tested type (hunk headers must be rewritten when lines are
deselected). Large but transformative for the Changes tab.

### M20 · Remote management UI — S/M
Beyond #6 (publish to the configured remote): add/remove remotes
(`git remote add/rm`), view their URLs, push to a non-origin remote. Natural
home: a Remotes section in the Branches tab + a remote picker on Publish.
#55's remote-less empty state currently points users at the terminal for
`git remote add` — this replaces that. Test: integration with two bare remotes.

### M21 · "Ignore Locally" via `.git/info/exclude` — S
Follow-up to #22: companion context action that appends to `.git/info/exclude`
instead of the shared `.gitignore` — for personal scratch files that mustn't be
committed to the shared ignore file. Reuses the `GitIgnore` helper verbatim;
only the target path differs (resolve via `client.gitDir()`).
Test: integration — ignored file disappears from status without touching
`.gitignore`.

### M23 · Spell checking in the commit box — S
SwiftUI's `TextEditor` doesn't spell-check by default; commit messages deserve
squiggles. One modifier; verify it doesn't fight the 72-char counter layout.

### F21 · Window title carries no branch — S
`navigationTitle(repo.name)` only. `navigationSubtitle` with the current
branch (+ dirty dot) makes Mission Control / window switching legible.

### F22 · Commit-box error dead-ends: "No API key configured" isn't actionable — S
`messageGenerationError` renders as plain caption text. When the error is the
missing key, show an "Open Settings…" button next to it (`SettingsLink` on
macOS 14) instead of making the user find Settings → AI.

### F23 · ⌘F doesn't focus the history filter — S
The filter bar exists but is mouse-only. `@FocusState` + a Find-menu ⌘F
command scoped to the History tab.

### F24 · Quick Look on file rows — S
Space-bar/context "Quick Look" on Changes + CommitDetail file rows via
`QLPreviewPanel` (AppKit, zero deps). Half of "did I mean this file?" checks
don't need a diff.

---

## Visual & layout

### V1 · Diff line numbers + gutter — S/M
Add old/new line-number columns and a +/- gutter to `DiffView`. Requires hunk
parsing to track running line numbers (extend `DiffParser`: emit line numbers on
each `DiffLine`, or a parallel array). Monospaced alignment; dim gutter color.
Test: parser unit tests for number computation across hunks/multiple files.

### F17 · Diff backgrounds don't span the scroll width (ragged blocks) — S/M
In `DiffView`'s two-axis `ScrollView` + `LazyVStack`, each line's `.background`
only extends to its own text width (the horizontal axis proposes nil width and
`maxWidth: .infinity` collapses to the ideal). Addition/deletion bands end
mid-pane at different x-positions — visibly scruffy next to every other git
client. The same structure defeats width caching, so parent publishes re-layout
the visible set. **Fix (one pass):** measure the longest line once per parsed
diff (the `ParseCache` from #30 already exists as the natural home) and lay
rows out at a fixed content width.

### V3 · Split (side-by-side) diff + whitespace toggle — M
A unified/split toggle and an "ignore whitespace" (`-w`) toggle in the diff
header. Split view = pair deletion/addition runs into rows (same pairing logic
as the intraline emphasis in #14 — factor it out). `-w` toggles the git
invocation (`diff(path:staged:ignoreWhitespace:)`) — note untracked
`diff --no-index` also accepts `-w`.

### V4 · Decoration overflow "+N" is a dead end — S
`+N` for commits with >3 refs is plain text. Make it a popover listing every
decoration (clickable → checkout for branches, copy for tags). Small win, big
repos with many tags (linux-style) currently lose information.

### V6 · Permanent "Drop a folder" hint — S
Show only while a drag hovers the sidebar (`isTargeted` on the List), or only
when the sidebar is empty.

### V9 · Date column width — S
Fixed 110 pt truncates with longer localized formats; measure or use
`fixedSize` + layout priority. Verify with a pseudo-localization build
(×LL length strings).

### V11 · File-type icons / language-color dots — S/M
Status letters only today. SF Symbol per extension (swift, py, md, json, png…)
or GitHub-linguist color dots (ship a tiny bundled JSON keyed by extension).
Renders in Changes rows and CommitDetail file lists.

### V12 · Accessibility pass — M
The graph strips are opaque to VoiceOver; rows/chips lack labels. Add
`.accessibilityElement(children: .combine)` with "commit <subject> by <author>,
<relative date>, refs: …" on rows; give RefChip an explicit label; give the
graph an accessibility summary ("history graph, N commits"). The unpushed
hollow dots (#42) need a spoken equivalent too.

### F25 · Commit-detail body clipped at 6 lines with no expansion — S
`CommitDetailView` (`lineLimit(6)`): long bodies — exactly the commits worth
reading — are silently truncated. Make the header scrollable or add an expand
toggle; keep text selectable.

### F26 · Truncated paths have no tooltip — S
File rows truncate middle (`ChangesView`, `CommitDetailView`) but don't set
`.help(file.path)`; sidebar rows same for the abbreviated path. One modifier
per row.

### F27 · Fixed 360 pt commit-detail pane — S/M
The detail column is hard-fixed at 360 pt (a deliberate anti-drift choice per
the comment in `HistoryView`). On a 27" display the history list is cavernous
while file paths in the detail truncate. Consider a user-resizable width
persisted in `@AppStorage` (keeping the no-HSplitView decision), or at least
400–420 pt on wide windows.

### F28 · Toolbar branch picker can dominate the toolbar — S
`.fixedSize()` on the picker label lets a 60-char branch name push the
fetch/pull/push cluster off-window. Cap with `.frame(maxWidth: 260)` + middle
truncation.

### F29 · Ref chips: HEAD chip crowding — S (design)
`RefChip` renders HEAD + branch as two chips on the same commit
("HEAD" + "main"), spending row width twice for one fact. Collapse
`HEAD -> main` into a single accented chip ("● main"), keep plain "HEAD" only
for detached. Pairs with A5 (lane-colored chips) and V4 (+N popover).

### F30 · Selection highlight is two disjoint rectangles — S
Graph strip and row text each paint their own `accentColor.opacity(0.20)`
(`GraphStripView` + `CommitRowView`), meeting at a visible seam when lane
counts squeeze widths. Paint one full-row background behind an HStack of
[strip, row] instead.

### F51 · WelcomeView is static — S
On a machine with 20 registered repos it shows one button and a hint. A
"recently opened" row list (the store already tracks `lastOpenedAt`) or a
"resume where you left off" affordance would make the empty pane useful
instead of decorative. (flash review V-NEW-8.)

---

## Interaction & UX

### U1 · Keyboard navigation in the history list — M
The list is `ScrollView` + tap rows: no arrow-key selection. Introduce move
up/down via `.onMoveCommand` (or wrap rows in a focusable list), keep ⏎ to open
detail, and maintain `selectedHash`. Must keep the graph selection highlight in
sync (it keys off `selectedRow`, so it comes free). Add "⌘C copies the selected
commit's hash" while wiring it.

### U2 · Stage/unstage/discard shortcuts — S
⌘⇧↑/⌘⇧↓ (or ⌥↑/⌥↓) for stage/unstage selected change; ⌫ opens the discard
confirmation; ⌘⇧N new branch. Wire in `ChangesView` via `.keyboardShortcut`
on the row actions or hidden menu commands.

### U4 · Double-click conventions — S
Local branch rows double-click → checkout; remote rows do nothing; history rows
do nothing. Decide: remote double-click → tracking checkout; history
double-click → reveal in Finder? Document in the tooltip.

### U6 · Background-completion notifications — S/M
Long fetch/push finishing while unfocused is invisible. Local user notification
(UNUserNotificationCenter, permission requested lazily on first background op;
errors only by default). Respect a Settings toggle.

### U7 · Open-on-remote deep links — M
`Remote.displayHost` already parses GitHub-style URLs. Add "Open on GitHub"
for: repo page, current branch, selected commit, file-at-commit (build
`/blob/<hash>/<path>` URLs). Support github.com, gitlab.com, bitbucket.org
shapes; hide the menu items when the URL doesn't parse to a known host.

### U8 · Stash everywhere — S
"Stash…" only appears in Changes when unstaged files exist. Add a Repository
menu item + ⌘⇧S, and make the status bar's "N stashed" a popover listing
entries with Apply/Pop/Drop.

### F32 · Stage/unstage icons flip meaning with no animation — S
The row action button switches `plus.circle`/`minus.circle` instantly as the
file jumps lists; the file appears to teleport. A `withAnimation` on the list
change (or matchedGeometryEffect at higher effort) makes stage/unstage legible.
Micro-polish with outsized perceived-quality payoff.

### F33 · Destructive dialogs can act on stale captures — S
Confirmation dialogs (`Discard`, `Hard reset`, `Force delete`) act on state
captured in `@State` vars that survive re-presentation; "Discard Changes" on a
stale `fileToDiscard` after a background refresh swaps the list is possible.
Clear the captured item when the snapshot no longer contains it (mirror the
selection-following logic added in #16).

---

## Aesthetics

### A1-remainder · Empty-state art — S (design)
The app icon derives from the designed artwork in `media-sources/icon.png`
(via `scripts/make-icon.js`, so regenerating can't revert it). The empty
states — #55's included — still use plain SF Symbols; picking up the icon's
visual language there remains open.

### A2 · Date grouping in history — S/M
"Today / Yesterday / This week / …" section headers (or subtle separators) in
the history list; compute buckets from `commit.date` cheaply per row render.
Constraint discovered while scoping: graph rows must stay 1:1 with commits, so
subtle in-row separators beat section headers.

### A3 · Density setting — S/M
27 pt rows are comfy; a "Compact" mode (22–24 pt, smaller font) helps big
histories. `GraphMetrics` must become dynamic (environment-injected) — keep it
the single source of truth shared by canvas and rows.

### A4 · Status bar polish — S (design)
Ahead/behind/stash/dirty are five separate gray `Label`s in one caption strip.
Group into pills (**↑2 ↓1** as one sync pill — click = fetch; **3 stashed** —
click = the stash popover from U8) with subtle semantic tints; make the remote
label a click-to-fetch target. Keep the git-activity terminal chip as-is — it's
the best part.

### A5 · Lane-colored branch chips — S/M
RefChips for HEAD/local branches use the same accent color at two opacities.
Tint each local-branch chip with the *graph lane color* of the branch tip
(derivable: layout node color for the decorated commit) — pretty and functional
(chips match lanes). Needs a per-commit `colorIndex` lookup exposed from the
layout (it exists on `Node`).

### A6 · Dark-mode contrast check of the palette — S
The graph palette switches brightness only; verify WCAG-ish contrast on OLED
black and possibly desaturate. Mechanical pass with the color math in
`GraphStripView.laneColor`.

### F34 · The commit box reads as an afterthought — S/M (design)
A borderless `TextEditor` with a 1 pt stroke, a tiny Generate button, and the
72-char counter crammed inline. Suggestion: give the subject its own
single-line field (auto-advancing to a body field on ⏎ — this also makes the
72-char rule structural instead of advisory), move Generate into the field as
a trailing sparkle icon, and let the box grow with content up to ~6 lines.

### F36 · No motion anywhere — S (design)
Banners appear/disappear with a hard cut (`RepoDetailView` merge/error
banners), rows pop in on refresh. Two `withAnimation(.snappy)` transitions —
banner slide+fade, list diff animation — would remove most of the "prototype"
feel. Deliberately skip animating the graph.

---

## Novel / delightful

### Q1 · Reflog-powered Undo (⌘Z) — M/L — the killer feature
`git reflog` is right there. Phase 1: "Undo last operation" covering
commit/reset/checkout performed *by the app* (reset to previous HEAD@{1},
keeping the worktree; explain when unsafe — e.g. after a push). Phase 2: an
"Operations" timeline sheet. Watch: undoing pushes must be refused with an
explanation, not attempted.

### Q2 · Command palette (⌘⇧P) — M
Fuzzy-searchable actions + repos + branches + commits ("checkout feature",
"fetch", "discard all", "open in terminal"). A tiny scoring function is pure and
testable; subsumes U5-style quick switchers. Natural extension surface for
everything in this backlog.

### Q3 · "Trace branch" graph interaction — M
Click/hover a lane: its whole ancestry lights up, everything else fades
(IntelliJ-style). Pure reachability computation over the loaded commit graph
(parents map) — fully unit-testable; rendering picks per-node emphasis alpha.

### Q4 · Optional "Generated with GitEnough" trailer — S
✨ Generate may append a configurable trailer (`🤖 Generated with GitEnough`).
**Off by default**, in Settings → AI; never silently rewrite messages.

### Q5 · Commit streak sparkline — S
A tiny 30-day per-author sparkline in the status bar (local `git log --author
--since` counts, cached per day). Zero network, pure fun.

### Q6 · GitHub language-color dots — S/M
(See V11 — same JSON, two presentations.)

### Q7 · Conflict "ghost preview" — M
For a conflicted file, show ours/base/theirs mini-panes before the user picks
Ours/Theirs (`git checkout --conflict=diff3` + existing DiffParser gets most of
the way). Turns blind resolution into an informed choice.

### Q8 · Repo activity sparkline in the sidebar — S/M
A 30-day commit sparkline per repo row (cached per day, never per refresh).
Makes the sidebar feel alive; keep it subtle (low contrast) and skippable.

### Q9 · Ambient "dirty tree" nudge — S
Working tree dirty for > N minutes → subtle tint/badge on the Changes tab
segment. No modal nagging.

### Q10 · Error messages with copy-paste fixes — S/M
Known error classes (detached HEAD push, non-fast-forward, index.lock exists)
get a "GitEnough hint" line under the raw git error naming the button to press
("Pull first", "Force push…" — the latter exists since #43). Map on
`GitError.message` matching; keep the raw text always visible; builds on #51's
expandable banner.

### Q11 · Graph rainbow easter egg — S
One-shot palette animation on the History tab: ⌥-clicking the History tab
title replays the graph's palette assignment as a ~0.8 s cascade. Zero value,
pure joy; a deliberate easter-egg surface beats a build flag.

### Q12 · Drag a commit onto a branch — M
Direct-manipulation cherry-pick/rebase: drag commit C onto branch row B →
menu "Cherry-pick C onto B / Rebase B onto C". Draggable rows + existing git
plumbing. Very demo-worthy; guard the drag target to local branches.

### Q13 · Gravatar avatars in history — S
`Insecure.MD5(lowercased email)` (CryptoKit) →
`gravatar.com/avatar/<hash>?d=identicon&s=32` in a 16 pt circle beside the
author in each history row. One `AsyncImage`, Settings opt-out. Instantly
humanizes the log; zero dependencies.

### Q14 · "Explain this commit" (AI) — S/M
Detail-pane button → send the commit's patch (capped, like the commit-message
flow) to the configured LLM → plain-English summary sheet. Reuses
`CommitMessageGenerator` plumbing with a different system prompt. Great for
archaeology in unfamiliar repos.

### Q15 · AI-assisted conflict resolution — M/L
Send a conflicted file's hunks to the LLM → proposed merged content in a
preview sheet (accept / edit / discard). Ambitious but on-brand; pair with Q7's
ghost preview so the user can judge the suggestion.

### Q16 · "Fetched N min ago" in the status bar — S
Persist last-fetch time per repo (UserDefaults), render next to the remote
host. Pairs with auto-fetch (#23): makes staleness visible instead of
surprising.

### Q17 · Commit-subject autocomplete from history — S
Offer recent repo subjects as autocomplete/suggestions while typing in the
commit box (repo-local, no network). Subtle, surprisingly handy for repetitive
chores ("Bump …", "Fix typo …").

### F37 · AI: PR description from the branch — S/M
`git log main..HEAD` + diffstat → the existing `CommitMessageGenerator`
plumbing with a PR-description system prompt → paste-ready title+body sheet
next to "Open Pull Request" (which already knows the base branch). Reuses
everything; pure win for the app's AI identity.

### F38 · AI: "Since you were away" repo digest — M
On selecting a repo whose `lastOpenedAt` is >N days old: summarize
`git log --since=<last open> --stat` into three bullets (local LLM call, cached
per head hash). The sidebar already tracks `lastOpenedAt`.

### F39 · Branch cleanup assistant — S/M
"Clean up branches…" sheet listing local branches fully merged into the
default branch (`git branch --merged` minus HEAD/protected), pre-checked for
bulk delete, with "also delete on remote" checkboxes where an upstream exists.
The single most-wanted janitorial feature in every git GUI; trivially testable
in the integration harness. Pairs with F15.

### F40 · Commit-graph minimap — M/L
A 60 px-wide vertical strip next to the history scroller drawing lane
polylines for the *loaded* history (one Canvas, decimated), with a viewport
brush. Doubles as a scrollbar and makes long-history navigation feel spatial.
Renders from the existing `GraphLayout` — no new git calls.

### F41 · Conventional-commit type chips — S
When the last ~20 subjects match `type(scope): …`, show one row of chips
(feat/fix/chore/docs…) above the commit box; clicking prefixes the draft.
Zero config, self-detecting, invisible in repos that don't use the convention.
(Pure-parse helper + tiny UI; unit-test the detector.)

### F42 · `.gitmessage` template support — S
If `commit.template` is configured (or `.gitmessage` exists), prefill the
empty commit box with it instead of a placeholder. Respects existing user
workflow; one `git config --get commit.template` read per repo open. Mind the
interaction with per-repo draft persistence (#54): the template seeds only a
box that has no persisted draft.

### F43 · Menu-bar extra: "N repos need attention" — M
Optional `MenuBarExtra` listing repos that are dirty/behind (from the summary
cache — zero extra git calls), one click to open. Off by default per the
no-nagging philosophy (Q9's spirit).

### F48 · Hover tooltip on graph nodes — S
Hovering a dot in the graph shows the commit subject in a small popover (the
rows already know the commits; the strip just needs a hit-test for its node's
row). Delightful for dense graphs where the subject truncates. (flash review
Q-NEW-4.)

### F49 · "N new commits on origin/main since your last fetch" — S/M
After a fetch that moved the default remote branch, show a subtle one-shot
banner: "origin/main moved: 3 new commits" with a click-to-jump to the first
new one. Turns an invisible event into awareness; pairs with Q16's
"fetched N min ago". Related but distinct from F38 (per-repo-open digest).
(flash review Q-NEW-5.)

### F50 · Keyboard-shortcut cheat sheet (⌘/) — S
A ⌘/ popover listing the app's shortcuts (≈15 now, growing). Tiny,
discoverable, and it makes every future shortcut land better. (flash review
Q-NEW-7.)

---

## Suggested next pickups (highest value first)

1. **G1** cancel/timeout for network ops (robustness foundation for M9)
2. **F17** diff backgrounds/width (the most visible remaining polish defect)
3. **M2** blame view (last missing classic view)
4. **F15/F39** remote-branch delete/prune + branch cleanup assistant
5. **F16** multi-select staging (everyday friction)
6. **M18** pull autostash rescue (small, removes a common raw-error dead end)
7. **F18** branch filtering (unusable at 100+ branches today)
8. **U1/U2** keyboard navigation + shortcuts (feel)
9. **V1/V3** diff gutter + split/whitespace toggles (review quality)
10. **F4/F5/F8/F12** the small correctness batch (menu busy state, Trash
    errors, `--tags` clobber, summary clobber)
11. **Q1** reflog undo (differentiator)
12. **Q2** command palette (differentiator; unlocks everything else)
13. **M15** minimal interactive rebase (flagship feature; #42's unpushed set
    is the guard rail)
14. **F37/Q13/Q14** AI PR description + gravatar avatars + "Explain this
    commit" (cheap delight)
