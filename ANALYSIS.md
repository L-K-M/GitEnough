# GitEnough — Analysis & Backlog (ANALYSIS.md)

A living, shovel-ready backlog for GitEnough: every entry below is a concrete,
self-contained task with suggested approach and test plan, ready for an LLM (or
human) to pick up. This document consolidates two independent full-codebase
reviews (`glm.md` and `kimi.md`, each kept on its review branch as the unedited
record) with everything learned while implementing the first waves of fixes.
**Maintenance rule:** when an entry ships, delete it here (the git history
preserves it); when a new issue is found, add it with the same level of
concreteness.

Effort: **S** ≤ ~30 min · **M** half a day · **L** multi-day.

---

## Status snapshot (do not re-implement)

The first wave from the review is **open (reviewed, unmerged) as PRs** — check
before starting anything overlapping:

| PR | Covers |
|----|--------|
| #4 | Stash & synthetic tool refs (refs/original, bisect, prefetch, notes, replace, rewritten) excluded from the graph + decorations |
| #5 | Rebase/cherry-pick/revert conflict detection, banner, Continue/Abort, visible conflicts (+ #11, an independent lighter version that also adds Skip and `git am` exclusion) |
| #6 | Publish to the actually-configured remote (prefers origin), model-level guard |
| #7 | Repo validation off the main thread; drop-failure alert (+ #20 partially, drop-error alert) |
| #8 | Sidebar summaries refreshed concurrently (windowed TaskGroup); live summary updates via onStatusChange (on main) |
| #9 | Discard of staged changes (was a silent no-op — `checkout --` only restores the worktree); `:(literal)` pathspecs |
| #10 | History search/filter: subject/author/email/hash/decorations, subset lane re-layout (+ #13, lighter duplicate) |
| #12 | Diff parsing memoized out of `DiffView.body` |
| #14 | Word-level (intraline) diff highlighting |
| #15 | Commit-box guardrails: 72-char subject counter, amend-after-push warning |
| #16 | Stale selection fixes: repo switch remount (`\.id`), selection follows files across stage/unstage |
| #17 | Create tags from the history context menu (annotated/lightweight; leading-dash names rejected) |
| #18 | Show in Finder / Copy Path / Open in External Editor on file rows |
| #19 | git version in Settings fetched off-main, cached per appearance |
| #20 | ISO8601 formatter race, merge-tool probe caching, drop-error alert, New Window command removed |
| #21 | Graph lines attach to row-center dots, sidebar filter fix, logical filters, full-height selection |
| #22 | "Ignore in .gitignore" context menu for untracked files (literal escaping, `check-ignore` short-circuit) |
| #23 | Auto-fetch setting (never/5/15/30/60 min, off by default) |

Verified non-issue, kept for the record: **graph width never includes trailing
free lanes** — every lane is either occupied (drawn to the last row) or was
claimed by a node, so `columnCount` never exceeds `maxNodeColumn + 1`. Don't
re-audit.

---

## Bugs & correctness

### B9 · Failed commit-detail load shows an eternal spinner — S
`CommitDetailView` renders `ProgressView()` whenever `selectedHash != nil` and no
detail is loaded; `RepoViewModel.selectCommit` uses `try?`, so a failed
`git show` (object gone after GC, corrupt repo) yields `nil` forever.
**Fix:** track load failure (e.g. `selectedCommitDetailFailed: Bool`) and show an
EmptyPane-style error state. Test: unit-test the VM state transition with a
stubbed client (or integration: request a bogus-but-shaped hash).

### B11 · `gone` upstream is dropped by the branch parser — S
`for-each-ref`'s `%(upstream:track)` can be `gone` (upstream deleted on the
remote); `GitParsers.parseBranches` only parses `[ahead N, behind M]`, so such
branches show no state. **Fix:** parse `gone` into a `upstreamGone: Bool` on
`Branch`, render as a small warning ("✗ upstream gone") in `BranchesView` rows
and the branch picker. Test: `GitParsersTests` with a `gone` track field.

### B12 · Merge-tool concurrency guard is racy and over-strict — S
`RepoViewModel.openMergeTool` refuses a second tool while one is open, but the
`mergeToolActivity == nil` check isn't atomic (double-click race), and refusing
is unnecessary — FileMerge/Kaleidoscope happily open multiple windows.
**Fix:** track open tools in a `Set<String>` of paths (main-thread guarded),
drop the blanket refusal, keep one refresh per tool exit.

### B13 · Relative dates go stale — S
`RelativeDateText` renders "2 minutes ago" once; the string only updates on an
unrelated re-render. **Fix:** wrap the row text in
`TimelineView(.periodic(from: .now, by: 60))`. Note #20 fixed a formatter race
here; staleness itself remains. Watch List perf with 300 rows — the periodic
timeline only re-evaluates visible rows if used inside the LazyVStack rows.

### G8 · Detached-HEAD "Publish" semantics unclear — S
`push -u origin HEAD` in detached HEAD does something surprising (creates/uses a
remote branch literally derived from HEAD's state; git's behavior differs by
version). **Fix:** disable Publish while `status.isDetached`, tooltip explains;
optionally offer "Create branch at HEAD…" from the same menu.
Test: integration — bare remote + detached HEAD, assert the UI path is guarded
(unit-test the `canPublish` predicate).

### P3 · `onChange(of: viewModel.commits.map(\.hash))` maps all hashes per render — S
`HistoryView` builds a full hash array on every body evaluation just to detect
"selection vanished". **Fix:** `firstIndex(where:)` for just the selected hash,
or compare a cheap derived value (count + first/last hash). Micro, but free.

### B14 · Cherry-pick / revert of a merge commit fails cryptically — S
`git cherry-pick <merge>` needs `--mainline 1`; today the user gets git's raw
"is a merge but no -m option was given" in the error banner.
**Fix:** in `HistoryView.commitContextMenu`, when `commit.isMerge`, either pass
`-m 1` (add a `mainline` parameter to `GitClient.cherryPick`/`revert`) or gate
the menu items behind a confirmation that explains the parent choice.
Test: integration — merge commit, cherry-pick onto a side branch, assert the
resulting tree matches the merge's first-parent diff.

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
alive forever; 20 repos → 20 timers forever. **Fix:** pause watchers for repos
that aren't selected (resume on select/activation), or evict view models not
visited within a TTL (keep scroll cache cheap to rebuild). Careful: the summary
live-update wiring (main) must survive eviction.

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
while at it).

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
`includeHistory == false` (benign Int race — capture locally); (3)
`AppState.viewModel(for:)` is called inside `ContentView.body` and from menu
evaluation, so VMs are created and git work starts as a view-body side effect
(derive a `selectedViewModel` from `selectedRepository` + explicit start).
**Fix:** introduce a test seam (injectable `GitShell`/`GitClient`) and cover the
perform → snapshot → apply contract, then fix 1–3 with tests watching them.
Also: consolidate duplicated formatting helpers (`RelativeDateText`,
`Remote.displayHost`, sidebar path abbreviation) into one `Formatters` file.

---

## Performance

### P1 · The whole-history Canvas is one giant non-lazy view — M/L (top perf item)
`GraphCanvasView` sizes to `rows × 27pt` and redraws **every** segment/node on
any state change (selection included). Rows are lazy; the graph isn't — after a
few "Load more"s that's an ~80 000 pt layer re-rasterizing on each click.
**Fix (preferred):** render the graph in per-row slices — each `CommitRowView`
draws its own slice (segments crossing into row r±1 owned by row r), making
both columns lazy and redraw O(visible). Alternative: keep the single canvas
but draw into it only for the visible window (GeometryReader bounds → segment
filter). Keep `GraphMetrics` the single source of truth either way.
Note #21 moved endpoints to row centers and fixed attachment — build on that.
Test: pure layout slice extraction (`GraphLayout.segments(in rows:)`) with unit
tests; no behavioral change assertions.

---

## Missing features (ranked)

### M2 · Blame view — M
The last classic read-only git view missing. `git blame --porcelain -- path`
parses cleanly (header lines + "\t<line>" bodies). Plan: `BlameParser` (pure,
tested like `GitParsers`), `GitClient.fileBlame(path:)`, a `BlameView` (rows
with author/date/commit chip, monospaced text), entry points from Changes file
context menu and CommitDetail files. Reblame-on-click (blame from parent) is a
nice follow-up.

### M3 · Squash merge + `--no-ff` option — S/M
`merge()` is always `git merge --no-edit`. Add modifiers to the merge
confirmation dialog in `BranchesView`: Squash (`--squash` then the normal commit
box flow — staged changes + message), and optionally `--no-ff`. VM:
`merge(branch:squash:noFF:)`. Test: integration — squash merge produces a
single commit with both branches' changes.

### M4-remainder · Tag management beyond creation — S
#17 adds create-from-commit. Still missing: delete tag (context menu on the
chip in history or a Tags section in Branches), and a Tags list per repo
(`for-each-ref refs/tags` — extend `branches()` or add `tags()`).

### M5 · Force push / push options — S/M
No `--force-with-lease` anywhere (people fall back to the terminal).
Plan: Push button → menu with "Force Push (with lease)…" + confirmation dialog
explaining lease semantics; disable when branch has an upstream that hasn't
moved. Test: integration with a bare remote — diverge, force-push, assert
remote tip.

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
"commits not on any remote" (derive from `merge-base` with upstream).
This is the flagship follow-up after the basics; design first, then implement.

### M16 · Submodule awareness — M/L
`Submodule` diff lines parse as meta only. Add: dirty-state indicator for
submodules in status, "Update Submodules" (`submodule update --init --recursive`)
in the Repository menu, and don't offer stage/discard on submodule paths (or
handle them via `submodule` subcommands).

### M17 · Unpushed-commit markers in history — S
Show which commits `push` would send at a glance: one
`git rev-list @{upstream}..HEAD` in the snapshot → hollow dot or "↑" on those
rows in `HistoryView`. High information density for one extra read-only call.
Test: integration with a bare remote — ahead by 2, assert exactly those two
hashes are flagged; unpushed flag clears after push.

### M18 · Pull rescue for dirty trees (autostash) — S
`git pull` with a dirty tree fails with git's raw message. Offer "Stash, pull,
pop" as a one-click recovery in the error path, or make
`pull --rebase --autostash` a Settings option (one flag). Pairs naturally with a
split-button Pull menu (Pull / Pull (Rebase) / Pull (Autostash)) in the toolbar
instead of today's Settings-only toggle.

### M19 · Hunk / line-level staging — L
The power feature (`git add -p` semantics via `git apply --cached` with a
constructed patch). Hunk checkboxes in `DiffView`, patch reassembly in a pure,
exhaustively tested type (hunk headers must be rewritten when lines are
deselected). Large but transformative for the Changes tab.

### M20 · Remote management UI — S/M
Beyond #6 (publish to the configured remote): add/remove remotes
(`git remote add/rm`), view their URLs, push to a non-origin remote. Natural
home: a Remotes section in the Branches tab + a remote picker on Publish.
Test: integration with two bare remotes.

### M21 · "Ignore Locally" via `.git/info/exclude` — S
Follow-up to #22: companion context action that appends to `.git/info/exclude`
instead of the shared `.gitignore` — for personal scratch files that mustn't be
committed to the shared ignore file. Reuses the `GitIgnore` helper verbatim;
only the target path differs (resolve via `client.gitDir()`).
Test: integration — ignored file disappears from status without touching
`.gitignore`.

### M22 · Per-repo commit-draft persistence — S
The draft message survives tab switches but not app restarts or repo switches.
Persist per repo in UserDefaults (keyed by repo path), restore in
`RepoViewModel.init`, clear on successful commit (the existing onSuccess hook).

### M23 · Spell checking in the commit box — S
SwiftUI's `TextEditor` doesn't spell-check by default; commit messages deserve
squiggles. One modifier; verify it doesn't fight the 72-char counter layout.

---

## Visual & layout

### V1 · Diff line numbers + gutter — S/M
Add old/new line-number columns and a +/- gutter to `DiffView`. Requires hunk
parsing to track running line numbers (extend `DiffParser`: emit line numbers on
each `DiffLine`, or a parallel array). Monospaced alignment; dim gutter color.
Test: parser unit tests for number computation across hunks/multiple files.

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

### V5-remainder · Empty states — S
History tab on a zero-commit repo (fresh `init`) is blank — add an EmptyPane
"no commits yet, make your first in Changes". Branches tab without remotes: hint
that publishing creates them. (#10 added the filtered-empty state only.)

### V6 · Permanent "Drop a folder" hint — S
Show only while a drag hovers the sidebar (`isTargeted` on the List), or only
when the sidebar is empty.

### V7 · Error banner truncates long git output — S
`lineLimit(4)`, no expansion. Add a chevron to expand, monospaced scrollable
body, and a Copy button next to dismiss. Hook failures regularly exceed 4 lines
with the useful part last.

### V9 · Date column width — S
Fixed 110 pt truncates with longer localized formats; measure or use
`fixedSize` + layout priority. Verify with a pseudo-localization build
(×LL length strings).

### V11 · File-type icons / language-color dots — S/M
Status letters only today. SF Symbol per extension (swift, py, md, json, png…)
or GitHub-linguist color dots (ship a tiny bundled JSON keyed by extension).
Renders in Changes rows and CommitDetail file lists.

### V12 · Accessibility pass — M
The graph Canvas is opaque to VoiceOver; rows/chips lack labels. Add
`.accessibilityElement(children: .combine)` with "commit <subject> by <author>,
<relative date>, refs: …" on rows; give RefChip an explicit label; give the
graph an accessibility summary ("history graph, N commits").

### V13 · Empty diff pane flashes during load — S
Selecting a file briefly shows the "No diff" empty state until the diff arrives,
even though `isLoadingDiff` exists on the view model. Show a spinner while
loading; keep the empty state for the truly-empty case only.

---

## Interaction & UX

### U1 · Keyboard navigation in the history list — M
The list is `ScrollView` + tap rows: no arrow-key selection. Introduce move
up/down via `.onMoveCommand` (or wrap rows in a focusable list), keep ⏎ to open
detail, and maintain `selectedHash`. Must keep the graph selection highlight in
sync (it keys off `selectedRow`, so it comes free).

### U2 · Stage/unstage/discard shortcuts — S
⌘⇧↑/⌘⇧↓ (or ⌥↑/⌥↓) for stage/unstage selected change; ⌫ opens the discard
confirmation; ⌘⇧N new branch. Wire in `ChangesView` via `.keyboardShortcut`
on the row actions or hidden menu commands.

### U3-remainder · Copy branch name — S
#18 covered file paths. Add "Copy Name" to branch rows and the branch picker;
"Copy Subject+Hash" (`hash subject` — the reflog-friendly format) to commit rows.

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

---

## Aesthetics

### A1 · Empty-state art — S (design)
Done for the icon: `scripts/make-icon.js` now derives every appiconset slot
from the designed artwork in `media-sources/icon.png` rather than drawing the
old procedural lane-graph glyph, so regenerating can't revert it. Empty states
should pick up the same visual language.

### A2 · Date grouping in history — S/M
"Today / Yesterday / This week / …" section headers (or subtle separators) in
the history list; compute buckets from `commit.date` cheaply per row render.

### A3 · Density setting — S/M
27 pt rows are comfy; a "Compact" mode (22–24 pt, smaller font) helps big
histories. `GraphMetrics` must become dynamic (environment-injected) — keep it
the single source of truth shared by canvas and rows.

### A4 · Status bar polish — S
Group ahead/behind into one pill ("↑2 ↓1"); make the remote label a
click-to-fetch target; "N stashed" becomes the stash popover (U8).

### A5 · Lane-colored branch chips — S/M
RefChips for HEAD/local branches use the same accent color at two opacities.
Tint each local-branch chip with the *graph lane color* of the branch tip
(derivable: layout node color for the decorated commit) — pretty and functional
(chips match lanes). Needs a per-commit `colorIndex` lookup exposed from the
layout (it exists on `Node`).

### A6 · Dark-mode contrast check of the palette — S
The graph palette switches brightness only; verify WCAG-ish contrast on OLED
black and possibly desaturate. Mechanical pass with the color math in
`GraphCanvasView.laneColor`.

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
("Pull first", "Force push…"). Map on `GitError.message` matching; keep the raw
text always visible.

### Q11 · Graph rainbow easter egg (⌥⌘G) — S
One-shot palette animation on the History tab. Zero value, pure joy; ship
behind a build flag if taste is a concern.

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

---

## Suggested next pickups (highest value first)

1. **G1** cancel/timeout for network ops (robustness foundation for M9)
2. **P1** lazy per-row graph rendering (top perf item; builds on #21)
3. **M2** blame view (last missing classic view)
4. **M3** squash merge (everyday parity)
5. **M17** unpushed-commit markers (one rev-list call, big clarity win)
6. **M18** pull autostash rescue (small, removes a common raw-error dead end)
7. **M5** force-with-lease push (safety)
8. **U1/U2** keyboard navigation + shortcuts (feel)
9. **V1/V3** diff gutter + split/whitespace toggles (review quality)
10. **Q1** reflog undo (differentiator)
11. **Q2** command palette (differentiator; unlocks everything else)
12. **M15** minimal interactive rebase (flagship feature)
13. **Q13/Q14** gravatar avatars + "Explain this commit" (cheap delight)
