# GitEnough — Deep Review (Kimi, 2026-08-18)

A thorough pass over the whole codebase (~5,900 lines of Swift, zero dependencies).
Overall: the foundation is genuinely solid — clean layering (GitShell/GitClient/parsers
→ view models → SwiftUI), a correct-and-tested graph layout, disciplined threading (one
serial queue per repo, no git on the main thread), and thoughtful touches (untracked
discards go to the Trash, C-quoted path decoding, `GIT_TERMINAL_PROMPT=0` everywhere).
Most findings below are polish, UX gaps, and a handful of real bugs.

Legend: 🐛 bug · ⚡ performance · ✨ missing feature · 🎨 visual/layout · 💡 idea/delight
Confidence: ✅ verified against real git / reading · 🔎 inferred, needs validation.

---

## 1. Bugs

### 1.1 🐛 "Discard Changes" on a staged file silently does nothing ✅ VERIFIED — *fixed in branch `fix/discard-staged-changes`*
`GitClient.discard(paths:)` runs `git checkout -- <path>`, which restores the
**worktree from the index**. For a file whose changes are staged (the Staged
section's context menu offers "Discard Changes…"), worktree == index, so nothing
happens — the file stays staged with its changes, despite the confirmation
dialog promising "All uncommitted changes … will be lost."
- Repro: modify `a.txt`, `git add a.txt`, `git checkout -- a.txt` → change intact.
- Fix (verified): `git reset -q HEAD -- <paths>` first, then `git checkout --`
  only for paths still in the index (`git ls-files -z`). A staged *new* file
  becomes untracked again (content kept — safe); unborn HEAD falls back to
  `git rm --cached`. Note `git restore --source=HEAD --staged --worktree` was
  considered and rejected: it **deletes** staged-new files from disk.
- Regression covered by new integration tests.

### 1.2 🐛 A rebase in progress is invisible — and the app nudges you to break it ✅ VERIFIED — *fixed in branch `fix/rebase-in-progress`*
`git pull --rebase` (a first-class setting!) that hits conflicts leaves the repo
in `rebase-merge` state. The app only detects `MERGE_HEAD`, so:
- no banner, no Continue/Abort;
- **worse**, unmerged paths only appear in `status.conflicted`, and the Changes
  tab's "Conflicted Files" section is gated on `mergeState.isMerging` — during a
  rebase, conflicts vanish from the UI entirely (they're not in staged/unstaged);
- the Commit button happily creates a plain commit mid-rebase.
- Fix (verified): detect `.git/rebase-merge` / `.git/rebase-apply` via
  `--absolute-git-dir`, show a "Rebase in progress" banner with
  `git rebase --continue` / `--abort` (works headless, `GIT_EDITOR=true`), and
  show the conflict section for rebase too. Integration-tested end to end.

### 1.3 🐛 Dropping a non-repo folder on the sidebar fails silently 🔎 — *fixed in branch `fix/small-polish`*
`SidebarView.handleDrop` → `appState.addRepository(at:)` returns false and sets
`addRepositoryError` — which is only displayed inside the Add-Repository sheet
(that isn't open). The user drops a folder, nothing happens, no feedback. Fix:
surface an alert on drop failure.

### 1.4 🐛 ⌘N opens a second window that fights the first 🔎 — *fixed in branch `fix/small-polish`*
`WindowGroup` + global `@StateObject AppState` means a second window mirrors the
same selection (`selectedRepoPath` is a single global). Two windows, one
selection: clicking either yanks the other. Either scope state per window
(overkill for v0.x) or remove the New Window command. Fix: `CommandGroup(replacing: .newItem)`.

### 1.5 🐛 Thread-unsafe shared date formatter 🔎 — *fixed in branch `fix/small-polish`*
`GitParsers.parseDate` mutates `formatOptions` on a `static let`
`ISO8601DateFormatter` **on every call**. Parsers run on per-repo serial queues —
two repos refreshing concurrently race on that mutation. Fix: configure the
formatter once in the static initializer and never mutate it again.

### 1.6 🐛 Merge-tool detection runs synchronously per conflict row 🔎 — *fixed in branch `fix/small-polish`*
`ConflictRow` initializes `@State tools = MergeTool.detectInstalled()` — that's
~9 executable probes + 9 `NSWorkspace.urlForApplication` lookups, per conflicted
file row, on the main thread, re-done every time the row's view identity is
recreated. Fix: cache the detection result app-wide (`MergeTool.installed`), with
`rescan()` for Settings.

### 1.7 🐛 Cherry-pick / revert of a merge commit fails with a cryptic error 🔎
`git cherry-pick <merge>` needs `-m 1`. The app surfaces git's stderr ("…is a
merge but no -m option was given") — technically correct, unfriendly. Either
detect `commit.isMerge` in the context menu and pass `--mainline 1`, or append a
hint to the error. Small.

### 1.8 🐛 `git` presence check can false-positive on the CLT stub 🔎
`/usr/bin/git` exists (and is "executable") even without the Xcode CLT — it's a
shim that pops a GUI install dialog when invoked. `GitShell.findGit` treats it as
available; first real invocation may hang on the dialog instead of failing fast.
Mitigation: probe with `git --version` (the shim still triggers the prompt… best
we can do is keep the not-installed alert; note as known limitation).

### 1.9 🐛 Amending / committing with `commit.gpgsign=true` may hang 🔎
`GIT_TERMINAL_PROMPT=0` doesn't stop GPG's pinentry GUI. A user with signing
enabled could see commits block until the pinentry dialog times out. Options:
document it, or pass `-c commit.gpgsign=false`… no — respect user config; better:
surface a hint in the error message after timeout. Low priority, worth a
troubleshooting note.

---

## 2. Performance

### 2.1 ⚡ DiffView re-parses up to 4,000 diff lines on *every* view re-evaluation ✅ — *fixed in branch `perf/diff-parse-cache`*
`DiffView.body` calls `DiffParser.parse(diff)` inline. The view model publishes
fresh snapshots every 2.5 s whenever the repo is dirty (watcher), and each
publish rebuilds `ChangesView` → `DiffView` → full re-parse + a fresh
4,000-element `ForEach` identity array. Selecting between files also re-parses.
This is the main scroll-stutter source in the app. Fix: parse once per diff
string (cache in `@State`, recompute in `onChange(of: diff)` / init).

### 2.2 ⚡ Every repo you ever open keeps polling and refreshing forever 🔎
`AppState.viewModels` never evicts. Each `RepoViewModel` owns a `RepoWatcher`
(2.5 s timer) and, on any `.git` mtime change, reloads *history + graph layout*
(300 commits) — for every repo touched this session. With a watch folder full of
repos, background work grows unboundedly. Mitigations: evict view models for
repos not selected in N minutes, pause watchers for non-selected repos, or make
non-active refreshes status-only (skip history). Medium effort, real win for
heavy users.

### 2.3 ⚡ Deep worktree edits don't refresh the Changes tab 🔎
`RepoWatcher` watches `.git` files + the worktree *root* mtime. Editing
`Sources/Foo/Bar.swift` touches neither — the change only appears on app
activation or git-state change. The comment acknowledges it. Cheap fix: a
low-frequency status-only poll (e.g. 15–30 s) for the *active* repo; proper fix:
FSEvents/`DispatchSource` on the worktree (recursively, excluding `.git`).

### 2.4 ⚡ `refreshSummaries` spawns one `git status` per registered repo on activation 🔎
Fine for 5 repos, spiky for 50 (watch-folder users). Bound concurrency
(e.g. a serial or 2-wide queue) — it's a background queue anyway.

### 2.5 ⚡ History Canvas draws the whole history eagerly 🔎
One full-height `Canvas` (commitCount × 27 pt) inside the ScrollView — every
segment/node is stroked even when off-screen. Fine at 300; "Load more" a few
times and it grows. Options: tile the canvas per ~50 rows, or cap loaded history
harder. Low priority.

### 2.6 ⚡ Relative timestamps never tick 🔎
"17 minutes ago" is frozen until the next unrelated re-render. A shared
1-minute timer (or `Text(date, style: .relative)`) keeps them honest for free.

---

## 3. Missing features (ranked by daily-driver value)

### 3.1 ✨ History filter/search ✅ — *implemented in branch `feat/history-filter`*
The #1 gap vs. IntelliJ/Fork: filter loaded commits by subject / author / hash
prefix. (Hides the graph while filtering — lane alignment requires the full,
unfiltered row sequence.)

### 3.2 ✨ Create (and push) tags ✅ — *implemented in branch `feat/tag-from-history`*
Context menu on any commit → Tag… (lightweight or annotated with a message).
Tags already render as chips via `%D`, so this closes a visible loop. Push-tag
support left as follow-up.

### 3.3 ✨ Commit-box polish ✅ — *implemented in branch `feat/commit-box-polish`*
- 72-char subject counter (grey → orange), the GitHub-Desktop-style guardrail.
- Warning when amending a commit that's already pushed (`ahead == 0 && upstream
  != nil`): "amending rewrites public history".

### 3.4 ✨ "Ignore this file" context action
Untracked file → "Ignore" appends `/<path>` to the root `.gitignore`. GitHub
Desktop parity, trivially safe (plain file append, watcher picks it up).

### 3.5 ✨ Auto-fetch
GitHub Desktop fetches in the background; here you must hammer Fetch. Add
Settings → "Automatically fetch: Never / 5 / 15 / 30 / 60 min" applied to the
active repository (share the existing 60 s app timer).

### 3.6 ✨ Unpushed-commit markers in history
Commits in `@{upstream}..HEAD` get a hollow dot or "↑" — instant "what will push
send?" answer. Needs one `git rev-list @{u}..HEAD` in the snapshot.

### 3.7 ✨ Tags section in the Branches tab
`for-each-ref refs/tags` already parses with the existing Branch machinery.
List, delete, push.

### 3.8 ✨ Keyboard navigation in the commit list
Selection is tap-gesture based, so ↑/↓ do nothing. Real `List(selection:)` or
explicit key handling. Big feel win.

### 3.9 ✨ Cherry-pick merge commits with `--mainline 1` (see 1.7).

### 3.10 ✨ Remote management & multi-remote push
Publish hard-codes `origin`; there's no add/remove-remote UI, no push-to-upstream.

### 3.11 ✨ Pull-into-dirty-tree rescue
`git pull` with a dirty tree fails with git's raw message. Offer
"Stash, pull, pop" as a one-click recovery (autostash: `pull --rebase --autostash`
is one flag and a good default honestly).

### 3.12 ✨ Hunk/line-level staging
The power feature everyone eventually wants (`git add -p` semantics via
`git apply --cached` with a constructed patch). Large; design carefully.

### 3.13 ✨ File history & blame
`git log -- <path>` from any file row; blame view later.

### 3.14 ✨ Rebase-onto / interactive rebase
Out of scope for "everyday 95%", but `rebase -i --autosquash` + fixup commits
would fit the app's personality. Park it.

### 3.15 ✨ Submodule awareness
Status shows submodules as modified files with "Subproject commit" diffs —
parse and present them properly (old → new hash, open submodule as repo).

---

## 4. Visual / layout

### 4.1 🎨 Diff view has no line numbers or sticky hunk headers
A monospaced gutter (old/new line numbers from the @@ header) + sticky
`@@` context line would make long diffs navigable. Also consider a
word-level intra-line highlight (GitHub-style darker red/green runs).

### 4.2 🎨 History row selection is a flat translucent overlay
`accentColor.opacity(0.20)` full-bleed rectangle; the system list selection
(rounded, vibrancy-aware) reads more native. Also consider a 1 px separator
or zebra tint every other row for scanability.

### 4.3 🎨 Ref chips truncate nothing
A commit with 6 long branch names still only shows 3 + "+3" ✓ good — but the
row can still get crowded on narrow panes; cap chip text at ~24 chars.

### 4.4 🎨 Empty diff pane shows even during load
Selecting a file flashes "No diff" before the diff arrives (`isLoadingDiff`
exists but the empty pane ignores it). Show a spinner while loading.

### 4.5 🎨 Error banner truncates at 4 lines with no way to see the rest
Add a "copy" button or expand-on-click.

### 4.6 🎨 Status bar is monochrome and crowded on narrow windows
Group into segments (sync state · changes · remote) with flexible truncation
priorities; the remote host label should truncate first.

### 4.7 🎨 Merge banner lacks a divider/shadow boundary
It blends into the tab content below. A bottom `Divider()` would ground it.

### 4.8 🎨 Graph: no hover feedback
Hovering a node could highlight its lane (dim the others) — delightful *and*
useful in bushy histories. Canvas hover → hit-test nearest node row.

---

## 5. UX / convenience

### 5.1 💡 Branch picker shows no ahead/behind, no upstream — it's in the status
bar, but the toolbar is where your eyes are. Tiny "↑2 ↓1" next to the branch name.

### 5.2 💡 Pull button could be a split menu: Pull / Pull (Rebase) / Pull (Autostash)
— instead of a buried Settings toggle.

### 5.3 💡 "Open on GitHub" for a commit
Remote URL → `https://host/owner/repo/commit/<sha>` (and "Copy commit URL").
Cheap, delightful.

### 5.4 💡 Per-repo commit message drafts
The draft survives tab switches but not app restarts or repo switches away.
Persist per repo in UserDefaults.

### 5.5 💡 Spell checking in the commit box (SwiftUI TextEditor: off by default).

### 5.6 💡 ⌘⏎ commits ✓ — add ⌘⇧⏎ "commit & push"? Maybe too easy to fat-finger.
Safer: a "Commit & Push" hold-to-confirm option.

### 5.7 💡 Quick repo switcher (⌘P palette) once the sidebar grows.

### 5.8 💡 Welcome view: show the watch-folder / discovery status and recent repos.

---

## 6. Novel / delightful

### 6.1 💡 Gravatar avatars in the history list
MD5(lowercased email) → `https://www.gravatar.com/avatar/<hash>?d=identicon&s=32`
in a 16 pt circle next to the author. Instantly humanizes the log; one
`AsyncImage`, opt-out in Settings. (CryptoKit has `Insecure.MD5`.)

### 6.2 💡 "Explain this commit" (AI)
Detail pane button → sends the commit's patch to the configured LLM → plain-
English summary sheet. Same plumbing as the commit-message generator; great for
archaeology in unfamiliar repos.

### 6.3 💡 AI-assisted conflict resolution
Send a conflicted file's hunks → model proposes the merged content into a
preview sheet (accept/edit/discard). Ambitious but on-brand.

### 6.4 💡 Graph lane hover-highlight (see 4.8) — the "follow the spaghetti" tool.

### 6.5 💡 "Time since fetch" indicator ("fetched 12 min ago") in the status bar —
pairs naturally with auto-fetch.

### 6.6 💡 Commit message "recent subjects" autocomplete from repo history.

---

## 7. Architecture notes (non-urgent)

- `AppState.viewModel(for:)` is called *inside* `ContentView.body` and from menu
  evaluation — it creates VMs and starts git work as a side effect of view-body
  evaluation. Works today; a `selectedViewModel` derived from
  `selectedRepository` + explicit `onAppear` start would be cleaner.
- `RepoViewModel.perform` collapses `isBusy` to false after the *first* of two
  queued ops finishes — spinner flicker if ops overlap. An op counter fixes it.
- `Snapshot` reads `canLoadMoreHistory` (a main-thread @Published) from the repo
  queue when `includeHistory == false` — technically a cross-thread read of
  mutable state. Benign (Int), but worth a comment or a local.
- No tests for `RepoViewModel` (the async/queue choreography) — the riskiest
  untested code in the app. A test seam (injectable shell) would pay off.
- `RelativeDateText`, `Remote.displayHost`, sidebar path abbreviation duplicate
  formatting logic that could live in one `Formatters` file.

---

## 8. Implementation status (this session)

| # | Item | Branch | PR | Status |
|---|------|--------|----|--------|
| 1.1 | Discard staged changes actually discards | `fix/discard-staged-changes` | — | implementing |
| 1.2 | Rebase-in-progress detection + banner | `fix/rebase-in-progress` | — | implementing |
| 2.1 | Diff parse caching | `perf/diff-parse-cache` | — | implementing |
| 3.1 | History filter | `feat/history-filter` | — | implementing |
| 3.3 | Commit-box counter + amend warning | `feat/commit-box-polish` | — | implementing |
| 3.2 | Tag from history | `feat/tag-from-history` | — | implementing |
| 1.3–1.6 | Small fixes bundle | `fix/small-polish` | — | implementing |

Explicitly **not** a bug (checked): `GraphLayout.columnCount` trailing-nil
"trim" — trailing free lanes were used earlier in history, so the width is
genuinely needed. Left as is.
