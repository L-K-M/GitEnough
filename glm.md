# GitEnough — Thorough Review (glm.md)

A full review of the GitEnough codebase (v0.1.0, commit `4d2e27f`) covering bugs,
general issues, performance, missing features, visual/layout problems, UX, aesthetics,
and ideas for novel/delightful improvements. Each entry notes where the problem lives,
why it matters, a suggested fix, effort (S/M/L), and whether it's unit-testable on CI.

Severity legend: 🔴 serious bug · 🟠 notable issue · 🟡 polish/minor · 💡 idea

---

## 1. Bugs

### B1 🔴 Rebase / cherry-pick / revert conflicts are invisible and unresolvable
`GitClient` only knows about `MERGE_HEAD` (`mergeHead()`), and `MergeState.isMerging`
is false during a `git pull --rebase`, `cherry-pick`, or `revert` that hits conflicts.
Consequences:
- `ChangesView` shows the "Conflicted Files" section only `if mergeInProgress`
  (`mergeState.isMerging`), and porcelain-v2 `u` entries are *only* routed to
  `status.conflicted` — so during a conflicted rebase the affected files appear
  **nowhere in the UI at all**.
- There is no banner, no `rebase --continue`, no `rebase --abort`,
  no `cherry-pick --continue/--abort`, no `revert --continue/--abort`.
- The "Pull (Rebase)" setting (Settings → General) makes this the *default* pull
  strategy, so a fairly ordinary pull can strand the user in a state the app
  neither displays nor can exit. They must drop to a terminal.

**Fix:** detect the operation in progress (`rebase-merge`/`rebase-apply` dirs,
`CHERRY_PICK_HEAD`, `REVERT_HEAD`, then `MERGE_HEAD`), extend `MergeState` with an
`operation` field, show the conflict section whenever conflicts exist (not just for
merges), and add Continue/Abort actions per operation. Highly testable with real git
in `GitIntegrationTests` (conflicted rebase in a temp repo).

### B2 🔴 `git log --all` includes the stash ref — WIP commits pollute the history graph
`GitClient.log` uses `--all`, which means *every ref under `refs/`*, including
`refs/stash`. Every `git stash` therefore drops two synthetic "WIP on…" commits into
the graph as permanent-looking lanes. IntelliJ, Fork, and Tower all exclude stashes.
**Fix:** `log --exclude=refs/stash --all …` (the `--exclude` must precede `--all`).
Trivial + integration-testable (stash, then assert the WIP subject is absent).

### B3 🟠 Publishing a branch hardcodes the `origin` remote
`RepoViewModel.publishBranch()` calls `push(setUpstream: true)` whose default is
`remote: "origin"`. The Publish button appears whenever *any* remote exists
(`!viewModel.remotes.isEmpty`), but if the sole remote is named anything else
(`upstream`, `github`, `gitlab`, a work remote…) the push fails with git's
"origin does not appear to be a git repository" error. **Fix:** pass the first
configured remote's actual name (and adjust the tooltip). Testable with a local bare
repo as remote under a custom name.

### B4 🟠 Repo validation runs `git` synchronously on the main thread
`RepoStore.add(url:)` shells out twice (`isRepository`, `topLevel`) and is called
from `AppState.addRepository(at:)` on the main thread — from the Add sheet's Add
button, from NSOpenPanel completion, and from the sidebar **drop handler**. On a
slow/network volume this beachballs the whole UI, and it violates the project rule
"don't call GitClient from the main thread" (AGENTS.md). **Fix:** validate on a
background queue, hop back to main to register/select; keep the sheet's error path.

### B5 🟠 Dropping a non-repository folder fails silently
When a dropped folder isn't a git repo, `AppState.addRepository` sets
`addRepositoryError` — but that error is only rendered inside `AddRepositoryView`,
which is not open during a drop. The user gets zero feedback.
**Fix:** surface drop-path failures as an alert on `ContentView` (or a toast).

### B6 🟠 Stale selection when switching repositories can hang the History detail pane
`HistoryView` holds `@State selectedHash`. Because the view occupies the same
structural identity across repo switches, the selection survives the switch, but
`viewModel.selectCommit` is never invoked on the *new* view model
(`.onChange(of: selectedHash)` doesn't fire — the value didn't change). If the hash
doesn't exist in the new repo, the later `commits` change clears it (spinner
meanwhile); if the hash *does* exist in both repos (common: shared history, forks),
`CommitDetailView` sits on an endless `ProgressView` until the user clicks a row.
**Fix:** reset `selectedHash` when the repo changes (`.onChange(of: viewModel.id)`
or `.id(viewModel.id)` on the tab content).

### B7 🟠 Stage/unstage drops the selected file even though it's still visible
`ChangesView.onChange(of: viewModel.status)` clears `selectedFile` when the entry is
in neither list — but `FileChange` equality includes the status columns, so staging
the selected file (status changes `??`→`A `) makes `contains` fail in the *unstaged*
list while the file is actually sitting in the *staged* list, and the selection (and
its diff) is lost. **Fix:** track selection by path, not by full `FileChange`
equality (and prefer keeping it pointing at wherever the path now lives).

### B8 🟡 `Settings → General` spawns a git process on every render
`GeneralSettingsView` calls `GitClient.version()` directly in `body` — a
synchronous process spawn each time the tab renders. Cache it once (static let or
task) or capture it in `onAppear`.

### B9 🟡 Failed commit-detail load shows an eternal spinner
`CommitDetailView` shows `ProgressView()` whenever `selectedHash != nil` and the
detail isn't loaded. `selectCommit` uses `try?` — a failed load yields `nil` detail
forever. Add an error/empty state after a failed fetch.

### B10 🟡 Amend + no staged changes can surprise
With `amendLastCommit` on and nothing staged, Commit is enabled (reasonable —
message-only amend), but there's no indication the *last commit's tree* is what's
being rewritten. A caption ("Amending rewrites <short-hash>") would prevent mistakes.

### B11 🟡 Branches "gone" upstream is dropped by the parser
`for-each-ref`'s `%(upstream:track)` can be `gone` (upstream deleted on the remote);
`parseBranches` only understands `[ahead N, behind M]`, so such branches show no
state at all. Parse `gone` and surface it (e.g. "✗ upstream gone").

### B12 🟡 Merge-tool "already open" guard misreports
`openMergeTool` refuses a second concurrent tool with an error banner — but the
guard checks `mergeToolActivity == nil` which is set/cleared on the main thread
around a background task; rapid double-clicks on *different* files can both pass
the guard before the first sets the flag (minor race), and refusing a second file
entirely is unnecessarily strict (FileMerge happily opens multiple windows).
Consider a per-path set, or at least make the guard atomic.

### B13 🟡 Relative dates go stale
`RelativeDateText` renders "2 minutes ago" once; the string only updates when some
other state change re-renders the row. Wrap in `TimelineView(.periodic(...))` (or
update on a timer) so ages stay truthful while the window is open.

---

## 2. General issues

### G1 🟠 No cancellation/timeout for git operations
`fetch`/`pull`/`push`/`clone` have no timeout and the serial repo queue has no
preemption. A fetch over a dead VPN hangs the queue for minutes: the spinner spins,
every other op queues behind it, and there's no Cancel button. Suggested: kill-switch
per RepoViewModel that terminates the running Process (GitShell would need a
handle to it), plus a visible Cancel in the toolbar/status bar during network ops.

### G2 🟠 Unbounded background polling for every repo ever opened
`AppState.viewModels` keeps every `RepoViewModel` (and its 2.5 s `RepoWatcher`)
alive forever. With 20 repos that's 20 timers doing ~12 `stat`s each — cheap, but
scales linearly and refreshes state nobody sees. Pause watchers for non-visible
repos (resume on select / on window focus) or evict after a TTL.

### G3 🟠 Snapshot refresh runs 6 sequential process spawns
`collectSnapshot` runs status → branches → remotes → stash → merge probes → log in
sequence on the serial queue. All are read-only (status is `--no-optional-locks`);
they could run concurrently (or be coalesced: `for-each-ref` already carries most of
what `remotes` gives). On big repos this shaves the felt latency of every refresh.

### G4 🟡 `refreshSummaries` is serial per repo
`AppState.refreshSummaries` loops all repos sequentially on one utility queue; with
15+ repos an activation refresh takes seconds. Parallelize (TaskGroup, maybe capped).

### G5 🟡 Watcher misses deep worktree edits by design
`RepoWatcher.signature` watches `.git` internals + the worktree *root* mtime; edits
in subdirectories don't tick the signature and are only caught on app activation.
Acceptable trade-off, but a note/tooltip ("changes refresh when GitEnough activates")
or an FSEvents-based watcher would close the gap.

### G6 🟡 No tests for RepoStore persistence semantics
AGENTS.md mentions `RepoStoreTests` ("removal sticks") but no such file exists in
`GitEnoughTests/`. The exclusion contract is only covered indirectly via
`RepoDiscoveryTests`. Add `RepoStoreTests` (inject a UserDefaults suite).

### G7 🟡 Dead code: `GraphPalette.colorIndex(forLane:)`
Unused since layout switched to its own `nextColor` counter. Remove or use.

### G8 🟡 Detached-HEAD push affordances
With no upstream, only "Publish" is offered, which does `-u origin HEAD` — in
detached HEAD that pushes HEAD to a remote branch named after the *commit*? (`push
-u origin HEAD` in detached state pushes to `refs/heads/HEAD`?? — git actually
refuses or creates a puzzling branch). Guard: disable Publish while detached, or
ask for a branch name.

---

## 3. Performance problems

### P1 🟠 The whole-history Canvas is a single giant, non-lazy view
`GraphCanvasView` sizes itself to `rows × 27pt` and draws **every** segment and node
whenever anything changes (selection included). The commit rows are lazy
(`LazyVStack`) but the graph is one opaque canvas: after a few "Load more"s
(thousands of rows) that's an 80 000 pt-tall layer that re-rasterizes on selection
changes — classic source of scroll stutter and memory growth on long histories.
**Fix options:**
1. Draw the graph in per-row slices (each `CommitRowView` renders its own graph
   slice) — makes both columns lazy and redraws only visible rows; also fixes
   alignment coupling forever. (Best, M effort.)
2. Keep the canvas but clip/chunk it to the visible window via geometry readers.
Also `layout.segments` currently carries O(rows) segments that all get iterated
per frame.

### P2 🟠 `--topo-order --date-order` full-log on every refresh & pagination restart
`git log --all --topo-order` has to walk essentially the whole history to order it;
`loadMoreHistory` re-fetches from scratch (`skip=0 … limit=n+1`) and re-lays-out the
entire graph each page. For big monorepos each refresh costs seconds. Mitigations:
cache the commit list and only append new pages (`--skip`), use
`--exclude=refs/stash` (B2) to cut stash refs, and consider `--no-walk`-style
shortcuts for the status-only refreshes (already mostly done via
`includeHistory:false` — good).

### P3 🟡 `onChange(of: viewModel.commits.map(\.hash))` maps every commit each render
`HistoryView` maps all hashes into an array on *every* body evaluation just to
detect "selection vanished". Cheap at 300 rows, pointless at 3 000: compare
`firstIndex(where:)` for the selected hash only, or track a set.

### P4 🟡 Diff parsing runs in `DiffView.body`
`DiffView.parse(diff)` re-parses up to 4 000 lines on every body evaluation (the
`diff` string rarely changes). Memoize (e.g. parse in `onChange`/task into state, or
a tiny cache keyed by string).

### P5 🟡 Untracked diff spawns a `diff --no-index` per selection
Fine today; just noting it's synchronous per click on the serial queue. Fine.

---

## 4. Missing features (everyday-git completeness)

### M1 🟠 Search/filter the history (subject, author, hash, ref)
There is no way to find a commit without scrolling. A filter field above the list
that filters rows *and* recomputes the lane layout for the matching subset (what
Fork/Tower do) is the single most-used history feature after the graph itself.
Pure matcher is trivially testable. (See also Q2 for the fuzzy-palette version.)

### M2 🟠 Blame view
No way to answer "who wrote this line". A per-file blame pane (click a file in a
commit → "Blame") with commit/author/line mapping is the last classic read-only
git view missing. `git blame --porcelain` is very parseable; pure parser +
integration tests possible.

### M3 🟠 Squash merge & `--no-ff` option
`merge()` is always a plain `git merge --no-edit`. GitHub-Desktop-parity needs
`--squash` (+ the follow-up commit) and optionally `--no-ff` — at minimum a
modifier in the merge confirmation dialog.

### M4 🟠 Tag management
Tags render as chips, but there is no create/delete/checkout-tag UI anywhere.
Context menu on a commit ("Tag…"), a Tags section in Branches, and
`git tag -l` in the refs list.

### M5 🟠 Force push / push options
No `--force-with-lease` anywhere. It's the safe force-push and its absence pushes
people to the terminal. Add to the Push button's menu (with confirmation).

### M6 🟠 Reveal in Finder / Open in editor from file rows
Neither the Changes lists nor the commit-detail file list offer "Reveal in Finder"
or "Open in External Editor" — the most common cross-app actions on a changed file.
(NSWorkspace one-liners + context menu items.)

### M7 🟡 File history (log of one path)
Click a file → "History" showing only commits touching it
(`git log --follow -- path`). Natural extension of M2.

### M8 🟡 Stash preview
The stash list has no diff preview. Show the stash's patch (or at least a file
list) when a stash row is selected — `git stash show -p stash@{n}`.

### M9 🟡 Fetch/push/pull progress
Network ops show only a spinner; `git fetch --progress` writes percentages to
stderr that could drive a progress bar / status text ("Receiving: 45%").

### M10 🟡 Auto-fetch option
Ahead/behind is only accurate after a manual fetch. An optional background fetch
(every N minutes, or on activation) with a setting would keep the sidebar honest.
(Network-touching default must stay opt-in.)

### M11 🟡 Per-repo identity override
Quick view/set of `user.name`/`user.email` per repo (work vs personal) — a
frequent source of "committed with the wrong email" pain.

### M12 🟡 Clone options
No `--depth`, no `--recurse-submodules`, no clone progress %, and no default
destination (uses manual folder pick each time — default to `~/src` or last used).

### M13 🟡 Compare branches
Clicking a branch shows ahead/behind counts only. A compare view (list of commits
unique to each side) is a natural Branches-tab detail pane.

### M14 🟡 Amend / fixup from history context menu
On HEAD: "Amend staged changes into this commit". On any commit: "Create fixup
commit" (`commit --fixup`) — pairs nicely with a future rebase.

### M15 🟡 Interactive rebase (squash/drop/reorder)
The big one. Even a minimal "squash the last N commits" or drag-to-reorder of the
last unpushed commits would differentiate. Large effort; plan after M3/M14.

### M16 🟡 Submodule awareness
`Submodule` lines are parsed as meta in diffs, but there's no init/update/status
surface. At minimum show submodule dirty state and "Update Submodules".

---

## 5. Visual issues & layout problems

### V1 🟡 Diff view has no line numbers or +/- gutter
Just colored rows. A line-number gutter (old/new columns) with the +/- column is
table stakes for reviewing patches and helps navigation.

### V2 🟡 No word-level (intraline) highlighting
Changed *lines* are colored, but changed *words* within a line aren't highlighted —
GitHub-style intra-line emphasis makes long-line diffs readable. Pure-parser work,
fully testable. (High value/effort ratio.)

### V3 🟡 No side-by-side (split) diff mode, no whitespace toggle
A unified/split toggle and an "ignore whitespace" (`-w`) toggle in the diff header
are standard. Both cheap given the parser.

### V4 🟡 History rows: "+N" decoration overflow is a dead end
When a commit has more than 3 refs, `+N` is plain text — no tooltip, no popover.
Make it a popover listing all refs (clickable → checkout/copy).

### V5 🟡 Empty states missing
- Repo with zero commits (fresh `init`): History tab is a blank pane — should say
  "No commits yet — make your first commit in the Changes tab".
- History filter with no matches: blank (see M1).
- Branches tab in a repo with no remotes: sections just absent; a hint that
  pushing/publishing creates them would help newcomers.

### V6 🟡 "Drop a folder to add it" hint is permanent sidebar clutter
It shows whenever repos exist. Show it only while a drag hovers (`isTargeted`), or
demote it to the empty-sidebar state.

### V7 🟡 Error banner truncates long git stderr
`lineLimit(4)` with no expansion; merge/hook failures are frequently longer than
4 lines and the useful part is the end. Make it expandable (chevron) and/or
monospaced with scroll; add "Copy" button next to dismiss.

### V8 🟡 Commit message box: no subject/body affordances
A fixed 76pt `TextEditor`, no monospace, no 50/72-char guides, no subject-line
preview of how it'll look in `git log --oneline`. Cheap and genuinely useful.

### V9 🟡 Commit row author/date widths
The date column is a fixed 110pt; with long relative strings ("1 minute ago" fine,
but localized builds/longer formats) truncation appears. Consider `fixedSize` +
layout priorities or a shorter `unitsStyle`.

### V10 🟡 Graph hover/selection affordances
No hover highlight of a lane, no "trace this branch" emphasis on selection. Even a
hover ring on nodes (and a tooltip with the hash) would make the graph feel alive.
(See Q7 for the ancestry-highlight idea.)

### V11 🟡 File rows lack file-type icons
A/ M/ D letters only. SF-Symbols-per-extension (or GitHub language-color dots, Q6)
make big change lists scannable.

### V12 🟡 Accessibility: the graph and chips are opaque to VoiceOver
The Canvas has no accessibility elements; RefChip has no label beyond its text.
Rows should expose `.accessibilityElement(children:.combine)` with "commit <subject>
by <author>, <date>, refs: …". Low effort, real impact.

### V13 🟢 Verified non-issue: trailing free lanes don't inflate graph width
I traced `GraphLayout`: every lane is either occupied (counted, and drawn to the
last row) or was claimed by a node at some row, so `columnCount` never exceeds
maxNodeColumn+1. No fix needed — noting it so nobody re-audits.

---

## 6. UX / convenience / speed of interaction

### U1 🟠 No keyboard navigation in the history list
The list is a `ScrollView` + `onTapGesture` rows — arrow keys don't move the
selection, type-ahead doesn't exist. Even without a full `List` rewrite,
`.focusable` + moveUp/moveDown handlers (or migrating rows to `List(selection:)`
in a shared ScrollView container) restores j/k-style navigation.

### U2 🟠 No shortcuts for stage/unstage of the selected file
Power users want ⌘⇧↑/⌘⇧↓ (or ⌥↑/⌥↓) to stage/unstage the selected change, ⌫ to
discard-with-confirm, and ⌘⇧N for new branch. Currently everything is
mouse-driven except the global commands.

### U3 🟡 Copy actions everywhere
Commit rows have Copy Hash/Message; file rows don't ("Copy Path" is constant
use). Branch rows: "Copy Name". Cheap wins.

### U4 🟡 Double-click semantics inconsistent
Branches: double-click a local branch checks it out; remote rows do nothing.
History: double-click does nothing (should open the commit detail focused /
reveal in Finder?). Pick a convention and apply it.

### U5 🟡 No recent-repos quick switcher
Sidebar filter exists, but ⌘⇧O-style "recent repos" fuzzy switcher (like editors)
is faster with many repos. (Overlaps Q2 palette.)

### U6 🟡 Notification when a long op finishes in the background
Fetch/push while unfocused: the result (especially failure) is invisible until you
look at the app. A user notification (with permission) or at least a badge/dock
bounce on error would help.

### U7 🟡 Open-on-remote (browser deep links)
`Remote.displayHost` already parses GitHub-style URLs. Add "Open on GitHub" for:
repo page, current branch, selected commit, and file-at-commit. Users constantly
jump between client and browser; deep links are the bridge. (Parse
`git@host:owner/repo` and `https://host/owner/repo` → web URL.)

### U8 🟡 Stash from anywhere
"Stash…" only appears in the Changes header when unstaged files exist. A Repository
menu item + shortcut (⌘⇧S) with the sheet, and stash-list access from the status
bar's "N stashed" label (click → popover) would round it out.

---

## 7. Aesthetics

### A1 🟡 App icon & empty-state art
The icon is generated (make-icon.js). A designed icon (git-graph motif — the app's
signature feature) plus subtle empty-state illustrations would lift perceived
quality disproportionately.

### A2 🟡 Date grouping in the history list
"Today / Yesterday / Last week" section headers (or subtle separators) make long
histories navigable and look modern (see every good git client).

### A3 🟡 Density control
27pt rows are comfy; reviewers with big histories want a "compact" mode (22–24pt,
smaller font). A simple setting toggle; GraphMetrics must become dynamic rather
than `let` constants (careful: shared by canvas and rows by design).

### A4 🟡 Status bar polish
The status bar is informative but flat: consider grouping ahead/behind into a
single pill ("↑2 ↓1"), adding a click-to-fetch affordance on the remote label,
and the stash count as a popover trigger (U8).

### A5 🟡 Accent-color-aware chips
RefChips use `Color.accentColor` for both HEAD and local branches — they're
distinguishable only by opacity. Use distinct hues (or tint local-branch chips by
the graph lane color of the branch, which is both pretty and informative — matches
the graph!).

### A6 🟡 Dark-mode check of graph palette
Hues are fixed with a brightness switch; verifying contrast ratios (and maybe
desaturating in dark mode) would keep lanes readable on OLEDB blacks.

---

## 8. Novel / cool / delightful / quirky ideas

### Q1 💡 Reflog-powered "Undo" — the killer feature
GitEnough already shells to git; `git reflog` is right there. An "Operations"
timeline (every checkout/reset/commit the app performed) with one-click
**Undo** (reset to previous reflog entry, keeping the worktree) would be the
"Time Machine for git" no mainstream client does well. Start with a simple
"Undo last operation" (⌘Z) covering commit/reset/checkout, plus a "Recent
Operations…" sheet. (Watch for: undo of a push → offer nothing, explain.)

### Q2 💡 Command palette (⌘⇧P)
Fuzzy-searchable actions + repos + branches + commits: "checkout feature",
"fetch", "discard all", "open in terminal". A tiny scoring function is pure and
testable. This subsumes U5 and half of U2 and feels magical.

### Q3 💡 "Trace branch" graph interaction
Click/hover a lane: the *entire ancestry path* of that branch lights up and
everything else fades. IntelliJ-style. With the current layout model this is a
pure reachability computation (testable!) — the graph suddenly explains history
instead of just drawing it.

### Q4 💡 Co-authored-by / "Generated with GitEnough" trailer (opt-in)
The ✨ Generate button could append a configurable trailer
(`🤖 Generated with GitEnough`) — delightful marketing, must be opt-in and off
by default (message purity matters).

### Q5 💡 Commit streak / contribution sparkline
A tiny "Your week: ▂▄▆█" sparkline in the status bar (local `git log --author
--since` — no network). Pure fun, zero privacy cost, and makes the app feel alive.

### Q6 💡 GitHub language-color dots for changed files
A 6pt colored dot per file using GitHub's `linguist` colors (ship the tiny JSON
map, key by extension). Instantly readable change lists, pretty, quirky in a
good way.

### Q7 💡 Merge-conflict "ghost preview"
When a file is conflicted, show a three-pane mini-preview (ours/base/theirs
side-by-side with conflict hunks highlighted) before the user picks Ours/Theirs —
turns the blind "Ours/Theirs" buttons into an informed choice. (`git checkout
--conflict=diff3` + existing DiffParser gets you most of the way.)

### Q8 💡 Sparkline of repo activity in the sidebar row
A 30-day commit sparkline behind each repo row (like Netlify's deploy graphs).
Cheap (`git log --since` counts), gorgeous, and makes the sidebar feel alive.
Must be cached per day, not per refresh.

### Q9 💡 "What's different here?" ambient hint
When the working tree is dirty for > N minutes, subtly tint the Changes tab
segment (or badge it). Nudges toward committing without a modal nag.

### Q10 💡 Terminal-flavored error messages with copy-paste fixes
When git fails with a known class of error (detached HEAD push, non-fast-forward,
lock file exists), show a "GitEnough hint" line under the raw error with the exact
button to press ("Pull first", "Force push"). Error → action, not error → fear.

### Q11 💡 Egg: konami-style graph rainbow
Press ⌥⌘G on the History tab → lane colors animate through the palette once.
Zero value, pure joy, one Canvas `withAnimation`. (Ship behind a build flag if
worried about taste.)

### Q12 💡 Drag a commit onto a branch row (cherry-pick / rebase gesture)
Direct-manipulation git: drag commit C onto branch B → menu "Cherry-pick C onto
B / Rebase B onto C". Draggable & droppable rows exist; the git plumbing exists.
Very demo-worthy.

---

## 9. Prioritized implementation queue

Ordered by (user value × confidence) ÷ effort, considering CI-testability (no local
macOS runner — logic must be provable via `GitEnoughTests` on GitHub's macos-14):

1. **B2** exclude stash from graph — tiny, testable, immediate correctness win
2. **B1** rebase/cherry-pick/revert conflict support — the biggest correctness gap
3. **B3** publish to the actual remote name — tiny + integration test
4. **B4+B5** off-main validation + visible drop failures — UX + rule compliance
5. **G4** parallel sidebar summaries — small perf win
6. **M1** history filter (rows + relaid graph) — top missing feature, testable matcher
7. **V2** word-level diff highlighting — parser-pure, most visible "wow"
8. **B6/B7** selection-staleness fixes — small but real
9. Then: M6 (reveal/open), V1/V3 (diff gutter/split), U1/U2 (keyboard), Q1 (undo),
   M2 (blame), M3 (squash), M4 (tags), Q2 (palette), Q3 (trace), P1 (lazy graph)

Entries verified as non-issues (V13) are kept for the record with a note.
