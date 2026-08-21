# GitEnough — GLM Review (2026-08-21)

An independent, full-codebase review of GitEnough at `f9bea7e` (main, post-#35).
Scope: every source file under `GitEnough/` and `GitEnoughTests/`, the CI setup,
and the existing `ANALYSIS.md` backlog (cross-referenced so this document adds
findings rather than duplicating them — entries below that merely confirm an
ANALYSIS.md item say so and are marked **[confirms X]**).

Reviewed categories: bugs, general/architecture issues, performance, missing
features, visual/layout problems, UX/interaction, aesthetics, and
novel/delightful ideas. Effort: **S** ≤ ~30 min · **M** half a day · **L** multi-day.

---

## Bugs & correctness

### GLM-B1 · Local branches with slashes render as remote-branch chips — S
`GitParsers.parseDecorations` classifies any decoration containing `/` as
`.remoteBranch`. Local branch names are allowed to contain slashes and very
commonly do (`feature/auth`, `bugfix/crash-on-save`). A commit decorated with a
non-HEAD local branch `feature/auth` gets a gray "network" chip instead of the
accent-colored branch chip — mislabeled kind, wrong color, wrong icon, and it
would confuse the planned V4 decoration popover (click-to-checkout would be
offered for what is actually a local branch).

**Fix:** make classification remote-aware. `collectSnapshot` already runs
`remotes()` before `log()`, so pass the known remote names down:
`parseLog(_ output:remoteNames:)` → a part is `.remoteBranch` only when it
starts with `<remote>/` for a configured remote; otherwise a slash-part is a
local branch. When `remoteNames` is empty (callers that don't know the remotes)
fall back to today's heuristic. Tests: `feature/auth` alone → localBranch;
`origin/feature/auth` → remoteBranch; `origin/feature` with remoteNames
`["upstream"]` → falls back to the slash heuristic. Also covers `%D` parts
like `refs/…`? Not needed — `%D` is always short names.

Note for the future: ref names may legally contain `", "` and `\x1F`, which
would both break the `%D` split and shift `parseLog` fields. Worth a comment at
least (see GLM-B8).

### GLM-B2 · Menu Pull/Push bypass every toolbar guard — S
The Repository menu (⇧⌘L Pull, ⌘⇧P Push) only checks `active == nil`, while the
toolbar buttons correctly require an upstream (Pull) and swap Push→Publish when
there is no upstream. Consequences:
- Pull with no upstream → raw `There is no tracking information for the current
  branch` error banner.
- Push with no upstream runs a **plain `git push`**, which for users with
  `push.default=matching` (a not-rare legacy config) pushes *every* branch that
  name-matches a remote branch — a destructive surprise, and in every config a
  dead end with a raw error, exactly what `publishBranch()` was built to avoid.

**Fix:** route the menu actions through view-model helpers that mirror the
toolbar's logic: `pushOrPublish()` (publishes when `status.upstream == nil` and
remotes exist) and a guarded `pull(rebase:)` that sets a friendly
`errorMessage` when there is no upstream. A pure predicate
(`shouldPublish(upstream:remotes:)`) keeps it unit-testable; optionally also
disable the menu items by observing the active VM in `AppCommands`.

### GLM-B3 · Abort merge/rebase/cherry-pick has no confirmation — S
`RepoDetailView.operationBanner`'s "Abort Merge/Rebase/…" button fires
`abortOperation()` immediately. Aborting discards in-progress conflict
resolution work (resolved-but-uncommitted files snap back) — it is the most
destructive unguarded action in the UI; even `reset --hard` asks first. A
one-line `confirmationDialog` naming the operation fixes it. Guard the same
path if a keyboard shortcut is ever added.

### GLM-B4 · Watcher double-snapshots every operation — S (perf-adjacent)
Every op that mutates repo state changes `.git` mtimes, so after `perform`'s own
snapshot the `RepoWatcher` tick fires a **second** full snapshot (status,
branches, remotes, stash, merge-state probes, `log --all --topo-order` — six
process spawns) for the same state. Net effect: each user op does ~12 spawns
where 6 suffice; on big repos that's the difference between a snappy and a
sluggish feel after every commit/stage/checkout.

**Fix:** suppress watcher-triggered refreshes while an op is in flight *on the
same serial queue* — increment a counter before `work`, decrement after
`collectSnapshot` (all on `queue`, so no locking needed); the watcher tick
(main-thread-created, fired on `queue`) skips **without** updating
`lastSignature`, so a genuinely external change that happened during the op is
still picked up by the next tick. Testable by driving the VM with a stub
client... today there is no seam (see G9); minimal test: RepoWatcher-level unit
for the "skip must not consume the signature" behavior.

### GLM-B5 · Repo renamed on disk keeps a stale sidebar name forever — S
`Repository.name` is snapshotted at registration and persisted. Rename the
folder on disk (or re-clone under a new name) and the sidebar label, window
title, and activity history keep the old name indefinitely — the path is right,
the label is wrong, and the only remedy is remove + re-add (which also loses
star/manual order/last-opened metadata). **Fix:** opportunistically refresh the
display name in `AppState.refreshSummaries` (path's lastPathComponent) via a
`RepoStore.refreshName(_:for:)` that preserves identity/order/stars.

### GLM-B6 · Dropping a *file* produces a misleading error — S
The sidebar drop accepts any `fileURL`. Dropping a regular file inside a repo
can't become a Process cwd, so validation fails with "not inside a git
repository" — misleading. Resolve dropped files to their parent folder before
validating (a dropped `README.md` almost always means "add the repo containing
it"), and/or check `hasItemConformingToTypeIdentifier(.directory.identifier)`.

### GLM-B7 · Activation does a full history walk — S/M (perf)
`applicationDidBecomeActive` → `refresh(includeHistory: true)` on every Cmd-Tab
back into the app: a whole-repo `git log --all --topo-order` plus five more
spawns per activation, regardless of whether anything changed. The watcher
already polls the same state every 2.5 s. **Fix:** on activation refresh
summaries + scan (cheap) and refresh the active repo *without* history unless
the watcher signature actually moved — `RepoWatcher.lastSignature` is exactly
the right predicate if exposed read-only.

### GLM-B8 · `parseLog` field-shift on control characters in subjects — S (hardening)
A commit subject containing the field (`\x1F`) or record (`\x1E`) separator
(creatable via `git commit -m $'\x1f'`) shifts fields: author/email/date/
decorations mis-parse and one poisoned commit can swallow its neighbors in the
record split. Pure display corruption, no security impact, but cheap to harden:
after splitting, validate that fields[0] looks like a 40-hex hash and
fields[4] parses as a date; drop the record otherwise. Worth one test.

### GLM-B9 · `fetch --all` fans out to every remote — S/M (config-dependent)
`fetch()` runs `git fetch --all --prune --tags`. On repos with many remotes
(collaborator forks, multiple upstreams) every fetch button press and every
auto-fetch interval hits all of them — slow, and `--prune` on a remote whose
branches were hand-deleted there produces surprising ref deletions. GitHub
Desktop fetches the preferred remote only. **Fix:** default the button to the
preferred remote (`fetch(remote:)`), keep "Fetch All" as the ⌥ variant or a
menu item. Pairs with the status-bar remote-label fix (GLM-V6).

### GLM-B10 · Staged-rename rows lose the "old → new" information — S (visual, see GLM-V1)
Both the Changes lists and the commit-detail file list render only
`file.path`; `originalPath` is parsed and never shown. A staged rename shows as
an inscrutable "R path" with no hint of the source name. Fix under GLM-V1.

### Confirmed / extended known items (do not re-file)
- **[confirms B9]** commit-detail spinner on load failure (PR #41 open).
- **[confirms B11]** `gone` upstream dropped (PR #40 open).
- **[confirms B14]** merge-commit cherry-pick needs `--mainline` (PR #39 open).
- **[confirms G9-3]** `AppState.viewModel(for:)` still runs inside
  `ContentView.body` and menu evaluation — the single remaining structural
  smell; everything else in G9 landed.
- **[confirms P2]** `loadMoreHistory` still refetches from skip=0 and re-lays
  the whole graph.
- **[confirms B13]** `RelativeDateText` still renders once.
- **[confirms G2]** unbounded VM/watcher retention still true; with the
  sidebar now auto-discovering repos, this got *more* likely to matter
  (a watch folder can silently accumulate dozens of live VMs).

---

## General / architecture issues

### GLM-G1 · `RepoViewModel` still lacks a test seam — M **[extends G9]**
Every plan above that wants VM-level tests (GLM-B2, GLM-B4) hits the same wall:
`GitClient` is constructed in `init` with the shared shell. An injectable
`GitClient` (protocol or init parameter) unlocks regression tests for the
perform→snapshot→apply contract, the busy-counter fix (G9-1), and the
watcher-suppression contract (GLM-B4). Highest-leverage single refactor left.

### GLM-G2 · No multi-select anywhere in the Changes lists — M
Rows act one at a time; stage/unstage/discard of "these 5 files" means five
clicks (or "All"). List `selection:` with `Set<FileChange>` + toolbar actions
would match GitHub Desktop and cut most repetitive staging in half. Needs the
row identity to survive staged↔unstaged moves (the selection-following logic in
`ChangesView.onChange(of: viewModel.status)` is the seed of it).

### GLM-G3 · Error surface is one transient banner — S/M **[extends V7/Q10]**
`errorMessage` is a single optional string: a second failure overwrites the
first, ops clear it at start, and there is no history of what failed beyond the
activity log's stderr tails. Minimum viable: keep the banner but (a) never
auto-clear an unread error on the *next* op start (mark-seen instead), (b) add
the expand/copy affordances from V7. Larger: an "Issues" list. Even the
activity-history window (which has the data!) doesn't link failures to the
banner.

### GLM-G4 · `GitClient.pull` hardcodes `--tags` — S
`git pull --tags` fails outright ("would clobber existing tag") when a remote
tag moved — rare but baffling, and `--tags` adds nothing to a pull's job
(fetch already passes `--tags`). Drop it from pull; keep it on fetch.

---

## Performance

### GLM-P1 · History filter re-runs on every selection click — S
While a filter is active, `visibleCommits` re-filters the entire loaded history
on *every* body evaluation — including every row click (selection change) and
every snapshot apply (watcher tick every 2.5 s). `localizedStandardContains` is
locale-aware and not cheap; at 3–5k loaded commits that's real work per click.
**Fix:** cache the filtered array in `@State`, recompute only when
`activeFilter` or `viewModel.commits` identity changes (`onChange`). Micro but
free, and it compounds with P2's bigger commits arrays.

### GLM-P2 · `commitRows` builds `Array(visible.enumerated())` per body — S
Fold into GLM-P1's cached state; same trigger, same fix.

### GLM-P3 · Status-bar `ForEach(runningActivityEntries)` re-sorts per render — S
`runningActivityEntries` filters `activityEntries` (up to 100) on every status
bar render; the timer-driven `Text(startedAt, style: .timer)` re-renders it
every second. Trivial cost today, but it re-filters *every repo's* view model
chain; compute once in the VM (a `@Published runningCommands` maintained in the
onChange hop). Optional polish.

(All other perf items worth doing remain P1/P2/G1/G3 in ANALYSIS.md; the
diff-parse memoization and per-row graph strips landed and work well.)

---

## Missing features (beyond ANALYSIS.md's M-list)

### GLM-M1 · Branch recency ("last commit 3 days ago") in the branch list — S
`for-each-ref` can emit `%(committerdate:relative)` for free; BranchesView rows
would gain the single most useful missing datum — which branches are alive.
Doubles as stale-branch triage and makes the ahead/behind columns meaningful.
Pure parser work + one column; trivially testable. (Implemented during this
review — see PRs.)

### GLM-M2 · Multi-select staging — see GLM-G2.

### GLM-M3 · Files-changed totals bar in Changes — S
"+123 −45 across 4 files" as a one-line summary of the staged (or all) diff —
`git diff --numstat` + `--cached --numstat` are cheap (no patch bodies). Gives
the Changes tab the "PR summary" feel and answers "how big is this commit about
to be" at a glance.

### GLM-M4 · Per-repo commit-draft restore prompt — S **[extends M22]**
M22 wants persistence; even before that, losing a typed message on repo switch
(today: kept, since drafts live on the VM — good) vs app quit (lost) is the
asymmetry to close. If M22 lands with per-repo keys, also restore *only* when
the box is empty, never over fresh typing.

### GLM-M5 · Parent-commit navigation in the detail pane — S/M
`CommitDetail.parents` is parsed and displayed nowhere. One small "⌘↑ parent"
chevron (or clicking the parents row) that selects the first parent in the
history list turns the detail pane into a walkable chain — classic archaeology.
Pairs beautifully with M7 (file history).

### GLM-M6 · ⌘F focuses the history filter — S
The filter field is keyboard-unreachable today; every list-first app binds ⌘F.
`@FocusState` + a Commands entry scoped to the History tab. Also consider ⌥⌘F
to focus the sidebar's repository search.

---

## Visual & layout

### GLM-V1 · Renames: display "old → new" — S
Changes rows and CommitDetail file rows show only the new path for `R` status.
Render `originalPath → path` (caption, middle-truncated) — the standard
convention from every other client. Data already parsed; pure view change.
(Implemented during this review — see PRs.)

### GLM-V2 · Status-bar remote label shows the wrong remote — S
`viewModel.remotes.first` renders the *first configured* remote's host, while
every actual operation uses the *preferred* remote (upstream's remote, else
origin, else first). On fork-style setups (origin=fork, upstream=canonical) the
label describes a remote you rarely push to. Show the preferred remote's host —
`preferredRemote()` already exists, it's just private. (Implemented — see PRs.)

### GLM-V3 · Commit-detail pane has no "N files, +x −y" summary — S/M
Header shows "N files changed" only; a numstat-derived "+x −y" (colored) is the
natural completion and reuses GLM-M3's plumbing.

### GLM-V4 · Conflicted-file rows lack a diff affordance — S
In the Changes conflicts section you can pick Ours/Theirs/tool, but can't
*look* at the conflict diff first (the right pane shows nothing for unmerged
paths since `diff(path:)` on an unmerged path errors quietly → "No diff").
`git diff` on a conflicted path shows the combined conflict diff and would make
Ours/Theirs an informed choice. One special-case in `selectFile`.

### GLM-V5 · Toolbar Publish/Push swap causes layout jump — S
The button swaps label (`Publish` ↔ `Push`) after a snapshot apply; in a
toolbar that's a visible pop. Prefer a stable single control whose *menu* grows
a "Publish branch to <remote>" first item when there's no upstream, or keep
both and disable the inapplicable one.

### GLM-V6 · Status-bar pill for ahead/behind — covered by A4 in ANALYSIS.md;
recommended implementation order: A4 + GLM-V2 together (same row).

### GLM-V7 · Graph lane squeeze has no minimum — S
`laneWidth(for:)` divides by column count with no floor; at 40+ lanes lanes
collide into an unreadable smear under `maxGraphWidth`. Consider a floor of
~4 pt with overflow scrolling (the column width cap then becomes the scroll
viewport), or collapse ultra-deep lane sets. Low priority; document the
trade-off either way.

---

## Interaction & UX

### GLM-U1 · Generate overwrites a hand-typed draft without asking — S
`generateCommitMessage()` assigns `draftCommitMessage` wholesale. If the user
typed half a message and hits ✨ for inspiration, their text is gone (no undo
across the VM write). Fix: only replace when the draft is empty or equal to the
last generated message; otherwise append under a divider or confirm. Tiny,
saves real annoyance.

### GLM-U2 · No feedback target for the "conflicts remain after tool exit" path — S
The merge-tool follow-up writes an errorMessage banner, but the user is staring
at the conflict row, not the banner; the row itself should show a "markers
remain" state. Pairs with GLM-V4.

### GLM-U3 · Discard-all is missing — S/M
Deliberate conservatism is fine, but "Discard All Changes…" with the same
confirmation pattern as reset --hard is what people expect from the Changes
section header (Stage All is right there). Keep the Trash semantics for
untracked files.

### GLM-U4 · Filter field can't be reached or cleared by keyboard — S
See GLM-M6; additionally Esc inside the filter should clear it (the current
comment explains why a global `.cancelAction` is wrong — scope it with
`@FocusState` so Esc only applies while focused).

### GLM-U5 · `Open in Terminal` hardcodes Terminal.app — S
Honor the user's default terminal via `open -a` on the handler of
`com.apple.terminal`-shaped duties... macOS has no clean default-terminal API;
minimum: probe for iTerm2/WezTerm/Warp in `/Applications` before falling back
to Terminal. Cosmetic nicety.

### GLM-U6 · Activity popover timer rows keep re-rendering — S (polish)
`Text(startedAt, style: .timer)` per running entry is fine; when the graph
grows (P2) keep an eye on it. No action needed now; noted for the record.

---

## Aesthetics

### GLM-A1 · Sidebar row hierarchy is flat — S (design)
Repo name / path / branch+counts are three equal-weight lines; the branch line
carries two font sizes and three icons. Suggested order: name + star + dirty
dot (line 1), branch chip + ahead/behind (line 2), path only when hovered or in
compact mode. Sketch first; the current layout is *fine*, this is polish.

### GLM-A2 · Empty-pane icons are generic SF Symbols — S
`doc.text.magnifyingglass`, `clock.arrow.circlepath` etc. work, but the app now
has a designed icon language (media-sources); a tiny matching glyph set for the
3–4 empty panes would tie the visual identity together. Pure design task, no
code risk. (A1 in ANALYSIS.md wants the same; this is the concrete inventory.)

### GLM-A3 · Diff view header is bare — S
No file name, no +x/−y, no hunk count at the top of the diff pane; the user
must infer the file from the list selection. One sticky header line (path,
status badge, insertion/deletion counts colored green/red) dramatically
improves orientation, especially for long single-file diffs.

---

## Novel / delightful (beyond ANALYSIS.md's Q-list)

### GLM-Q1 · "Squash this into HEAD" — one-click fixup — S/M **[pairs M14]**
Context menu on any commit that is HEAD's *ancestor*: "Fixup into this commit"
runs `commit --fixup=<hash>`; combined with a future autosquash rebase this is
the two-click path everyone wants. Even without the rebase half, `--fixup`
commits are self-describing.

### GLM-Q2 · Branch tips as "cards" at the top of Branches — S (design)
Local branches with recency + ahead/behind (GLM-M1) render beautifully as a
2-column card grid (name, recency, dot for dirty tip) above the plain list —
makes the Branches tab feel like a dashboard instead of a `git branch -a`
dump.

### GLM-Q3 · Hover a graph lane → faint continuation preview — M **[cheaper cousin of Q3]**
Full trace-highlighting (ANALYSIS.md Q3) needs reachability computation; a much
cheaper first cut: hovering a row *slightly* emphasizes the segments of the
lanes passing through it (alpha bump on that row's strips only). Zero graph
algorithms, still feels alive.

### GLM-Q4 · "What would push send?" popover — S **[pairs M17]**
When ahead > 0, make the status-bar ↑N label a popover listing exactly those
commit subjects (the same `rev-list upstream..HEAD` M17 needs). Turns a number
into the answer people actually open a terminal for.

### GLM-Q5 · Commit-message "ghost text" from recent subjects — S **[cousin of Q17]**
Instead of autocomplete plumbing, show a subtle one-line suggestion under the
commit box: the most recent subject in this repo sharing the draft's first
word. Zero infra, surprisingly useful for "Bump …" chains.

### GLM-Q6 · Repo health line in the sidebar tooltip — S
Hovering a sidebar repo shows a 2-line tooltip: last fetch (needs Q16's stored
timestamp) + last commit recency. Cheap "is this thing alive?" signal without
opening it.

---

## Implementation notes for reviewers

Items implemented as PRs from this document during this review (each in its own
branch, tests included):

1. **GLM-B1** — remote-aware decoration classification (`parseLog` gains
   `remoteNames:`).
2. **GLM-B2** — `pushOrPublish()` + guarded pull for the Repository menu.
3. **GLM-B3** — confirmation before aborting an in-progress operation.
4. **GLM-V1** — "old → new" rendering for renames in Changes and CommitDetail.
5. **GLM-M1** — branch last-commit recency in BranchesView (parser + model + UI).
6. **GLM-V2** — status bar shows the preferred remote.

Everything else above is written to be shovel-ready for future waves, in the
same style as ANALYSIS.md.
