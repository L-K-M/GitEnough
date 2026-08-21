# GitEnough — flash review (independent full-codebase pass)

A fresh, independent review of the whole codebase (all 41 Swift sources + tests),
done after the first review waves already shipped. **Entries marked NEW were not
in ANALYSIS.md before this pass.** Entries referencing `ANALYSIS.md Bxx/Pxx/…`
are re-confirmations or sharpened versions of already-tracked items — they are
kept here only when this pass adds new detail worth preserving; the merge step
consolidates them into the existing backlog.

Verdict up front: the code is in unusually good shape for an AI-built app. The
serial-queue model, the pure/parser discipline, the per-row graph strips, the
memoized diff parsing, and the "removal sticks" bookkeeping are all solid
architecture. The problems below are mostly **sharp edges at the seams** —
places where two subsystems meet (watcher × refresh, menu × tab-local state,
discovery × bare repos), plus a pile of small UX dead ends.

---

## 1. Bugs & correctness

### B-NEW-1 · Stash is unreachable with staged-only changes — S
**NEW.** The only "Stash…" button lives in the *Changes (unstaged)* section
header of `ChangesView`, which renders only when
`!viewModel.status.unstaged.isEmpty`. A user who has **staged** everything (the
normal "I'm mid-work, stage + stash to switch branches" flow) sees no stash
button anywhere — not in the toolbar, not in any menu. Real workflow dead end.
**Fix:** show "Stash…" in the Staged header too (or move it into the commit box
row / add a Repository-menu command, which needs the stash sheet hoisted to
`RepoDetailView`). Test: UI-level — hard to unit test; keep it a layout change
reviewed visually, plus (optional) a menu command that's trivially testable.

### B-NEW-2 · Watch-folder discovery registers bare repos and submodules — S
**NEW.** `RepoDiscovery` treats *any* entry named `.git` as "this is a
repository": a **bare repo** (`.git` is a directory, `core.bare = true`) gets
added to the sidebar and then shows the yellow "missing or no longer a git
repository" triangle forever (status fails: no worktree). A **submodule** (`.git`
is a *file* whose `gitdir:` points at `…/.git/modules/…`) is likewise added as a
sidebar entry — a duplicate-ish row the user never asked for, sitting next to
the parent repo's own entry. **Fix (in `RepoDiscovery`, no git spawns):**
- `.git` file → read it; if the `gitdir:` line contains `modules/`, it's a
  submodule — skip (still a boundary: don't descend).
- `.git` directory → read `.git/config`; if it contains a `[core] bare = true`
  line, it's bare — skip.
Test: extend `RepoDiscoveryTests` with a bare `.git` dir (+config), a submodule
`.git` file, and a linked-worktree `.git` file (must still be found).

### B-NEW-3 · Settings window clips the AI tab — S
**NEW.** `SettingsView` forces `.frame(width: 480, height: 360)` on the TabView.
The AI tab (provider picker + base URL + API key + model field + Save/Load/Test
row + status text + caption) is taller than 360 pt; a grouped macOS Form does
not scroll, so the bottom (very likely the buttons/status) is clipped on
default font sizes. **Fix:** wrap each tab's `Form` in a `ScrollView`, or drop
the fixed height and keep `.frame(width: 480)` so the Settings window sizes to
the tallest tab. Test: visual; open Settings on a 13" screen with default
Dynamic Type.

### B-NEW-4 · `GitShell.runChecked` fallback error message is misleading — S
**NEW.** When git exits non-zero with *empty* stderr, the synthesized message is
`"git \(args.first ?? "") failed with exit code N"` — `args.first` is always
`-C` for every `GitClient` call, so users see **"git -C failed with exit code
128"**. **Fix:** strip the leading `-C <worktree>` pair before picking the
command name (same logic `GitActivityLog.displayCommand` already has). Test:
`GitShellEnvironmentTests`-style unit test of the message builder (extract it).

### B-NEW-5 · `HistoryView` selection vs. detail-pane race on refresh — S/M
**NEW (sharpening of B9).** `selectedCommitDetail` is set by `selectCommit` from
a `try?` — if `git show` fails the detail stays `nil` and `CommitDetailView`
shows the eternal spinner (B9). Additional wrinkle found this pass: when a
refresh lands *while* a `git show` is in flight, `apply()` replaces `commits`
but the detail load still completes on the serial queue afterwards — normally
fine, but if the selected commit was garbage-collected between the click and the
`show`, the result is the same permanent spinner, and there is no way to clear
it short of selecting another commit. Fix as B9 says (failure state + EmptyPane);
also consider clearing `selectedCommitDetail` when `apply()`'s new commit list
no longer contains the selected hash.

### B-NEW-6 · `openMergeTool`'s "already open" refusal is worse than the race — S
**NEW (confirms B12 from the UI side).** The guard produces an error banner
"A merge tool is already open" even for a *different* file, and the non-atomic
read allows the double-open race B12 describes. FileMerge/Kaleidoscope handle
multiple windows fine; the only real invariant worth keeping is "one refresh
per tool exit". B12's plan (a main-thread-guarded `Set<String>` of open paths)
is right; this pass just confirms the user-visible sting: the banner appears
mid-conflict-resolution and looks like a bug.

### B-NEW-7 · Duplicate refresh storm on activation — S
**NEW.** At launch (and on every ⌘Tab back), the selected repo is refreshed
*three* ways: `ContentView.onAppear` → `refreshSummaries()` + `scanDiscoveryFolder()`,
`AppDelegate.applicationDidBecomeActive` → same two + a full `refresh(includeHistory: true)`
on the selected repo, and the 60 s `AppState` timer doing discovery again.
That's 2× the summary TaskGroup + a full `git log` + a filesystem walk per
activation. Harmless individually; together they make activation feel heavy on
big repos. **Fix:** drop the `onAppear` block (the delegate already covers
launch), or gate the delegate's full-history refresh behind "last refresh > N
seconds". Test: none needed; watch Activity Monitor on activation.

### B-NEW-8 · `git pull --tags` is redundant and can surprise — S
**NEW.** `GitClient.pull` always passes `--tags`. Since git 2.35 `git pull`
already fetches tags like `fetch`; the explicit `--tags` additionally forces
tags that would otherwise be pruned/not-followed, so a repo with tag churn can
grow unwanted refs. Drop the flag (or make it a setting). Test: integration —
pull a repo where a tag was force-moved upstream; assert the local tag follows
the default behavior (doesn't move) with the flag removed.

### B-NEW-9 · `RelativeDateText` staleness + first-render hiccup — S
**NEW (confirms B13 with a new detail).** B13's `TimelineView(.periodic)` fix is
correct; this pass additionally notes the *first*-render cost: `RelativeDateTimeFormatter.localizedString`
runs once per row per render for 300 rows — cheap, but it recomputes on every
selection change (row re-render). The TimelineView fix doubles as a cache: only
the visible rows re-render, and only once per minute.

### B-NEW-10 · Conflicted-file rows have no diff — S/M
**NEW.** `ConflictRow` in `ChangesView` offers Ours/Theirs/Merge Tool but
selecting a conflicted file shows nothing in the diff pane (`selectFile` only
serves the staged/unstaged lists). For a user facing 20 conflicted files, there
is no way to even *see* the conflict markers in-app before picking a side.
**Fix:** make `ConflictRow` selectable and serve `git diff` output for the path
(the standard conflict diff already renders fine through `DiffView`); Q7's
ghost preview builds on the same path.

### Re-confirmed (already tracked, no new detail worth preserving)
B9 (spinner), B11 (upstream gone — **PR #40 open**), B12 (merge-tool race),
B13 (relative dates), B14 (merge cherry-pick — **PR #39 open**), B15 (CLT
shim), B16 (GPG pinentry), G8 (detached publish), G9 (isBusy flicker / VM as
body side effect).

---

## 2. Robustness / architecture

### R-NEW-1 · No cancellation or timeout anywhere — M
**NEW (confirms G1, adds a concrete observation).** Every `GitShell.run` is
`waitUntilExit()` with no timeout and no registry of live processes. A fetch
against a dead VPN blocks the repo's serial queue indefinitely — every button
in the toolbar is disabled while `isBusy`, and the Cancel affordance doesn't
exist. G1's plan (process registry + SIGTERM + Cancel button) is the right one;
this pass only notes that the **menu commands bypass the `isBusy` disable**
(`AppCommands` disables on `active == nil` only), so a user can stack a pull on
a hung fetch and make the pile-up worse.

### R-NEW-2 · Every repo ever opened polls forever — M
**NEW (confirms G2).** `AppState.viewModels` is never evicted; each VM runs a
2.5 s `RepoWatcher` timer that fires `collectAndApply(includeHistory: true)` —
six sequential process spawns every time the `.git` signature changes, for repos
the user isn't looking at. 20 repos × 6 spawns × change frequency is the
largest silent CPU consumer in the app. G2's pause-when-unselected plan is the
fix; consider pairing it with R-NEW-3.

### R-NEW-3 · Snapshot refresh = 6 sequential process spawns — M
**NEW (confirms G3).** `collectSnapshot` runs status → branches → remotes →
stash → sequencer probes → log strictly sequentially. All are read-only;
`for-each-ref` already returns most of what `remote -v` gives. On flutter-sized
repos this is the difference between a snappy and a sluggish refresh. G3's
TaskGroup windowing applies; measure first.

### R-NEW-4 · Watcher misses deep worktree edits — S/M (design note)
**NEW (confirms G5).** `RepoWatcher.signature` watches `.git` internals + the
worktree *root* mtime. An edit in `src/deep/path/file.swift` never ticks it —
the UI is stale until app activation (which the delegate refreshes, masking the
gap). Options stay: FSEvents, or an explicit "refresh" affordance. Document
whichever ships.

### R-NEW-5 · `RepoViewModel` untested; three compounding micro-races — M
**NEW (confirms G9 in full).** (1) `perform` clears `isBusy` when the *first* of
two queued ops finishes (menu commands don't check `isBusy`, so two queued ops
are reachable — R-NEW-1); (2) `Snapshot` reads the main-thread `@Published
canLoadMoreHistory` off-queue when `includeHistory == false`; (3) view models
are created and started from `ContentView.body` and menu evaluation. G9's
injectable-shell seam is the unlock for all of it.

### R-NEW-6 · `RepoDiscovery` runs unbounded per minute — S
**NEW.** `AppState`'s 60 s timer + activation both call `scanDiscoveryFolder`,
each doing a full `findRepositories` walk (≤ 4000 dirs). Fine for small trees;
a watch folder over a giant `node_modules`-heavy tree pays it twice a minute
forever. Cache the walk's result + mtimes and re-scan only when the folder
changed, or throttle to a longer interval. Low priority.

### R-NEW-7 · Bare-repo/`git`-file edge in `AddRepository` validation — S
**NEW.** `AppState.addRepository` validates with `rev-parse --is-inside-work-tree`
then `--show-toplevel`; both fail cleanly for a bare repo, so the *manual* path
is fine. Only discovery (B-NEW-2) is exposed. No action beyond B-NEW-2.

---

## 3. Performance

### P-NEW-1 · `DiffView.ParseCache` compares the whole diff string per render — S
**NEW.** `cache.lines(for: diff)` does `key == diff` — an O(n) equality over up
to 4 000 lines on *every* body evaluation (the parent re-renders on every
snapshot while dirty). It's cheap relative to the parse it avoids, but it can be
free: have the VM publish a monotonically increasing diff revision alongside
the string, or key the cache on a hash. Micro, but this is the hottest path in
the app (2.5 s watcher × dirty repo).

### P-NEW-2 · Active history filter re-runs over all commits on every click — S
**NEW.** `visibleCommits` re-filters the whole loaded set on every body
evaluation while `isFiltering` — including pure selection changes (each row tap
re-renders → re-filter 300–1 000+ commits). The debounce handles typing, not
clicks. Memoize on `(activeFilter, commits)`.

### P-NEW-3 · Full topo-order log on every refresh; pagination restarts at zero — M/L
**NEW (confirms P2).** `--topo-order` walks essentially all reachable history to
order the page, and `loadMoreHistory` re-fetches `skip=0…limit=n+1` and re-lays
the graph per page. P2's plan (cache + `--skip` appends + head-hash validation)
is the right shape; note the graph layout is pure and stable under prefix
extension, so the append path is unit-testable against full-layout equivalence.

### P-NEW-4 · Graph canvas is lazy *rows*, non-lazy *strips* — fixed already
Per-row `GraphStripView` (post-#21/#35) is the right design; the only
residual cost is 300 tiny Canvas layers at full page. Not a problem at current
page sizes; revisit only if "Load more" gets pressed a lot.

### P-NEW-5 · `HistoryView.onChange(of: viewModel.commits.map(\.hash))` — S
**NEW (confirms P3).** Maps 300+ hashes per body evaluation to detect a vanished
selection. Cheap fix: compare count + the selected hash's presence.

---

## 4. Missing features

### M-NEW-1 · History filter ignores branch/tag names — S
**NEW.** The filter matches subject/author/hash only. Searching "feature-x"
finds nothing even though every commit on that branch carries a
`RefDecoration`. Extend the predicate to decorations (branch/remote/tag names);
two lines, instant power. (This pass implements it — see PR list.)

### M-NEW-2 · Commit box: "committing as X <y>" + per-repo identity — S
**NEW (confirms M11).** No visible identity anywhere near the commit box; the
classic "wrong email pushed" pain is unfixable in-app. M11's per-repo override
is the full fix; a zero-cost first step is showing `git config user.name/email`
(read-only, cached per snapshot) as a caption under the commit box.

### M-NEW-3 · Copy Diff / "Open file at commit" — S
**NEW.** The diff pane and the commit-detail file list both lack a "Copy Diff"
action, and the commit-detail list lacks "Open in External Editor" (the Changes
list has it — the detail list only has Finder/Copy Path). Cheap, symmetric.

### M-NEW-4 · Diffstat bars in commit detail — S
**NEW.** The commit-detail file list shows status + path only. A tiny per-file
`+N −M` (from `--numstat`) or GitHub-style diffstat bar would make archaeology
much faster. Requires one more parse of `git show --numstat` output (pure,
testable).

### M-NEW-5 · "New Branch…" affordance in the Branches tab — S
**NEW.** Branch creation lives only in the toolbar + ⇧⌘B; the Branches tab —
where branch operations actually happen — has no create button. (This pass
implements it — see PR list.)

### M-NEW-6 · Stash everywhere (Repository menu, status-bar popover) — S/M
**NEW (confirms U8, sharpened by B-NEW-1).** Stash is only reachable from the
unstaged header. U8's menu item + ⇧⌘S + "N stashed" popover remains the full
fix; B-NEW-1 is its minimal emergency patch.

### M-NEW-7 · Unpushed-commit markers in history — S
**NEW (confirms M17).** One `rev-list @{upstream}..HEAD` per snapshot would mark
exactly the commits `push` would send. High info density for one read-only call.

### M-NEW-8 · Squash / `--no-ff` merge options — S/M
**NEW (confirms M3).** The merge dialog is single-button. Squash-merge is the
everyday "make the branch history tidy" move that Desktop users expect.

### M-NEW-9 · Blame view — M
**NEW (confirms M2).** Last missing classic read-only view; `--porcelain`
parses cleanly.

### M-NEW-10 · Force-push with lease — S/M
**NEW (confirms M5).** Nothing protects the fallback-to-terminal crowd.

### M-NEW-11 · Fetch/push progress + cancellation — M
**NEW (confirms M9 + G1).** The spinner says "busy", not "45 % of 1.2 GB".

### M-NEW-12 · Tags list + delete — S
**NEW (confirms M4-remainder).** Create exists (#17); list/delete doesn't.

---

## 5. Visual & layout

### V-NEW-1 · Settings AI tab clipping — S
See **B-NEW-3** (this pass's most visible layout defect).

### V-NEW-2 · `+N` decoration overflow is a dead end — S
**NEW (confirms V4).** Commits with >3 refs collapse to plain "+N" text.
Popover listing all decorations (click to checkout/copy) remains the fix; this
pass notes it's more common than you'd think — every repo with a release tag
on HEAD plus a branch shows it.

### V-NEW-3 · Empty states — S
**NEW (confirms V5).** Fresh `git init` → History tab is blank, Branches tab has
no "publish creates remotes" hint. #10 covered only the filtered-empty case.

### V-NEW-4 · RefChip colors are branch-kind-based, not lane-based — S/M
**NEW (confirms A5).** All local-branch chips share one accent tint. A5's
lane-color tie-in (chip color == graph lane color of the branch tip) is both
pretty and functional; the layout's per-node `colorIndex` is already there.

### V-NEW-5 · Diff line numbers + gutter — S/M
**NEW (confirms V1).** Without line numbers, the diff pane can't reference
"line 42" to anyone. Needs hunk parsing to track running numbers.

### V-NEW-6 · Sidebar rows are text-only — S
**NEW.** No folder glyph, no per-type icon, no language dots (V11). The rows
would read much faster with a small folder/icon leading the name.

### V-NEW-7 · Error banner: no expand, no copy — S
**NEW (confirms V7).** `lineLimit(4)` truncates exactly the diagnostics you need
most. Chevron-expand + Copy button.

### V-NEW-8 · WelcomeView is static — S
**NEW.** On a machine with 20 registered repos it shows one button and a hint.
Recent-repos list or a "resume where you left off" row would make first-run feel
less empty.

---

## 6. Interaction & UX

### U-NEW-1 · Keyboard navigation in history — M
**NEW (confirms U1).** ScrollView + tap rows = no arrow keys. The single most
felt gap for keyboard users; `.onMoveCommand` + selection sync is the plan.

### U-NEW-2 · Shortcuts for stage/unstage/discard — S
**NEW (confirms U2).** ⌘⇧↑/↓, ⌫-discard, ⇧⌘B exists for branches but nothing
for the changes dance.

### U-NEW-3 · Menu coverage is thin — S
**NEW.** Repository menu has Fetch/Pull/Push/PR/Branch/Refresh — no Stash, no
Stage All, no Discard All, no Commit. The three actions people do most (stage,
commit, push) are button-only in the tab; a ⌘↩ is there, stage-all isn't.

### U-NEW-4 · "⌘↩ to commit" hint — S
**NEW.** GitHub Desktop shows it; the box's placeholder could too
("Commit message — ⌘↩ to commit"). Two characters of onboarding.

### U-NEW-5 · Double-click conventions — S
**NEW (confirms U4).** Remote rows do nothing on double-click; history rows do
nothing. Tracking-checkout on remote double-click is the obvious one.

### U-NEW-6 · Background completion notifications — S/M
**NEW (confirms U6).** A 4-minute fetch finishing while the user is in another
app is invisible. Local notifications (errors only by default, Settings toggle).

### U-NEW-7 · Open-on-remote deep links — M
**NEW (confirms U7).** `ForgeRepo` already parses remotes; repo/branch/commit/
file-at-commit links for GitHub/GitLab/Forgejo are one URL builder away.

### U-NEW-8 · Pull rescue for dirty trees — S
**NEW (confirms M18).** `pull --rebase --autostash` as a split-button Pull menu
(Pull / Pull (Rebase) / Pull (Autostash)) — the Settings-only toggle hides the
escape hatch exactly when it's needed.

---

## 7. Aesthetics

### A-NEW-1 · Density setting — S/M
**NEW (confirms A3).** 27 pt rows are comfy; a Compact mode (22–24 pt) would
help big histories. `GraphMetrics` must become environment-injected — it is
already the single source of truth, so the change is contained.

### A-NEW-2 · Date grouping in history — S/M
**NEW (confirms A2).** "Today / Yesterday / This week" separators make long logs
navigable. Cheap per-row bucket computation.

### A-NEW-3 · Status-bar pills — S
**NEW (confirms A4).** "↑2 ↓1" as one pill; remote label click-to-fetch; "N
stashed" → popover (U8).

### A-NEW-4 · Dark-mode contrast of the lane palette — S
**NEW (confirms A6).** Brightness-only switch; worth a mechanical WCAG-ish pass
on OLED black.

---

## 8. Novel / delightful

### Q-NEW-1 · Reflog-powered Undo (⌘Z) — M/L — the killer feature
**NEW (confirms Q1).** Undo commit/reset/checkout via HEAD@{1}, refuse pushes.
Differentiator no other OSS client ships.

### Q-NEW-2 · Command palette (⌘⇧P) — M
**NEW (confirms Q2).** Fuzzy actions + repos + branches + commits. Unlocks every
shortcut-less feature above.

### Q-NEW-3 · "Explain this commit" (AI) — S/M
**NEW (confirms Q14).** Detail-pane button → LLM summary of the patch. Reuses
`CommitMessageGenerator` plumbing with a different prompt — cheap and very
on-brand for this app.

### Q-NEW-4 · Hover tooltip on graph nodes — S
**NEW.** Hovering a dot in the graph shows the commit subject in a small
popover (the rows already know the commits; the strip just needs a hit-test for
its node's row). Delightful for dense graphs where the subject is truncated.

### Q-NEW-5 · "N new commits on origin/main since your last fetch" — S/M
**NEW.** After a fetch, show a subtle banner: "origin/main moved: 3 new commits"
with a one-click jump to the first new one. Turns an invisible event into
awareness; pairs with Q-NEW-6.

### Q-NEW-6 · "Fetched N min ago" in the status bar — S
**NEW (confirms Q16).** Persist last-fetch per repo; makes auto-fetch (#23)
auditable.

### Q-NEW-7 · Keyboard-shortcut cheat-sheet popover (⌘/) — S
**NEW.** A ⌘/ popover listing the app's shortcuts (there are ~15 now, growing).
Tiny, discoverable, and it makes every future shortcut land better.

### Q-NEW-8 · GitHub language-color dots — S/M
**NEW (confirms V11/Q6).** One bundled extension→color JSON, two presentations.

### Q-NEW-9 · Commit streak sparkline — S
**NEW (confirms Q5).** Per-author 30-day sparkline; zero network.

### Q-NEW-10 · Drag a commit onto a branch — M
**NEW (confirms Q12).** Direct-manipulation cherry-pick/rebase; very demo-worthy.

### Q-NEW-11 · Conflict ghost preview — M
**NEW (confirms Q7).** ours/base/theirs mini-panes before picking a side;
natural next step after B-NEW-10.

---

## 9. What this pass ships (see the PR list)

Implementations of the highest-confidence, lowest-risk items, one PR each:

1. **Stash reachable with staged-only changes** (B-NEW-1)
2. **Discovery skips bare repos + submodules** (B-NEW-2, with tests)
3. **Settings window sizing** (B-NEW-3)
4. **History filter matches branch/tag names** (M-NEW-1)
5. **"New Branch…" button in the Branches tab** (M-NEW-5)
6. **`GitShell.runChecked` fallback message** (B-NEW-4)

Everything else in this document is the shovel-ready backlog for future passes.
