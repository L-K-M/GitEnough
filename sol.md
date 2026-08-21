# GitEnough — fresh project review

Reviewed against `origin/main` at `f9bea7e` on 2026-08-21.

This is a static, repository-wide review of the current macOS application,
tests, project configuration, CI, and existing `ANALYSIS.md`. The review also
used disposable Git repositories to reproduce pathspec, ref-name, rename, and
`.gitignore` edge cases. The review host is Linux and has neither Swift nor
Xcode, so native layout, VoiceOver, dark-mode, and runtime behavior still need
a final macOS pass. Implementation PRs must use the repository's macOS CI as
the executable check.

## Executive assessment

GitEnough is well beyond a toy. Its core product shape is coherent, the
everyday path is recognizable, and several safety choices are notably better
than many small Git clients: Git is invoked with argv arrays instead of a
shell, authentication prompts fail rather than hang, untracked discard uses
the Trash, parser and graph code are kept pure, secrets live in the Keychain,
and the activity log makes otherwise opaque Git work inspectable. The graph's
new per-row lazy canvases also remove the largest historical rendering problem.

The main weakness is not missing visual polish. It is that several independent
models of repository state have accumulated without one admission/refresh
coordinator. A view model, one watcher per visited repository, app activation,
sidebar summary sweeps, and selection loaders can all initiate work. That
creates stale-result races, redundant process launches, and UI states that look
clean or current after a read actually failed. The product is at the point
where tightening state ownership will yield more perceived speed than adding
animations.

There are also a handful of bounded, reproducible correctness bugs suitable
for immediate independent PRs. Most importantly, a filename can be interpreted
as a Git pathspec and cause unrelated files to be staged; conflict-only repos
are labelled clean; staged renames cannot be fully unstaged; branch/tag name
collisions can detach HEAD; copied activity commands are not shell-safe; and an
AI response can overwrite text written while the request was in flight.

## What is already strong

- Native macOS structure: `NavigationSplitView`, system toolbars and commands,
  Keychain storage, AppKit file operations, drag/drop, and standard shortcuts.
- Git commands are arrays, not shell strings; `--` is used consistently to end
  option parsing, prompt/editor variables are suppressed, and both output pipes
  are drained concurrently.
- Per-repository serial queues are a sound base for mutation ordering. External
  merge tools are correctly kept off that queue because they can remain open
  for minutes.
- Untracked files are moved to Trash. Hard reset and amend-after-push are
  explicitly guarded. Tracked discard distinguishes an unborn repository.
- The persistent command/activity history is excellent operational feedback
  and a strong base for recovery-oriented features.
- Parser, graph-layout, forge-URL, discovery, store, and real-repository
  integration tests provide a much better foundation than the app's size would
  suggest.
- The graph now renders as lazy row strips, so the old full-height Canvas issue
  is fixed. Diff parsing is memoized and intraline highlighting exists.
- Token-free GitHub, GitLab, and Forgejo/Gitea PR discovery is thoughtful, as is
  constructing safe forge URLs instead of trusting an API-provided URL.
- Repository discovery normalizes paths, honours exclusions, and prevents a
  manually removed repository from immediately being rediscovered.
- The project stays dependency-free, CI actions are pinned, and no telemetry is
  present.

## Immediate implementation ledger

The entries in this section have a crisp desired behavior, a bounded change,
and a practical regression test. Each should be implemented on its own branch
and left as an open PR after CI and reviewer feedback reach steady state.

### S01 · Treat every UI-supplied file path as a literal Git pathspec — critical

`GitClient` passes repository filenames directly to stage, unstage, selected
diff, commit-file diff, mergetool, mark-resolved, and conflict-side commands.
`--` stops option parsing but does not disable Git pathspec globbing or magic.
This was reproduced with a literal `a*.txt`: staging it also staged `abc.txt`.
A `:(exclude)...` filename can have still broader effects. Discard already has
the right literal treatment.

Implement one central literal-pathspec conversion for repo-reported paths and
use it for every Git command that accepts a pathspec. Do not apply it to
`diff --no-index`, whose operands are filesystem paths. Integration coverage
must include `*`, `?`, `[`, and `:(...)`, and must prove a one-file action never
affects its neighbour.

### S02 · Conflict-only status is dirty, and counts unique changed paths — high

Porcelain `u` records are stored only in `RepoStatus.conflicted`, while
`isDirty` and `changeCount` inspect staged and unstaged arrays. A repository
whose only changes are unresolved conflicts therefore gets no dirty sidebar
dot, disappears from the Uncommitted filter, and says “Working tree clean”
under the conflict banner. Partially staged paths can also be double-counted.

Define changed paths as the unique union of staged, unstaged, and conflicted
destinations. Preserve the separate arrays for presentation. Add conflict-only
and partially-staged model/parser assertions.

### S03 · Generate a POSIX-safe command when activity is copied — high

The activity model currently quotes only arguments containing spaces or tabs,
using unescaped double quotes. The history view then presents that flattened
display text as a command that can be rerun. Arguments containing `$`,
backticks, quotes, newlines, or command substitution can behave differently—or
execute code—when pasted into Terminal.

Retain structured argv where practical and separate human display text from
the rerunnable representation. Generate the latter with robust POSIX
single-quote escaping, including embedded apostrophes and newlines. Tests must
cover benign simple arguments, whitespace, apostrophes, dollars, backticks,
newlines, and an empty argument.

### S04 · Neutralize inherited Git repository-routing environment — high

`GitShell` copies the parent environment and only adjusts prompt/editor/PATH
settings. If GitEnough is launched from a terminal that exports `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, object directories, or
related config overrides, `git -C` can operate on another repository or index.

Remove repository-routing and command/config-injection variables from child
environments while preserving credential-helper and SSH settings that users
legitimately need. Add isolation tests with alternate repositories and indexes.
Document the allow/deny rationale next to the list.

### S05 · Correct `.gitignore` literal escaping and deduplication — high

Trailing whitespace is currently escaped after the space (`/foo \\`) rather
than before it (`/foo\\ `), which Git does not interpret as a literal trailing
space. Deduplication also assumes a raw metacharacter-containing pattern is
equivalent to its escaped literal form: existing `report[1].txt` can prevent a
correct rule even though that pattern matches `report1.txt`.

Escape each trailing whitespace character in place, and deduplicate only
patterns that are semantically literal-equivalent. Replace tests that encode
the wrong output and add real `git check-ignore` integration coverage for
brackets, leading `!`/`#`, backslashes, and one or more trailing spaces.

### S06 · Preserve both sides when unstaging or discarding a staged rename — high

Rename parsing retains `originalPath`, but unstage/discard passes only the
destination. For `R100 old new`, restoring only `new` leaves `old` as a staged
deletion and `new` untracked. The visible action therefore does not clear the
rename.

For an unstage, pass both source and destination literal pathspecs. For discard,
restore the source and make the destination outcome explicit and recoverable;
do not silently delete a newly created destination. Crucially, porcelain copy
records also carry `originalPath`, but their source is independent: only true
`.renamed` entries may expand to two action paths. Add rename tests plus copy
regressions proving Stage/Unstage/Discard never alter a separately modified
source, including spaces and pathspec characters.

### S07 · Derive branch names from full refs, not ambiguous short refs — high

`for-each-ref` requests `refname:short`. If a branch and tag share `same`, Git
can return the branch as `heads/same`; checking that out resolves as a revision
and produces detached HEAD. Rename then fails as well.

Request/retain full local, remote, and upstream refnames and strip only the
known `refs/heads/` or `refs/remotes/` prefix for display. Mutation methods
should receive the canonical branch identity. Cover local/tag and remote/tag
collisions in parser and integration tests.

### S08 · Preserve detected forge kind when no pull request exists — medium/high

For an unknown host, the PR finder probes Forgejo and then GitLab. A valid
GitLab HTTP 200 with an empty array and a failed probe both collapse to `nil`.
The caller then uses the original generic forge and opens a GitHub-style
`/compare` URL rather than GitLab's new-merge-request form. A valid empty
Forgejo response also needlessly falls through to GitLab.

Return a structured probe result containing detected forge kind plus an
optional existing PR. Stop after the first successful forge response and use
that forge for the create URL. URL-protocol tests must cover Forgejo 404 plus
GitLab 200 `[]`, and Forgejo 200 `[]` without a GitLab request.

### S09 · Report failures while moving untracked files to Trash — medium/high

Untracked discard uses `try?`, so permission, network-volume, or Trash failures
look successful. A batch can be partially moved without any explanation.

Collect failures per path and surface them through the normal operation error
path while retaining successful recoverable moves. Refresh after the attempt so
the file list tells the truth. Test the error aggregation independently of the
platform Trash implementation.

### S10 · Do not let a late AI response overwrite a newer draft or commit — high

The commit editor and Commit button stay active during generation. The eventual
response assigns `draftCommitMessage` unconditionally. A user can press
Generate, write a better message, and have it replaced; worse, they can commit
before the response arrives and see a stale message repopulate the cleared box.

At minimum, capture a generation token plus the original draft/staged-state
revision and apply only if all are still current. Invalidate generation when a
commit succeeds or staged content changes; surface staged-diff read failures
instead of asking the service to summarize an empty string. The preferable UX
is a suggestion card with Accept/Replace/Regenerate and Undo rather than direct
mutation. Add deterministic reverse-completion tests around the state reducer.

### S11 · Honour the “only when Generate is pressed” network promise — high

Opening AI settings automatically calls the configured provider's `/models`
endpoint whenever a key exists, contradicting the README privacy promise that
the LLM is contacted only after Generate. This also sends a request merely for
viewing settings.

Make model loading explicitly user-triggered (the button already exists), or
change the disclosure and obtain clear consent. The low-surprise fix is to
remove the appearance-triggered request and keep last known/manual model data.

### S12 · Make menu Push use the same context-aware Publish behavior as toolbar — high

The toolbar changes to Publish when a branch has no upstream, but Shift-Command-P
always invokes plain push. On a new branch the keyboard equivalent of the
visible action therefore fails. The toolbar can also offer Publish on detached
or unborn HEAD.

Define one capability/action used by toolbar, menu, and shortcuts: push an
existing upstream, publish a named local branch when a remote exists, and
disable with a useful reason for detached/unborn states. The menu title should
track the action if SwiftUI command refresh permits it. Test the pure predicate
and generated Git operation.

### S13 · Reject accidental overlapping mutations at the model boundary — high

`perform` sets a Boolean but accepts another request. Menu and many row/context
actions ignore busy state. The first completion can set `isBusy = false` while
later queued work is still running; stash ordinal commands are especially
unsafe because an earlier operation renumbers later `stash@{n}` targets.

Represent one admitted mutation with identity rather than a cosmetic Boolean,
reject unintended re-entry centrally, and expose the same capability to menus,
toolbar, rows, sheets, and shortcuts. Preserve explicitly detached work such as
a merge tool through a separate logical lease. Add a fake-client test that
blocks the first operation and attempts a second.

### S14 · Classify decorated local branches containing slashes correctly — medium

The log decoration parser treats any undecorated label containing `/` as a
remote branch, so a normal local `feature/login` gets remote coloring/iconography
unless it is HEAD. Use full decoration refnames and explicit `refs/heads/`,
`refs/remotes/`, and `refs/tags/` prefixes, with a conservative fallback only
for legacy fixture text. Add parser tests for local and remote slash names.

### S15 · Stop forcing an all-tags fetch during ordinary Fetch and Pull — medium

Both operations add `--tags`. Ordinary fetch already follows relevant tags;
forcing every tag makes routine sync slower on tag-heavy repositories and can
fail the whole action when a moved local tag would be clobbered, even if branch
updates succeeded.

Use normal configured fetch semantics for Fetch/Pull and offer “Fetch all tags”
as an explicit variant if desired. Integration tests should prove ordinary
fetch does not overwrite a divergent local tag and still updates branches.

### S16 · Match upstream remotes without splitting valid remote names — medium

Preferred-remote selection takes the portion of `remote/branch` before the first
slash. Git remote names may themselves contain slashes, so the wrong remote can
be used for Publish or PR creation.

Match the longest configured remote-name prefix followed by `/`; then fall back
to `origin`, then the first remote. Cover nested remote names and overlapping
prefixes.

### S17 · Make staged/unstaged selection identity include the side — high

A partially staged file appears in both sections as an equal `FileChange`.
Clicking the same path in the other section changes a separate Boolean but does
not trigger the selection change, so the highlighted row can show the other
side's patch. Status refreshes can likewise leave a now-outdated diff.

Use a single selection value containing path plus staged/unstaged side and a
request generation. Immediately represent the new request as loading, discard
old completions, and refresh content when the selected side's status revision
changes. This complements, rather than duplicates, generic stale-request token
work. Use a typed failure state as well: `try? ?? ""` must not turn a Git/read
failure into a legitimate-looking “No diff.”

### S18 · Make conflict-marker verification fail closed — high

Marker checking loads the entire file and returns “no markers” if reading or
decoding fails. “Mark Resolved” then stages the unreadable file. This is both a
large-file cost and unsafe error semantics.

Scan incrementally with chunk overlap and a bounded memory footprint. Return a
throwing/tri-state result; a read failure must prevent automatic staging and
show an actionable error. Test markers spanning chunk boundaries and injected
read failures.

### S19 · Apply `--no-optional-locks` consistently to read-only Git calls — medium

Only status and one symbolic-ref query currently use it, despite the project
contract. History, refs, remotes, diffs, stash listing, details, and conflict
reads can create avoidable lock contention or maintenance side effects.

Centralize pure reads behind a helper that injects the global flag and assert
argv in unit/integration tests. Keep commands whose semantics may mutate or run
hooks on the normal path.

## Already in flight; do not duplicate

At review time the repository already has open PRs for these items. They should
be reviewed and allowed to settle, not reimplemented on new branches:

| PR | Current scope |
| --- | --- |
| #36 | stale diff request tokens and loading state |
| #37 | strip only a trailing `.git` in remote display host |
| #38 | immutable/thread-safe date formatter configuration |
| #39 | merge-commit cherry-pick/revert mainline handling |
| #40 | explicit upstream-gone state |
| #41 | commit-detail failure state |
| #42 | unpushed commit graph markers |
| #43 | guarded force-push-with-lease |
| #44 | stash availability for staged-only changes |
| #45 | discovery handling for bare repositories/submodules |
| #46 | Settings window sizing |
| #47 | history filtering by decorations |
| #48 | GitShell synthesized error command name |
| #49 | visible New Branch action in the Branches tab |
| #50 | squash/no-fast-forward merge options |
| #51 | expandable/copyable error banner |
| #52 | live relative-date updates |
| #53 | branch/commit copy actions |
| #54 | per-repository commit-draft persistence |
| #55 | empty History/remote-branch states |

Review notes that should be handled on those branches include: stale detail and
diff responses need generations and main-thread invariants; a newly selected
file must not display the previous file's patch while loading; Git host tests
should include dots before a trailing suffix; merge mainline should not silently
assume parent 1 when parent choice matters; “upstream gone” help should not claim
that push always fails; and commit-detail errors must not be resurrected by an
older selection response.

## Architecture and performance: design before patching

These are real problems with high implementation value, but a narrow patch can
easily move the race or cost elsewhere. Each needs an enabling model/test or a
small design note before implementation.

### A01 · Replace root-mtime polling with event-driven, tiered observation

The watcher checks Git metadata and the worktree root every 2.5 seconds. Editing
an existing nested file changes neither, so Changes can remain stale indefinitely
while GitEnough and an editor stay side by side. Adding a nested file changes
only its immediate directory. Linked worktrees additionally keep shared refs in
the common Git directory, which is not observed.

Use a debounced FSEvents stream for worktree changes and observe both absolute
Git dir and common Git dir. Classify events: file/index changes request status
and the visible diff; HEAD/ref changes request branches/history; config changes
invalidate remotes. Test nested in-place writes, nested creation/deletion,
linked-worktree ref changes, exclusions, and burst coalescing.

### A02 · Suspend or evict inactive repository view models

Every repository ever selected retains a heavyweight view model, history,
layout, selections/diffs, activity bridge, and a repeating timer. Forty visited
repositories mean forty timers and roughly 208 metadata probes per second even
when one repo is visible.

Watch only the selected repository. Keep cheap persistent summaries/drafts
separately and use an LRU/TTL for heavy history/diff state. Resume plus refresh
on selection, and explicitly release large selections on eviction.

### A03 · Introduce one refresh coordinator and invalidation tiers

Launch currently triggers summary/discovery work from both view appearance and
application activation, while the active view model separately refreshes.
Sidebar sweeps create unrelated Git clients that bypass the active repo queue,
then replace the entire summary dictionary. Older sweeps can overwrite a newer
post-commit summary or resurrect removed entries.

Create a path-keyed coordinator with generation tokens, in-flight coalescing,
and a short freshness TTL. Route instantiated repositories through their serial
executor. Merge only still-current per-repo results. Define status-only,
refs/history, config, and full refresh tiers rather than treating every event as
full invalidation.

### A04 · Eliminate the automatic second snapshot after app-originated work

The watcher baseline is updated only on its next tick. A stage operation performs
its intended status refresh, then the watcher sees the index change and triggers
a full history snapshot around 2.5 seconds later. Users can observe the duplicate
command sequence in Activity.

Successful internal operations should acknowledge the watch baseline and
coalesce pending events with a running refresh. A spy runner should assert a
command budget for stage, commit, branch, fetch, and manual refresh.

### A05 · Reduce full-snapshot process launches and preserve partial success

A normal full refresh launches about eight Git processes: status, branches,
remotes, stash, Git-dir/operation probes, conflicts, and log. Conflict paths are
already present in porcelain status; Git-dir is repeatedly rediscovered;
remotes rarely change. Every query currently uses `try?`, then replaces a
failure with empty data. A corrupt index can therefore erase history/branches
and present a nominally valid clean summary.

Cache immutable/common Git directories, inspect operation markers directly,
derive conflicts from status, cache remotes until config changes, and publish a
snapshot atomically. Preserve last-known-good values per domain with freshness
and error metadata. Status failure must never become “clean.” First add a
`GitRunning`/client protocol and partial-failure tests.

### A06 · Bound and stream process output before constructing Swift strings

GitShell fully buffers stdout and stderr, converts them to strings, and the diff
parser then splits the entire output before respecting its 4,000-line cap. AI
generation obtains the full staged patch before trimming the prompt. Large
generated files or noisy hooks can create several full copies and millions of
line objects.

Add capture policies: bounded stdout head, bounded stderr ring tail, truncation
metadata, and streaming drains so pipes never block. Parse diffs incrementally
off-main and cancel stale parses. Display a clear truncated/binary/large-file
state with an explicit “Open externally” or guarded full-load action. Test data
well beyond pipe-buffer and configured limits.

### A07 · Add cancellation and meaningful progress for network operations

Fetch, pull, push, and clone retain no cancellable process handle or timeout.
A dead VPN, credential helper, signing tool, or hook can jam a repository queue
indefinitely. Clone only shows a spinner even though Git emits useful progress.

Create cancellable process handles with graceful interrupt/terminate escalation,
stream sanitized progress, expose Cancel, and apply explicit timeout policy only
to automatic/network work. Never silently kill an arbitrary mutation. Test with
a fake remote that blocks.

### A08 · Split the monolithic observable model

One `RepoViewModel` publishes snapshot data, draft keystrokes, selection/diffs,
activity history, and operation state. Every Git command begins and finishes an
activity entry, so an eight-command refresh can invalidate History, Changes,
Branches, toolbar, and status bar at least sixteen times before snapshot field
assignments. History then rebuilds hash/enumerated arrays on rerender.

Split activity, draft, selection/load state, and repository snapshot into
narrow observation domains (or adopt fine-grained Observation). Suppress
identical publications, publish the core snapshot once, and benchmark body
counts/signposts before and after.

### A09 · Make history pagination incremental and memory-bounded

Load More increases a limit, refetches from zero, and recomputes the complete
graph prefix. Cumulative work becomes quadratic in page count and the enlarged
limit is used on every later refresh. Layout also retains both flat and per-row
segment collections.

Append older pages using `--skip` only after validating that visible ref/head
generation is unchanged; otherwise rebuild. Develop continuation-compatible
layout or document why full layout is required. Make row buckets canonical and
add 10k-commit/large-DAG performance tests.

### A10 · Isolate main-owned and queue-owned state

History limit and load-more state are mutated on main and read on the repo
queue. Models lack actor annotations. Selection and summary completions likewise
cross queues without a uniform identity rule.

Mark UI models `@MainActor`, capture immutable request parameters before queueing,
and keep queue generations on their owning executor. Enable stricter Swift
concurrency checks incrementally; the project currently compiles in Swift 5
language mode despite its “latest stable” intent.

### A11 · Make external merge tools hold a logical mutation lease

Running a merge tool off the serial queue avoids jamming GitEnough, but leaves
Ours/Theirs, Mark Resolved, Abort, Pull, and other mutations enabled. The stale
tool can later exit and auto-stage over a newer or aborted state.

Keep the process detached, but acquire a logical repo mutation lease for its
path/operation. Disable conflicting mutations, allow reads, and before staging
verify the same conflict and operation still exist. Decide whether multiple
tools can run for distinct files and model that explicitly.

### A12 · Correct conflict actions across merge, rebase, and missing sides

Generic “Ours—Keep our version” and “Theirs—Take their version” are dangerously
misleading in a rebase, where ours is the new base and theirs is the replayed
commit. Modify/delete and delete/delete conflicts also have a missing stage;
plain checkout fails instead of resolving the chosen deletion. Ours/Theirs and
Abort are one-click destructive operations.

Inspect index stages, use `git rm` when the chosen side is absent, and present
operation-specific names (“Rebase target” / “Your replayed commit”, etc.). Add a
preview or at least a concrete confirmation, and offer Continue/Abort/Skip only
when meaningful. A future three-way conflict view should show base/current/
incoming before replacement.

### A13 · Keep mutating forms open until Git succeeds

New branch, tag, rename, and stash sheets dismiss and clear user input before
the async Git result is known. Invalid refs, hooks, and filesystem errors arrive
later in a top banner after corrective context is gone.

Give `perform` a completion/result channel. Validate ref names with Git, keep the
sheet open with inline progress/error, and dismiss/clear only on success. Reuse
the Add Repository completion pattern.

### A14 · Harden persistence, privacy, and runner edge cases

- Persisted selected-repository paths must be validated; otherwise the app can
  reopen to Welcome despite valid repositories in the sidebar.
- Custom LLM endpoints should require HTTPS except an explicit localhost
  exemption/warning. API keys and staged source must never be sent to cleartext,
  userinfo-bearing, or credential-in-query URLs without explicit handling.
- One Keychain item across providers risks sending a previous provider's key to
  a new endpoint. Scope credentials per provider/endpoint with migration.
- Activity persistence includes user-provided stash/tag messages; redact
  sensitive free-text option values and ensure restrictive file permissions.
- `/usr/bin/git` can be an executable Command Line Tools shim that prompts. Probe
  `git --version` with bounded behavior rather than trusting executable bits.
- GPG pinentry can still block commits. Detect/explain signing stalls; never
  silently disable configured signing.
- Parser record separators are legal commit-message control characters. Add
  adversarial tests and move toward a framing strategy that cannot be confused
  by commit data.
- Existing leading-dash refs/remotes can still reach mutation commands. Use full
  canonical refs and `--end-of-options` where supported.

### A15 · Fill the test seam before the state-management rewrite

There are no meaningful RepoViewModel or RepoWatcher tests. Add an injected
Git runner/client, clock/scheduler, and event source. Required cases include
reverse-order completions, partial snapshot failures, overlapping mutation
admission, watcher coalescing, summary generations, huge dual-pipe output,
termination, the documented diff cap, and 10k-commit graph performance. The
integration harness should isolate global Git config/hooks/signing.

## Everyday workflow and interaction review

### Make the obvious path visually obvious

- Turn Fetch/Pull/Push/Publish into one context-aware primary Sync action:
  “Fetch,” “Pull 3,” “Push 2,” or “Publish Branch,” with a dropdown for variants.
  This reduces toolbar density and makes the next action self-explanatory.
- Put dirty/ahead/behind counts into the relevant tab or primary control. A
  “Changes 7” tab makes Stage → Message → Commit → Push easy to scan.
- Add visible branch-row actions or a selection detail pane: Checkout, Merge
  into `<current>`, Rename, Delete. Core branch operations are currently hidden
  behind context menus and double-click.
- Add Repository-menu Commit, Stage All, Unstage All, and Stash actions with
  discoverable shortcuts. Menus and toolbar must share capability predicates.
- Support file multi-selection and batch Stage/Unstage/Discard. Repeated
  one-file operations are tedious and process-heavy.
- Stash should be reachable whenever anything is changed, including staged-only
  state, and from menu/status controls. Add a stash diff preview before Apply,
  Pop, or Drop.
- Show the actual remote selected for push and PR actions. The status bar should
  not blindly display the first configured remote.
- Add configurable Open in Editor with detected Xcode, VS Code, and JetBrains
  apps; keep Terminal as one option rather than the only command.

### Feedback and recovery

- Report short nonmodal success outcomes: “Pulled 4 commits,” “Pushed 2,” and
  “Fetched just now.” A spinner disappearing is weak confirmation.
- Disabled actions need a reason: publish before PR, set an upstream before
  pull, create the first commit before publish, wait for the current operation.
- Hard reset copy must say it preserves untracked files. “Copy Message” currently
  copies only the subject and should be named accordingly or load the body.
- Render renames/copies as `old/path → new/path` in Changes and commit detail.
- Add basename emphasis, secondary parent path, and readable words/tooltips for
  file statuses rather than relying on one-letter badges.
- Add a sticky diff header with filename, staged/unstaged side, statistics,
  whitespace control, and safe external-open action.

### Empty states and information hierarchy

- A clean Changes tab should collapse the inert stage sections/commit form and
  show a positive “clean and synced” state with the next useful action.
- Zero-commit History, no stashes, no branches/remotes, and no search matches
  need task-oriented states and Clear/Create/Publish affordances.
- Sidebar paths should appear primarily for duplicate repository names, hover,
  or an optional roomy mode; always using three lines wastes scanning space.
- The permanent drop footer should become an active drag overlay or appear when
  the sidebar is empty.

## Layout, visual design, and accessibility

### Responsive layout risks

At the 860-point minimum window, a minimum 200-point sidebar plus a fixed
360-point commit detail leaves very little room for graph lanes, a 110-point
date, subject, and author. Changes demands two 320-point panes, and the one-line
Generate/count/Amend/Commit row will not survive localization or larger text.
The toolbar also combines a 280-point picker, unbounded branch text, and several
labeled controls.

- Make commit detail a collapsible, resizable Inspector and auto-collapse below
  a threshold. Persist the inspector/split position.
- Bound/truncate branch-name presentation, use adaptive toolbar labels, and
  group sync actions.
- Let Changes stack or collapse panes at narrow widths; allow the commit control
  row to wrap into a second line.
- Replace fixed detail/diff text sizes with user-selectable density/font sizing.
- Validate these in English expansion/pseudo-localization and with larger
  accessibility text on macOS before shipping.

### Visual system

The cobalt toolbox icon is distinctive but loses Git identity at small sizes,
the accent asset is warm coral, graph colors are separate, and most surfaces
fall back to stock gray. Establish one deliberate palette connecting app icon,
active branch, graph lane, selection, and primary actions; reserve orange/red
for warning/destruction. Consider a simpler branch/toolbox silhouette for 16px
and 32px variants.

Use compact semantic status pills, clearer hunk headers and line-number gutters,
basename-first file rows, and branded but quiet empty states. Any decoration
must remain legible in dark mode, Increase Contrast, and color-blind settings.

### Accessibility and keyboard

History and changed-file rows use tap gestures instead of standard selectable
controls, limiting keyboard focus and VoiceOver traits. Branch operations are
mostly right-click/double-click. The 7-point dirty dot and ahead/behind icons do
not communicate a combined spoken state; file badges speak raw letters.

- Add arrow-key navigation for history/files/branches, Return for primary action,
  Delete with confirmation, stage/unstage shortcuts, and Command-F focus for the
  active pane.
- Give rows standard selected/focus behavior plus explicit accessibility labels,
  hints, and custom actions.
- Speak “modified/added/untracked/conflicted,” dirty state, and ahead/behind
  phrases. Announce operation/error banners.
- Test VoiceOver, Full Keyboard Access, Increase Contrast, Reduce Motion, larger
  text, and pseudo-localization.
- Runtime-check window restoration after the main window is closed while
  Activity/Settings remains open; provide an Open GitEnough Window command and
  Dock reopen behavior if needed.

## Missing features, prioritized

### Near-term high value

1. Hunk and line staging, with patch preview and safe fallback.
2. Multi-file selection and batch actions.
3. Visible branch actions, search, recent branches, and explicit merge target.
4. Cancellable fetch/pull/push/clone with real progress.
5. Stash preview and stash access from anywhere.
6. Preferred editor integration and native Quick Look with Space.
7. Per-repository author/email visibility and overrides.
8. Pull with autostash plus clear recovery steps.
9. File history and blame.
10. Diff line gutters, split mode, whitespace toggle, image diff, navigation,
    and Copy Full Diff.
11. Remote and tag management, including explicit Fetch Tags.
12. Branch comparison and guarded force-with-lease.
13. Repository initialization plus richer clone destination/options/progress.
14. Submodule and linked-worktree awareness.

### Larger roadmap

- Minimal interactive rebase with reorder/squash/fixup and a recovery path.
- Full three-way conflict triptych with base/current/incoming.
- Repository-wide history search by path/author/message with pagination and
  jump-to-result; current search is limited to loaded commits.
- Optional scheduled fetch for selected/starred repositories, one at a time and
  paused on battery/constrained networks.
- Persist a cheap last-known snapshot for instant reopen, then validate it in
  the background.
- Authenticated forge integration only if the explicit no-token product stance
  changes; otherwise keep web handoff simple and trustworthy.

## Delightful differentiators

- **Safety Timeline:** combine the excellent activity log with reflog to preview
  and undo the last GitEnough operation. This is the strongest defensible idea:
  delight through confidence rather than confetti.
- **Repo Launchpad:** a cross-repository dashboard grouping “needs commit,”
  “needs push,” “needs pull,” and “fully synced,” with a serialized Fetch All.
- **Commit Flight Plan:** a subtle Stage → Message → Commit → Push progression
  that highlights the next step without becoming a modal wizard.
- **Lane Spotlight:** hover/click a graph lane to illuminate ancestry while
  fading unrelated history; add a minimap for genuinely long graphs.
- **Conflict Ghost Preview:** preview both candidate sides before a destructive
  choice, with the operation-specific meaning written in plain language.
- **AI as proposals:** two or three selectable commit-message cards, retaining
  the user's draft, with Conventional Commit chips and `.gitmessage` awareness.
- **Quick Look everywhere:** Space previews files, images, Markdown, and stash
  contents using familiar macOS behavior.
- **Command palette:** fuzzy-switch repository/branch and run any guarded action
  from one keyboard surface.
- **Direct manipulation:** drag a commit onto a branch to initiate a guarded,
  previewable cherry-pick.
- **Toolbox latch:** an optional restrained latch/check animation when a repo is
  clean and fully synchronized—brief, soundless, and never celebratory noise.

## Corrections required in `ANALYSIS.md`

- Remove the old full-height graph Canvas performance item: per-row lazy
  `GraphStripView` rendering is on main.
- Reconcile its “open first wave” table with actual merged code and the current
  open PR set; several referenced PRs have long since landed or been superseded.
- Upgrade the stale-diff note to cover wrong-file disclosure, request identity,
  both worktree and commit-detail files, and the staged/unstaged side identity.
- Do not claim history search currently covers email/decorations or subset graph
  relayout unless the relevant open PR lands; current main searches loaded
  subject/author/hash and hides the graph while filtering.
- Replace references to the removed `GraphCanvasView` with `GraphStripView`.
- Remove the claim that RepoStore lacks tests; relevant store cases live in the
  discovery/store test file even if file/class organization could improve.
- Add every unfinished S/A/UI/feature item above, consolidate duplicates, and
  delete items completed by settled PRs. Git history is the record of completed
  work; `ANALYSIS.md` should remain only a shovel-ready future backlog.

## Suggested delivery order

1. Land independent safety/correctness PRs S01–S09 first.
2. Land interaction consistency and async-identity PRs S10–S19.
3. Establish the test seam in A15, then implement A03/A05 operation and refresh
   ownership before changing rendering architecture.
4. Implement event-driven watching and lifecycle control (A01/A02/A04).
5. Implement bounded streaming/cancellation (A06/A07), then async diff parsing.
6. Do the responsive/accessibility pass on real macOS hardware.
7. Add workflow features in the order listed, using measured process counts and
   accessibility acceptance criteria for each.
