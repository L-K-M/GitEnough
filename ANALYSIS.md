# GitEnough — Analysis & Roadmap

Consolidated review of the codebase (initial deep pass 2026-08-18, ~5,900 lines
of Swift). This document is the backlog: every item is self-contained and
shovel-ready. Completed work is listed at the bottom with its PR.

How to read: 🐛 bug · ⚡ performance · ✨ feature · 🎨 visual · 💡 idea.
Each item notes where to start and what "done" looks like.

---

## 1. Known bugs & correctness gaps

### 🐛 Cherry-pick / revert of a merge commit fails cryptically
`git cherry-pick <merge>` needs `--mainline 1`; today the user gets git's raw
"is a merge but no -m option was given" in the error banner.
**Fix:** in `HistoryView.commitContextMenu`, when `commit.isMerge`, either pass
`-m 1` (add a `mainline` parameter to `GitClient.cherryPick`/`revert`) or gate
the menu items behind a confirmation that explains the parent choice.

### 🐛 Apply `:(literal)` pathspecs to the remaining path-taking commands
Follow-up from PR #9, which fixed it for `discard` only: `stage`, `unstage`,
`resolveConflict`, `markResolved`, `diff`, and `checkout`-based flows still
pass raw paths, so a file literally named `a*.txt` glob-matches siblings.
**Fix:** prefix with `:(literal)` consistently (verify each subcommand accepts
pathspec magic — they do), add one integration test per command with a
metacharacter filename. See PR #9's `testDiscardTreatsGlobCharactersInFilenamesLiterally`.

### 🐛 Sequencer states (cherry-pick / revert) have no banner
Follow-up from PR #11: an interrupted `git cherry-pick`/`revert`
(`.git/sequencer/…`, `CHERRY_PICK_HEAD`) shows conflicts but no guidance, and a
plain commit concludes it implicitly. Mirror the rebase handling: detect
`CHERRY_PICK_HEAD`/`REVERT_HEAD`, banner with `--continue` / `--abort`.

### 🐛 `/usr/bin/git` CLT stub can false-positive the availability check
Without the Xcode CLT, `/usr/bin/git` exists and is "executable" — it's a shim
that pops a GUI install dialog. `GitShell.findGit` treats it as available, and
the first real invocation may block on that dialog instead of failing fast.
**Fix:** probe with a short-timeout `git --version` at launch, or at least
document the limitation next to `findGit`.

### 🐛 GPG pinentry can hang commits
`GIT_TERMINAL_PROMPT=0` does not suppress GPG's GUI pinentry, so users with
`commit.gpgsign=true` can see commits block. **Fix:** detect the hang class in
the error path and suggest `-c commit.gpgsign=false` per-commit, or surface a
troubleshooting note in Settings. Do NOT silently disable signing.

---

## 2. Performance

### ⚡ View models (and their watchers) live forever
`AppState.viewModels` never evicts: every repo opened this session keeps a
2.5 s `RepoWatcher` timer and reloads history + graph layout on any `.git`
change. Heavy watch-folder users accumulate background work unboundedly.
**Fix:** pause watchers for non-selected repos (`viewModel.pause()`/`resume()`),
or evict view models not used in N minutes. Done = only the selected repo
polls; switching back restores state quickly.

### ⚡ Deep worktree edits don't refresh the Changes tab
`RepoWatcher` watches `.git` files + worktree-root mtime; editing
`Sources/Foo/Bar.swift` touches neither, so changes appear only on app
activation. **Fix:** a 15–30 s status-only poll for the *active* repo (cheap,
reuses the existing snapshot path), or FSEvents/`DispatchSource` on the
worktree excluding `.git`.

### ⚡ `refreshSummaries` spawns one `git status` per repo concurrently
Fine for 5 repos, spiky for 50. **Fix:** bound concurrency (serial or 2-wide
queue) in `AppState.refreshSummaries`.

### ⚡ History Canvas draws the entire loaded history eagerly
One full-height `Canvas` strokes every segment/node even off-screen; grows
with each "Load more". **Fix:** tile the canvas per ~50 rows inside the
`LazyVStack`, or hard-cap loaded pages.

### ⚡ Relative timestamps never tick
"17 minutes ago" freezes until an unrelated re-render. **Fix:**
`Text(date, style: .relative)` or a shared 1-minute timer in
`RelativeDateText`.

---

## 3. Features (ranked by everyday value)

### ✨ Unpushed-commit markers in history
Show which commits `push` would send at a glance: one
`git rev-list @{upstream}..HEAD` in the snapshot → hollow dot or "↑" on those
rows in `HistoryView`. High value, small change.

### ✨ Tags section in the Branches tab
`for-each-ref refs/tags` parses with the existing `Branch` machinery; list,
delete, and **push** tags (follow-up to PR #17, which added tag creation).
Include a "Push Tag" context action (`git push origin <tag>`).

### ✨ Keyboard navigation in the commit list
Selection is tap-gesture based, so ↑/↓ do nothing. **Fix:** real
`List(selection:)` semantics or explicit `.onKeyPress` handling that moves
`selectedHash`. Big feel win.

### ✨ Pull rescue for dirty trees
`git pull` with a dirty tree fails raw. Offer "Stash, pull, pop" as a one-click
recovery in the error path — or make `pull --rebase --autostash` a Settings
option (one flag).

### ✨ Remote management & multi-remote push
Publish hard-codes `origin`; no add/remove-remote UI, no push-to-non-origin.
Start: a Remotes section in the Branches tab + remote picker on Publish.

### ✨ "Ignore Locally" via `.git/info/exclude`
Follow-up from PR #22: companion context action that appends to
`.git/info/exclude` instead of the shared `.gitignore` — for personal
scratch files. Reuse the `GitIgnore` helper verbatim; only the path differs
(resolve via `client.gitDir()`).

### ✨ Hunk / line-level staging
The power feature (`git add -p` semantics via `git apply --cached` with a
constructed patch). Design carefully: hunk checkboxes in `DiffView`, patch
reassembly in a pure, tested type. Large but transformative.

### ✨ File history & blame
`git log -- <path>` from any file row (Changes + commit detail) → filtered
history view. Blame view later on top of the same plumbing.

### ✨ Submodule awareness
Status shows submodules as modified files with "Subproject commit" diffs.
Parse old → new hash, link "open as repository", offer `--recurse-submodules`
on pull. Niche but confusing today.

### ✨ Interactive-rebase-adjacent powers
`rebase -i --autosquash` + fixup commits fits the app's personality; park
full interactive rebase. Also: "Squash last N commits" soft-reset flow.

---

## 4. Visual & UX polish

### 🎨 Diff view line numbers + sticky hunk headers
Gutter with old/new line numbers (parse from the `@@` header in `DiffParser`),
sticky hunk context line while scrolling. Consider word-level intra-line
highlights (GitHub-style darker runs).

### 🎨 Empty diff pane flashes during load
Selecting a file shows "No diff" until the diff arrives even though
`isLoadingDiff` exists. Show a spinner while loading; keep the empty state
for the truly-empty case.

### 🎨 History row selection styling
Flat `accentColor.opacity(0.20)` rectangle → system-like rounded selection
(or zebra striping) for a more native read.

### 🎨 Error banner: copy button / expand
Truncates at 4 lines with no way out; add a copy-to-clipboard button (the
text is already selectable).

### 🎨 Merge/rebase banner boundary
Add a bottom `Divider()` so the banner reads as a distinct strip.

### 🎨 Graph lane hover highlight
Hovering a node dims all other lanes — the "follow the spaghetti" tool for
bushy histories. Canvas hover → hit-test nearest node → tint.

### 💡 Toolbar sync badge next to the branch picker
"↑2 ↓1" beside the branch name (it's currently only in the status bar).

### 💡 Split-button Pull menu
Pull / Pull (Rebase) / Pull (Autostash) in the toolbar instead of a
Settings-only toggle.

### 💡 "Open on GitHub" for a commit
Derive `https://host/owner/repo/commit/<sha>` from the remote URL (parsing
already exists in `Remote.displayHost`); context-menu item + "Copy commit URL".

### 💡 Per-repo commit draft persistence
The draft survives tab switches but not restarts/repo switches. UserDefaults
keyed by repo path, restored in `RepoViewModel.init`.

### 💡 Spell checking in the commit box
`TextEditor` spell-check is off by default on macOS SwiftUI; enable it.

### 💡 Quick repo switcher (⌘P) once the sidebar grows.

---

## 5. Delightful / novel

### 💡 Gravatar avatars in history
`Insecure.MD5(lowercased email)` → `gravatar.com/avatar/<hash>?d=identicon&s=32`
in a 16 pt circle beside the author. One `AsyncImage`, Settings opt-out.
Instantly humanizes the log.

### 💡 "Explain this commit" (AI)
Detail-pane button → send the commit's patch to the configured LLM →
plain-English summary sheet. Reuses `CommitMessageGenerator` plumbing
(system prompt swap). Great for archaeology in unfamiliar repos.

### 💡 AI-assisted conflict resolution
Send conflicted hunks → model proposes merged content into a preview sheet
(accept / edit / discard). Ambitious but on-brand.

### 💡 "Fetched 12 min ago" in the status bar
Pairs with auto-fetch (PR #23); persist last-fetch time per repo.

### 💡 Commit-message autocomplete from recent repo subjects.

---

## 6. Architecture notes (non-urgent)

- `AppState.viewModel(for:)` is called inside `ContentView.body` and from menu
  evaluation — VMs are created and git work starts as a view-body side effect.
  A `selectedViewModel` derived from `selectedRepository` + explicit start
  would be cleaner.
- `RepoViewModel.perform` sets `isBusy = false` after the first of two queued
  ops finishes — spinner flicker. Use an operation counter.
- `Snapshot` reads `canLoadMoreHistory` (a main-thread @Published) from the
  repo queue when `includeHistory == false` — benign Int race; comment or
  capture locally.
- No tests for `RepoViewModel` (the async/queue choreography) — the riskiest
  untested code. A test seam (injectable `GitShell`) would pay off.
- Formatting helpers (`RelativeDateText`, `Remote.displayHost`, sidebar path
  abbreviation) could live in one `Formatters` file.

---

## Done (this review cycle, 2026-08-18)

| PR | Item |
|----|------|
| #9 | 🐛 Discard of staged changes was a silent no-op — now unstages then restores; unborn-HEAD, staged-new, deletion, mixed-batch, and glob-safe (`:(literal)`) covered by tests |
| #11 | 🐛 Rebase in progress was invisible (conflicts hidden, Commit button derailed it) — detection (merge/apply backends, `git am` excluded), banner with Continue/Skip/Abort, Commit disabled mid-rebase |
| #12 | ⚡ DiffView re-parsed up to 4,000 lines on every snapshot publish — memoized read-through cache, no stale frames |
| #13 | ✨ History filter bar (subject/author/hash, diacritic-insensitive), graph hides while filtering, scroll/state resets |
| #15 | ✨ Commit box: 72-char subject counter + confirmation when amending a pushed commit |
| #17 | ✨ Create lightweight/annotated tags from the history context menu (leading-dash option-injection rejected) |
| #20 | 🐛 Bundle: date-formatter race fixed, merge-tool detection cached + observable, New Window removed (state is single-window), sidebar drop failures alert |
| #22 | ✨ "Ignore in .gitignore" for untracked files — literal escaping, dedup, symlink-safe appends, `check-ignore` short-circuit |
| #23 | ✨ Auto-fetch the active repository on a configurable interval |

Explicitly verified as **not bugs** (don't re-file): `GraphLayout.columnCount`
"trailing free lanes" — those lanes were used earlier in history, so the width
is genuinely needed. Modern git auto-drops emptied commits on
`rebase --continue` (`--empty=drop` default), so no dead-end exists there
(Skip is still offered for intent).
