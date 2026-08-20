# GitEnough — Fable Review (fable.md)

A full-codebase review of GitEnough (third round, after `glm.md` and `kimi.md`),
conducted on top of the merged state of PRs #1–#35. Everything here was verified
against the code as of `main` @ f9bea7e; entries duplicating the existing
`ANALYSIS.md` backlog are only listed when this review adds a correction or a
material refinement (marked **[refines …]**). Effort: **S** ≤ ~30 min ·
**M** half a day · **L** multi-day. Confidence: how sure this review is that
the entry is real and worth doing.

---

## 1 · Bugs & correctness

### F1 · `Remote.displayHost` mangles names containing ".git" — S, certain
`GitModels.swift:65-76` strips `.git` with `replacingOccurrences(of: ".git")`,
which replaces **every** occurrence, not just a suffix. A GitHub Pages remote
`https://github.com/user/user.github.io.git` renders in the status bar as
`github.com/user/userhub.io`; `my.gitops-tools` becomes `myops-tools`.
**Fix:** strip only a trailing `.git` (`hasSuffix` + `dropLast(4)`), in both the
scp-style and URL branches. Unit-testable next to `ForgeRepoTests`.

### F2 · Stale diff resurrection in the Changes pane — S, certain
`RepoViewModel.selectFile` (`RepoViewModel.swift:600-618`): selecting a file
enqueues the diff load on the repo queue; `selectFile(nil)` (file committed,
discarded, or deselected) clears `selectedFileDiff` immediately — but an
in-flight load completes afterwards and writes the dead file's diff back into
`selectedFileDiff`, resurrecting it on screen with no selection. The same
pattern sits in `selectCommitFile` (masked in the History UI only because
`CommitDetailView` re-checks the hash). **Fix:** a generation counter (or the
selected path captured and compared on completion) so stale completions drop
their result. While in there: show a spinner while `isLoadingDiff` (the
published flag exists and is rendered nowhere — ANALYSIS V13).

### F3 · `GitParsers.parseDate` mutates a shared formatter from concurrent queues — S, certain
`GitParsers.swift:11-16`: the static `ISO8601DateFormatter` has its
`formatOptions` assigned on **every call**, and `parseLog`/`parseCommitDetail`
run on per-repo serial queues — two repos refreshing concurrently means
concurrent mutation of shared state (a genuine data race; TSan would flag it).
`.withInternetDateTime` is the formatter's default anyway. **Fix:** configure
once in a closure initializer; never touch it in `parseDate`. (Distinct from
the `RelativeDateText` formatter race #20 already fixed.)

### F4 · Menu commands ignore the busy/remoteless state their comment claims — S, certain
`AppCommands.swift:6-51` says "items are disabled when no repository is
selected **or the model is busy**", but every item only checks `active == nil`.
⇧⌘P with no remote pushes into an error banner; shortcuts fire mid-operation
and queue duplicate network ops (mostly harmless thanks to the serial queue,
but inconsistent with the toolbar, which does disable). **Fix:** disable on
`isBusy`/`remotes.isEmpty` like the toolbar. Note SwiftUI `Commands` only
re-evaluate on observed changes — the VM's `isBusy` isn't observed by
`AppCommands`, so this needs the active VM published through `appState` (or an
`@ObservedObject` hop) to actually update.

### F5 · Untracked-file discard swallows Trash failures — S, likely
`RepoViewModel.discard` (`RepoViewModel.swift:509-518`) wraps `trashItem` in
`try?`. On volumes without a Trash (network mounts, some external disks) the
discard silently does nothing — the row stays, no error. **Fix:** collect
failures and set `errorMessage` ("Couldn't move X to the Trash — …").

### F6 · `historyLimit` read/written across threads — S, likely
`loadMoreHistory` (main thread) mutates `historyLimit` while
`collectSnapshot` reads it on the repo queue (`RepoViewModel.swift:148,192`).
Same benign-Int-race class as the `canLoadMoreHistory` read G9 already notes —
fold into the G9 cleanup: capture the limit on main and pass it into the
snapshot call.

### F7 · Clone bypasses the activity log and can't be seen or cancelled — S/M, certain
`GitClient.clone` is static and calls `GitShell.shared` directly
(`GitClient.swift:607-609`), so the one operation most likely to run for
minutes never appears in the activity log/status bar, has no progress, and no
cancel. At minimum route it through an activity-log-carrying client; real
progress is ANALYSIS M9/M12 territory.

### F8 · `git pull --tags` fetches all tags into unrelated remotes' pulls — S, speculative
`GitClient.pull` hardcodes `--tags` (`GitClient.swift:320-324`). Beyond being
redundant with the default tag-following behavior, `--tags` historically
changes fetch semantics (fetch *only* tags refspec on some versions) and can
fail a pull when a remote moved a tag (refusing to clobber). Consider dropping
`--tags` from `pull` (fetch already passes it) or making it config-respecting.

### F9 · Merge-commit cherry-pick/revert still raw-errors **[refines B14]** — S, certain
Confirmed in current code: `HistoryView.commitContextMenu` offers
"Cherry-pick onto Current Branch" and "Revert Commit" for every row;
`GitClient.cherryPick`/`revert` never pass `-m`. ANALYSIS B14's fix stands;
suggested shape: `cherryPick(hash, mainline: Int?)`, pass `1` when
`commit.isMerge`, and label the menu item "(first parent)" for merges.

---

## 2 · Robustness & architecture

### F10 · `RepoStore` persistence is main-thread UserDefaults JSON on every mutation — S, likely
Every star/reorder/register encodes the full repo list synchronously
(`RepoStore.swift:149-162`). Harmless at 20 repos; noticeable at hundreds.
Low priority — fold into a G6 (RepoStoreTests) follow-up with injected
defaults.

### F11 · `AppState.viewModels` grows forever **[refines G2]** — M
Still true post-#35; additionally each VM's 2.5 s `RepoWatcher` runs its
signature stat calls on the VM's **git serial queue**, so a wedged git op also
stops change detection for that repo (watcher and ops share the queue).
Refinement for G2: when pausing watchers for unselected repos, also move the
signature polling off the repo queue (it's pure stat calls; it doesn't need
serialization with git).

### F12 · The GLM-review workflow's `pull_request_target` gate — informational
`.github/workflows/zai-code-review.yml` correctly gates on same-repo branches;
no action needed. Recorded so future reviews don't re-audit.

---

## 3 · Performance

### F13 · Diff line rows re-layout the whole visible set per keystroke of parent state — S/M, likely
`DiffLineView` is cheap, but the two-axis `ScrollView([.horizontal, .vertical])`
+ `LazyVStack` in `DiffView.swift:32-42` defeats width caching: every parent
publish re-proposes unlimited width. Combined with F17 (ragged backgrounds) the
right fix is one pass: measure the longest line once per parsed diff (the
`ParseCache` already exists) and lay rows out at a fixed content width.

### F14 · `visibleCommits` recomputed and re-enumerated per body pass — S **[refines P3]**
`HistoryView.historyList` builds `Array(visible.enumerated())` (300+ tuples)
and `commits.map(\.hash)` on every body evaluation. With the debounce in place
this is fine at one page but degrades after several "Load more"s. Fold into P3:
compare `(count, first, last)` instead of the full hash array, and let
`ForEach` iterate indices directly.

---

## 4 · Missing features (new relative to ANALYSIS.md)

### F15 · Delete / prune remote branches — S/M
Remote branch rows (`BranchesView.swift:45-63`) offer checkout and merge only.
Missing: "Delete on Remote…" (`git push <remote> --delete <branch>`, destructive
confirmation) and a "Prune stale remote branches" action (`git remote prune`,
or `fetch --prune` exists but nothing surfaces branches whose upstream is gone
— pairs with B11). Daily-driver feature every competitor has.

### F16 · Multi-select in the Changes lists — M
`ChangesView` file lists are single-click rows; staging 10 of 12 files means
10 round trips. `List(selection: Set<…>)` + bulk Stage/Unstage/Discard on the
selection (the VM APIs already take arrays). Pairs with a "Discard All…"
action for the unstaged section.

### F17 · Diff backgrounds don't span the scroll width (ragged blocks) — S/M, likely
In `DiffView`, each line's `.background` only extends to its own text width
because the horizontal axis proposes nil width and `maxWidth: .infinity`
collapses to the ideal. Addition/deletion bands therefore end mid-pane at
different x-positions — visibly scruffy next to every other git client.
Fix jointly with F13 (fixed content width per parsed diff).

### F18 · Branch list has no filter and the picker no search — S
A repo with 100+ branches makes both `BranchesView` and the toolbar picker
unusable. Add the same debounced filter-field pattern HistoryView already has
(reuse its filter bar), and consider sectioning the picker (current, recent,
all).

### F19 · "Open file at this commit" / save patch — S/M
`CommitDetailView` file rows: no way to view the file's content at that commit
(`git show hash:path` → temp file → Quick Look or editor) nor to export a
patch (`git format-patch -1 hash` / copy `selectedCommitFileDiff`). Two small,
high-leverage archaeology features.

### F20 · Check for Updates (zero-dep) — S/M
The app ships DMGs via GitHub Releases but has no update check. A manual
"Check for Updates…" menu item hitting
`api.github.com/repos/L-K-M/GitEnough/releases/latest` (unauthenticated, like
PullRequestFinder) + compare against `CFBundleShortVersionString` + link to the
download keeps the zero-dependency rule and closes the loop with the release
pipeline.

### F21 · Window title carries no branch — S
`navigationTitle(repo.name)` only. `navigationSubtitle` with the current
branch (+ dirty dot) makes Mission Control / window switching legible.

### F22 · Commit-box error dead-ends: "No API key configured" isn't actionable — S
`messageGenerationError` renders as plain caption text (`ChangesView:223-228`).
When the error is the missing key, show a "Open Settings…" button next to it
(`SettingsLink` on macOS 14) instead of making the user find Settings → AI.

### F23 · ⌘F doesn't focus the history filter — S
The filter bar exists but is mouse-only. `@FocusState` + a Find-menu
`⌘F` command scoped to the History tab.

### F24 · Quick Look on file rows — S
Space-bar/context "Quick Look" on Changes + CommitDetail file rows via
`QLPreviewPanel` (AppKit, zero deps). Half of "did I mean this file?" checks
don't need a diff.

---

## 5 · Visual & layout

### F25 · Commit-detail body clipped at 6 lines with no expansion — S
`CommitDetailView.swift:79-85` (`lineLimit(6)`): long bodies — exactly the
commits worth reading — are silently truncated. Make the header scrollable or
add an expand toggle; keep text selectable.

### F26 · Truncated paths have no tooltip — S
File rows truncate middle (`ChangesView`, `CommitDetailView`) but don't set
`.help(file.path)`; sidebar rows same for the abbreviated path. One modifier
per row.

### F27 · Fixed 360 pt commit-detail pane — S/M
`HistoryView.swift:88-95`: the detail column is hard-fixed at 360 pt (a
deliberate anti-drift choice per the comment). On a 27" display the history
list is cavernous while file paths in the detail truncate. Consider a
user-resizable width persisted in `@AppStorage` (keeping the no-HSplitView
decision), or at least 400–420 pt on wide windows.

### F28 · Toolbar branch picker can dominate the toolbar — S
`.fixedSize()` on the picker label (`RepoDetailView.swift:136-161`) lets a
60-char branch name push the fetch/pull/push cluster off-window. Cap with
`.frame(maxWidth: 260)` + middle truncation.

### F29 · Ref chips: identical styling for local branches and HEAD chip crowding — S (design)
`RefChip` renders HEAD + branch as two chips on the same commit
("HEAD" + "main"), spending row width twice for one fact. Collapse
`HEAD -> main` into a single accented chip ("● main"), keep plain "HEAD" only
for detached. Pairs with ANALYSIS A5 (lane-colored chips) and V4 (+N popover).

### F30 · Selection highlight is two disjoint rectangles — S
Graph strip and row text each paint their own `accentColor.opacity(0.20)`
(`GraphStripView.swift:92-95`, `HistoryView.swift:395`), meeting at a visible
seam when lane counts squeeze widths. Paint one full-row background behind an
HStack of [strip, row] instead.

---

## 6 · Interaction & UX

### F31 · No keyboard path anywhere in History **[refines U1]** — M
Confirmed still true: rows are `onTapGesture` in a `ScrollView`; arrow keys,
⏎, ⌘C do nothing. U1's plan stands; add "⌘C copies the selected commit's
hash" while wiring it.

### F32 · Stage/unstage icons flip meaning with no animation — S
The row action button switches `plus.circle`/`minus.circle` instantly as the
file jumps lists; the file appears to teleport. A `withAnimation` on the list
change (or matchedGeometryEffect at higher effort) makes stage/unstage legible.
Micro-polish with outsized perceived-quality payoff.

### F33 · Double-press protection on destructive dialogs — S
Confirmation dialogs (`Discard`, `Hard reset`, `Force delete`) act on state
captured in `@State` vars that survive rapid re-presentation; harmless today,
but "Discard Changes" on a stale `fileToDiscard` after a background refresh
swaps the list is possible. Clear the captured item when the snapshot no longer
contains it (mirror the selection-following logic added in #16).

---

## 7 · Aesthetics

### F34 · The commit box reads as an afterthought — S/M (design)
A borderless `TextEditor` with a 1 pt stroke, a tiny Generate button, and the
72-char counter crammed inline (`ChangesView.swift:203-285`). Suggestion: give
the subject its own single-line field (auto-advancing to a body field on ⏎ —
this also makes the 72-char rule structural instead of advisory), move
Generate into the field as a trailing sparkle icon, and let the box grow with
content up to ~6 lines.

### F35 · Status bar is a flat caption strip — S (design)
Ahead/behind/stash/dirty are five separate `Label`s in one gray row
(`RepoDetailView.swift:209-266`). Group into pills (**↑2 ↓1** as one sync pill
— click = fetch; **3 stashed** — click = stash popover, per U8/A4) and give the
pills subtle semantic tints. Keep the git-activity terminal chip as-is — it's
the best part.

### F36 · No motion anywhere — S (design)
Banners appear/disappear with a hard cut (`RepoDetailView` merge/error
banners), rows pop in on refresh. Two `withAnimation(.snappy)` transitions —
banner slide+fade, list diff animation — would remove most of the "prototype"
feel. Deliberately skip animating the graph.

---

## 8 · Novel & delightful

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
in the integration harness.

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
workflow; one `git config --get commit.template` read per repo open.

### F43 · Menu-bar extra: "N repos need attention" — M
Optional `MenuBarExtra` listing repos that are dirty/behind (from the summary
cache — zero extra git calls), one click to open. Off by default per the
no-nagging philosophy (Q9's spirit).

### F44 · Hidden credits: the lane rainbow — S
⌥-clicking the History tab title replays the graph's palette assignment as a
0.8 s cascade (Q11's rainbow, but scoped to a deliberate easter egg surface,
behind no flag). Ship whimsy responsibly.

---

## 9 · Suggested implementation order (this wave)

Small, CI-verifiable, low-regret first:

1. **F2** stale-diff race + V13 loading spinner (correctness, user-visible)
2. **F1** `.git` suffix stripping (one-liner + tests)
3. **F3** formatter race (one-liner)
4. **F9/B14** merge-commit cherry-pick/revert `-m 1` (+ integration test)
5. **B11** upstream-gone parsing + branch-row badge (+ parser tests)
6. **B9** commit-detail failure state (kills the eternal spinner)
7. **M17** unpushed markers in history (one rev-list per snapshot)
8. **M5** force-push-with-lease behind confirmation
9. **M3** squash/no-ff merge options (+ integration test)
10. **V7** expandable error banner with Copy
11. **B13** live relative dates (TimelineView)
12. **U3** copy name / "hash subject" menu items
13. **M22** per-repo commit-draft persistence
14. **V5** empty states (zero-commit History, remote-less Branches)
15. **F15** delete/prune remote branches
16. **F18** branch filtering
17. **F39** branch cleanup assistant
18. **F37** AI PR description

Then the two structural items — G1 (cancel/timeout) and P2/P1 remainders —
deserve their own design round.
