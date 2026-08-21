# GitEnough — Analysis & Backlog (ANALYSIS.md)

A living, shovel-ready backlog for GitEnough: every entry below is a concrete,
self-contained task with suggested approach and test plan, ready for an LLM (or
human) to pick up. This document consolidates five independent full-codebase
reviews (`glm.md`, `kimi.md`, `fable.md`, `flash.md`, and `sol.md`, each kept
unedited on its review branch as the record) with everything learned while
implementing the first three waves of fixes.
**Maintenance rule:** when an entry ships, delete it here (the git history
preserves it); when a new issue is found, add it with the same level of
concreteness.

Effort: **S** ≤ ~30 min · **M** half a day · **L** multi-day.

---

## Status snapshot (do not re-implement)

Wave-1 work represented by PRs #1–#35 is integrated into `main`; several of
those PRs were closed and superseded by later equivalents rather than merged
literally. Waves 2–3 are **open and deliberately unmerged**. Rows below are
implemented or actively being repaired/reviewed; do not start a duplicate
unless the linked PR is closed or abandoned. Check its current checks, feedback,
base, and dependencies before relying on it:

| PR | Covers |
|----|--------|
| #36/#77 | #77 is stacked on #36: generation guards/loading plus side-aware staged/unstaged selection identity; land or retarget together |
| #37 | `Remote.displayHost` strips only a trailing `.git` (was mangling `user.github.io` and `.git`-containing hostnames) |
| #38 | `GitParsers.parseDate` formatter data race (configure-once) |
| #39 | Cherry-pick/revert merge commits via `--mainline` (per-parent menu items; 1-based precondition) |
| #40 | `[gone]` upstream parsed + "upstream gone" badge in Branches |
| #41 | Commit-detail load-failure state (kills the eternal spinner; real git error in the pane; superseded-load guard) |
| #42 | Unpushed-commit markers: hollow graph dots from `rev-list @{upstream}..HEAD` |
| #43 | Force Push (with lease) as a Push split-button + confirmation |
| #44 | Make Stash reachable with staged-only changes |
| #45 | Skip bare repositories and submodules during watch-folder discovery |
| #46 | Let the Settings window size to content instead of clipping |
| #47/#74 | Overlapping alternatives for matching branch/remote/tag decorations in history filtering; merge one |
| #48 | Name the real Git command in synthesized GitShell errors |
| #49 | Add a visible New Branch action to the Branches tab |
| #50 | Squash / no-fast-forward merge options in the merge dialog |
| #51 | Error banner: expandable long output + copy button |
| #52 | Relative dates tick via per-minute TimelineView |
| #53 | Copy Name on branch rows; Copy Hash and Subject on commits; shared `NSPasteboard.copyString` |
| #54 | Per-repo commit-draft persistence (restore on launch, cleanup on repo removal, injectable defaults) |
| #55 | Empty states: zero-commit History, empty Remote Branches section |
| #56/#59 | #59 is the preferred superset (slash-named locals, full-ref parsing, remote HEAD suppression); #56 is only the local-slash subset |
| #57/#71/#80/#83 | Complementary guardrail series: menu/toolbar state, context-aware Push/Publish, unborn amend, and central mutation admission; #83 is stacked on #57 |
| #58 | Remove inherited repository-routing Git environment variables from child processes |
| #60 | Correct literal `.gitignore` escaping, trailing whitespace, and duplicate detection |
| #61 | Treat conflict-only repositories as dirty and count unique changed paths |
| #62 | Show useful content instead of “No diff” for an untracked directory |
| #63/#85 | #63 is the fixed preferred superset for stage/unstage/discard plus copy-source safety; #85 is discard-only and unsafe for copy records until it adds the same guard |
| #64 | Copy structured activity argv as POSIX-shell-safe commands; disable unsafe legacy copies |
| #65 | Suppress duplicate activation and post-operation refreshes |
| #66 | Preserve canonical branch identities across local/tag/remote short-name collisions |
| #67 | Expand long commit bodies, label merges, and navigate parents in commit detail |
| #68 | Force literal pathspec semantics for every UI-supplied repository path |
| #69 | Preserve detected self-hosted forge type when no open PR exists |
| #70 | Load AI models only after an explicit user action, matching the privacy copy |
| #72 | Use normal reachable-tag following for Fetch/Pull instead of forcing all tags |
| #73 | Select the longest matching configured remote name, including slash-named remotes |
| #75 | Validate Trash targets and report partial/complete untracked-file Trash failures |
| #76 | Prevent an early-exiting Git child from terminating GitEnough with SIGPIPE |
| #78 | Fail closed when a conflict-marker scan cannot read the file |
| #79 | Add `--no-optional-locks` centrally to every read-only repository query |
| #81 | Reject late AI results after edits/newer requests/commit success; recheck staged-diff identity and surface staged-diff read failures |
| #82 | Validate persisted repository selection and fall back to the first valid repository |
| #84 | Remote-branch deletion (active repair: remote-HEAD rejection and a qualified refspec are fixed; longest-match slash-named remote parsing plus empty-component validation remain) |
| #86 | Copy a paste-ready cherry-pick command from a history row |

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

## Correctness & safety

### C1 · Make sidebar summaries generation-safe — S/M

`AppState.refreshSummaries` snapshots every repository, computes results away
from main, then replaces the entire `store.summaries` dictionary. A live
`onStatusChange` update that lands during the sweep can be overwritten by its
older result, and a sweep may race repository removal. Introduce per-path
generation/revision tokens and merge only still-current results for still-
registered repositories. Route an instantiated repository through its existing
serial executor so the sweep cannot race a mutation. Add the narrow injected
summary-loader/VM-queue seam needed to resolve two requests in reverse order;
update/remove a repository between request and completion and assert the newest
surviving per-path value wins. Treat this as P3's first vertical slice:
name/place both seam and generation primitive so the later coordinator reuses
them rather than replacing them.

### C2 · Make conflict choices operation- and side-aware — M

“Ours—Keep our version” and “Theirs—Take their version” are dangerously
misleading during rebase, where ours is the new base and theirs is the replayed
commit. Modify/delete and delete/delete conflicts also have a missing index
stage, so plain checkout fails rather than resolving the chosen deletion.
Inspect stages 1/2/3, use `git rm` when the chosen side is absent, and label
choices for the active operation (“Rebase target” / “Your replayed commit”).
Confirm destructive replacement, preview both candidates, and show only the
Continue/Skip/Abort actions meaningful to merge/rebase/cherry-pick/revert.
Before any choice, make each conflicted row selectable and render Git's raw
combined conflict diff in the detail pane; this is the cheap first increment
even if a full three-way preview follows later.
Add a pure operation × side × missing-stage × allowed-action label matrix for
merge, rebase, cherry-pick, and revert, then integration-test each sequencer.
Conflict fixtures cover content/content, modify/delete, delete/modify, and a
true divergent rename/rename delete/delete case—ordinary deletion on both sides
auto-resolves and is not a valid DD fixture.

### C3 · Give external merge tools a logical mutation lease — M

The process correctly runs off the repository queue, but Ours/Theirs, Mark
Resolved, Abort, Pull, and other mutations remain enabled. A stale tool can
exit later and stage over a newer or aborted state. Acquire a main-owned lease
for the path and operation while the tool is open, disable conflicting
mutations while retaining reads, then verify the same conflict/operation before
staging on exit. The lease identity must include an operation generation plus
operation-head and index stage OIDs: path + operation kind alone can match a new
same-kind conflict started after an abort. Model multiple tools explicitly as a
set keyed by canonical path: reject a duplicate for one path, allow distinct
conflicted paths concurrently, and hold the repo-wide conflict mutation lease
until the set empties. Test both double-open cases, abort then recreate the same
conflict/path before old-tool exit, and resolution elsewhere before exit.

### C4 · Keep mutating forms open until Git succeeds — M

New branch, tag, rename, and stash sheets dismiss and clear input before their
asynchronous Git result is known. An invalid ref, hook, or filesystem error is
then detached from the form needed to correct it. Give `perform` a typed
completion/result channel and extract a testable form-state reducer. Validate
branch creation/rename with `git check-ref-format --branch` and tags with
`check-ref-format refs/tags/<name>`; a stash message is free text and must not
use ref validation. Render inline progress/errors and dismiss/clear only on
success. Pin each form with a fake runner that fails once then succeeds without
losing input.

### C5a · Enforce safe custom AI endpoints and credential scope — M

Require HTTPS except an explicit warned HTTP exemption for exactly `localhost`,
`127.0.0.0/8`, and `[::1]`; reject userinfo, fragments, and all query parameters
(provider-specific nonsecret queries require a later structured allowlist).
Normalize scheme/host case and default ports, collapse only the trailing slash,
and preserve endpoint path components. Scope Keychain items per provider plus
normalized endpoint, and clear/reload the visible key draft before saving after
a provider/base change. Migrate without logging secrets. Tests cover every
loopback spelling, lookalike hosts, ports, paths/spaces, userinfo/query/fragment,
normalization collisions, and provider changes behind an injectable Keychain.

### C5b · Redact and protect persistent activity history — S/M

Activity JSONL can include user-provided stash/tag text and sensitive option
values. Define redaction at the structured-argv boundary and create/repair the
history file with user-only permissions. #64 disables its copy button for
unstructured legacy rows but leaves raw text persisted and selectable; migrate,
redact, quarantine, or delete those on load so secrets are absent from both UI
and disk. Tests inspect raw files after quoted values, URL credentials, arbitrary
messages, migration, and restart; assert mode `0600` after creation, append,
migration, permission repair, and atomic compaction.

### C5c · Detect Git and signing stalls honestly — M

`/usr/bin/git` may be the Command Line Tools shim that opens an installer, so
probe `git --version` instead of trusting executable bits: allow 3 seconds,
terminate, then kill after a 1-second grace while draining both pipes.
`GIT_TERMINAL_PROMPT=0` also does not prevent GPG pinentry; expose P6-style
user cancellation and signing-aware recovery rather than silently timing out or
disabling a commit. Test injectable executables that hang, ignore termination,
exit late, emit partial dual-stream output, or report a signing failure.

### C5d · Replace parser delimiters that commit content can spoof — M

The custom field/record separators are legal commit-message and stash-message
control characters. Move the relevant GitShell result path to `Data`; use an
exact fixed-count NUL-delimited field protocol only after pinning Git's no-NUL
invariant, otherwise retrieve/length-frame records so content cannot imitate
boundaries. Strictly decode each textual field as UTF-8 and surface invalid data
instead of replacement characters. Add adversarial subjects, bodies, authors,
refs, and stash messages containing every old delimiter plus malformed,
truncated, invalid-UTF-8, and non-ASCII records.

### C5e · Harden leading-dash refs and remotes — S/M

Existing refs/remotes beginning with `-` can still be mistaken for options in
mutating commands, but one generic canonical-ref/`--end-of-options` rule is
wrong: Git 2.39 checkout lacks that option and checking out
`refs/heads/-dash` detaches HEAD. Build and test a per-command matrix—e.g.
attached checkout via `switch -- -dash`, deletion via `branch -d --`, and
canonical refs/refspecs where their command accepts them. Cover checkout,
merge, delete, push, tag, and remote operations on the minimum supported Git;
assert symbolic HEAD remains attached where intended.

### C6 · Surface selected-diff read failures as typed load state — S/M

Even after #36/#77, worktree and commit-file diff reads still use `try? ?? ""`,
so permission/corrupt-index/bad-object errors look like a legitimate “No diff.”
Replace string + boolean combinations with generation-gated
idle/loading/success/empty/failure state for both panes. Keep the selected
path/hash/side in request identity, show the sanitized Git error with Retry, and
never let an older failure/success replace a newer selection. Add deterministic
reverse-completion tests through an injected client plus real bad-object and
read-failure integration coverage.

---

## Performance & architecture

### P0 · Establish reproducible performance fixtures and measurements — S/M

Check in deterministic generators/manifests for a 10k-commit merge-heavy
history, a 50k-file worktree, and bounded plus oversized diff/process-output
cases. Record macOS, hardware, Git version, warm/cold state, iteration count,
median/p95 latency, peak resident memory, Git-process count, and phase timings
(Git execution versus parse/layout/render). Land the harness with current-
behavior guardrails (cold selected-repo load ≤10 read processes and a warm full
snapshot ≤8) plus an exact checked-in baseline manifest. P3/P4 then activate
the target gates: cold load ≤7, warm/manual full refresh ≤5, activation inside
the freshness TTL = 0, a same-domain event burst = one domain refresh,
status-plus-visible-diff invalidation ≤2, and a mutation's necessary commands
followed by at most one authoritative refresh. P5 activates default retained-
capture gates of 8 MiB for display stdout, 256 KiB for a diagnostic stderr tail,
4,000 parsed diff rows, and one 64 KiB streaming chunk; a structured record
above an explicit 8 MiB record limit fails rather than truncates. Do not make
P0 fail against targets owned by later tasks. CI asserts the gates activated by
the landed architecture and logical buffer sizes, not environment-sensitive RSS.
On the documented reference machine, take five warm-ups plus 30 samples and
fail a performance PR whose median regresses by >10% or p95 by >20% without an
explicitly accepted trade-off; record RSS statistically there. Every
performance PR below must publish its before/after fixture and measurements so
“faster” remains falsifiable.

### P1 · Replace root-mtime polling with tiered FSEvents observation — M/L

The watcher polls Git metadata and the worktree root every 2.5 seconds. Editing
an existing nested file changes neither; creating a nested file changes only
its immediate directory, so Changes can remain stale indefinitely while the app
and editor stay open. Linked worktrees also keep shared refs in the common Git
directory, which is not watched. Use one debounced, file-event-aware FSEvents
stream for worktree changes and observe both absolute Git dir and common Git
dir. Classify events: worktree/index → status plus visible diff; HEAD/refs →
branches/history; config → remotes. The callback must only enqueue P3 domain
invalidations, never launch Git itself. Fully reconcile and restart observation
after `MustScanSubDirs`, user/kernel dropped events, event-ID wrap, or a watched
root move/change. Test deep writes/create/delete, linked-worktree refs, excluded
directories, rename storms, burst coalescing, dropped events, and root moves.

### P2 · Suspend or evict inactive repository view models — M

Every repository ever selected retains its view model, history/layout, loaded
diffs, activity bridge, and timer. Forty visited repositories mean forty timers
and roughly 200 metadata probes per second although only one is visible. Watch
only the selected repository; keep cheap summaries/drafts separately and use an
LRU/TTL for heavyweight state. Resume plus refresh on selection, release large
diff/history buffers on eviction, and move filesystem observation off the Git
serial queue. Test selection churn and ensure summary callbacks do not retain an
evicted model.

### P3 · Introduce one refresh coordinator with invalidation tiers — M/L

View appearance, app activation, discovery, sidebar summary sweeps, watcher
events, and the active model can initiate overlapping work through different
Git clients. PR #65 removes two known duplicate triggers, but ownership remains
distributed. Create a path-keyed coordinator with generation tokens, in-flight
coalescing, a short freshness TTL, and explicit `status`, `refs/history`,
`config`, and `full` invalidations. Route instantiated repos through their
serial executor, key ownership by normalized repository identity, and make C1's
generation primitive the first reusable slice of this API. Manual refresh and
authoritative post-mutation refresh must bypass the freshness TTL; mutation
invalidation must neither join nor accept a pre-mutation in-flight result.
Watcher/FSEvents and config/ref changes likewise invalidate and bypass the TTL
for their affected domain. A spy runner should prove the P0 command budgets for
launch, activation, stage, commit, branch, fetch, and manual refresh, including
read-in-flight → mutation → late-read-completion ordering.

### P4 · Reduce snapshot process launches without turning failures into empty data — M

A full snapshot launches roughly eight Git processes: status, branches,
remotes, stash, Git-dir/operation probes, a redundant conflict query, and log.
Cache immutable/common Git directories, inspect operation markers directly,
derive conflicts from porcelain status, and retain remotes until config
changes while preserving the required serial Git access per repository. Remote
caching must wait for P1 or an equivalent config generation/fingerprint that
covers worktree, common, global, and `includeIf` config origins; until then a
manual full refresh reloads remotes. Do not introduce concurrent same-repository
Git calls without a separate architecture decision and safety proof. Today most
failures become empty arrays via `try?`; a corrupt index can thus present
“clean” and erase last-known history. Publish atomically, but preserve last-
known-good data per domain with freshness/error metadata. Assert the reduced
process budget deterministically and report warm visible-refresh latency and
memory against P0's fixed fixture.

### P5 · Bound process output and parse diffs incrementally off-main — M/L

GitShell fully buffers stdout/stderr, converts them to strings, and DiffParser
splits the complete output before enforcing its 4,000-line UI cap. AI generation
also obtains the complete staged patch before trimming. Large generated files or
noisy hooks cause multiple full copies and potentially millions of line
objects; parsing from a SwiftUI body can stutter. Define capture policy per
command: complete or incrementally parsed output for completeness-sensitive
status/refs/history and all `-z` framing; bounded display output for diffs and
log excerpts; bounded stderr ring tails for diagnostics. Continuously drain
both pipes. Never parse truncated structured output as complete—return a typed
failure when an incremental/complete policy cannot satisfy its bound. Parse and
cancel stale diffs on a worker, cache the parsed value, and key that cache by a
view-model request/revision identity rather than comparing the entire
up-to-4,000-line diff string during every body evaluation (specifically remove
`DiffView.ParseCache.key == diff`). Render clear truncated/binary/large-file
states with a guarded external-open action. Tests must exceed pipe-buffer and
configured limits on both streams, and prove structured truncation cannot
produce false clean/empty state.

### P6 · Add cancellation, progress, and bounded clone behavior — M/L

Fetch, pull, push, and clone retain no cancellable process handle or timeout. A
dead VPN, credential helper, signing tool, or hook can jam a repo queue
indefinitely. Clone also bypasses the repository activity log. Introduce a
cancellable process registry that owns the process tree/group, streams
sanitized stderr progress, and exposes a Cancel control. Cancellation must
capture a dedicated child process group atomically at spawn, then escalate INT
→ TERM → KILL to that proven group with bounded pipe draining and guaranteed
registry cleanup. Cover descendants such as hooks, credential helpers, SSH, or
signing tools, but do not signal a separately daemonized helper by an unproven
or potentially reused PID; report any survivor the group cannot own. Apply
automatic timeouts to clearly network-only phases, not arbitrary local
mutations, and route clone through an activity-bearing operation object. A pull
is not a single safe “network” phase: retain `git pull` with user cancellation
and no automatic integration-phase timeout by default.
Splitting it into fetch plus merge/rebase is only an investigated alternative
if parity is demonstrated for upstream/refspec choice, `pull.ff`, rebase and
autostash, recurse-submodules, hooks, multi-head fetches, operation detection,
and recovery. Integration-test blocked fetch/clone/push, pull before/after
integration starts, descendant termination, escalation, pipe drainage, final
state, and that the next operation can run.

### P7 · Split observation domains and remove per-render linear work — M

`RepoViewModel` publishes snapshot data, every draft keystroke, selection/diff
state, activity history, and operation state. An eight-command refresh can
invalidate History, Changes, Branches, toolbar, and status bar at least sixteen
times before snapshot publication. Split activity, draft, selection/load state,
and repository snapshot into narrower observable objects (or adopt Observation),
suppress identical publishes, and publish core snapshots once. Replace
`commits.map(\.hash)` and `Array(visible.enumerated())` construction in view
bodies with stable IDs/indices; memoize history filtering by `(query,
commit-generation)` so a selection-only render does not rescan every loaded
commit. Add signposts and use P0's 10k-commit fixture to report phase/body counts
and assert that a draft keystroke does not re-evaluate History and an activity
event does not republish unrelated snapshot domains.

### P8 · Make history pagination incremental and memory-bounded — M/L

Load More raises a limit, refetches from zero, and recomputes the whole graph
prefix; the larger limit then applies to every later refresh. Work becomes
quadratic by page count, and layout retains flat plus per-row segment arrays.
Offset pagination with `--skip` can make app parsing/layout incremental only
after validating every `--all` ref root and graph-affecting generation;
otherwise rebuild. It still makes Git walk/order/discard the skipped prefix, so
cumulative Git work remains offset-linear per page and can still be quadratic
over many pages. Measure Git execution separately from parsing/layout before
choosing offset pagination or a continuation strategy. Develop
continuation-compatible layout or document why a full relayout is necessary,
make row buckets canonical, and cap/evict old pages. Property-test append layout
against full layout on random DAGs, then publish latency and peak-memory results
for P0's 10k-commit fixture with explicit page count and warm/cold state.

### P9 · Isolate ownership and build the state-management test seam — M

History limit/load-more state is main-owned but read from the repo queue; models
lack actor annotations; and view-model creation can start Git work as a SwiftUI
body side effect. Mark UI models `@MainActor`, capture immutable request values
before queueing, keep generation counters on one executor, and explicitly start
selected models outside `body`. First inject a Git runner/client, scheduler,
clock, and filesystem events (#82 already injects defaults into AppState and
RepoStore). Required deterministic cases: reverse-
order completions, partial snapshot failure, watcher coalescing, summary
generations, mutation admission, huge dual-pipe output, cancellation, diff cap,
and 10k-commit layout. Enable strict Swift concurrency checks incrementally;
the project still compiles in Swift 5 language mode.

### P10 · Clean up low-cost accumulated work — S

Remove unused `GraphPalette.colorIndex(forLane:)` unless lane-stable colors are
adopted. Move duplicated path/date/host formatting to one utility and finish
using `NSPasteboard.copyString` at remaining inline call sites. Debounce
RepoStore's synchronous full-list encode when star/reorder/register operations
are bursty (#82 already supplies an isolated defaults suite). These are
suitable as one mechanical PR with targeted unit tests, not a redesign.

---

## Missing features (ranked)

### M2 · Blame view — M

The last classic read-only git view missing. Deliberately use `git blame
--line-porcelain -- <literal-path>`: repeated metadata is larger but permits a
bounded streaming parser without `--porcelain`'s cross-line commit-metadata
cache. Add pure `BlameParser`, `GitClient.fileBlame`, and rows with
author/date/commit chip plus monospaced content; enter from Changes and commit
detail (with the selected revision). Test repeated commits, boundary commits,
quoted/Unicode paths, binary/huge files, and malformed records. Reblame from
parent can follow.

### F15-remainder · Prune stale tracking refs and repair upstreams — S/M

#84 is implementing destructive “Delete on Remote…”. The distinct remaining
action is “Prune Stale Tracking Branches” (`git remote prune <remote>`), which
deletes only obsolete local `refs/remotes/*`, plus remediation on #40's
upstream-gone badge: Re-publish (`push --set-upstream`) and Unset Upstream
(`branch --unset-upstream`). Use structured remote/branch identity (never split
on the first slash), show the exact remote in confirmations, and integration-
test that pruning removes tracking refs without deleting server branches, using
two bare remotes including a slash-named remote.

### F16 · Multi-select in the Changes lists — M

The file lists are single-click rows; staging 10 of 12 files means 10 round
trips. Use `List(selection: Set<ChangeSelection>)` keyed by #77's path **and
staged/unstaged side**, because a partially staged path exists in both sections;
then add bulk Stage/Unstage/Discard (the VM APIs already take arrays) and
“Discard All…”. Define whether moved rows transfer or clear selection. Test the
same path selected on both sides, mixed batch success/failure, and refresh while
a batch is in flight.

### F18 · Branch list has no filter and the picker no search — S

A repo with 100+ branches makes both `BranchesView` and the toolbar picker
unusable. Add the same debounced filter-field pattern HistoryView already has
(reuse its filter bar), and consider sectioning the picker (current, recent,
all).

### F19 · Open a historical blob in the preferred editor — S/M

F24 owns historical Quick Look and V3c owns patch copy/export. This distinct
task adds “Open This Revision in Editor” to commit-detail rows: materialize
`git show <hash>:<literal-path>` with its useful extension, launch U5's selected
editor, and retain it in a bounded app-owned temp cache until TTL/app exit—an
open acknowledgement does not prove the editor has read asynchronously. Clean
stale cache files at launch. Test renamed/deleted/binary/oversized blobs, editor
launch failure, and a delayed-reading fake opener.

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
(`for-each-ref refs/tags` — extend `branches()` or add `tags()`). Add explicit
“Fetch All Tags” and “Push Tag…” actions so the ordinary sync path can retain
Git's safer reachable-tag behavior from #72.

### M7 · File history (log of one path) — S/M

Reuse `parseLog` and the existing history list in a sheet/detail pane. From
Changes run `git log --follow HEAD -- <literal-path>`; from a CommitDetail row
start at the selected commit and that revision's path (`git log --follow
<selected-hash> -- <literal-path>`), so deleted/historical files neither miss
history nor include later commits. Test rename continuity, deletion, a
historical entry point, literal pathspecs, and a path reused after deletion.

### M8 · Stash preview — S

Stash rows have no diff. `git stash show --stat -p stash@{n}` → render in the
existing `DiffView` on selection in the Branches tab (mini split or sheet).
Test: parser-free (reuse diff pipeline); integration assert on staged content.

### M11 · Per-repo identity override — S

View/set `user.name`/`user.email` per repo (Settings sheet or Repository menu):
`git config --local`. Show current values in the commit box tooltip. Common
"wrong email" pain point.

### M12 · Clone options — S

Add `--depth` (shallow) toggle and `--recurse-submodules` to the clone sheet;
default the destination to the last-used parent folder (UserDefaults), show
estimated progress (P6 dependency).

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
are valuable without a full todo-editor UI. Do **not** reuse #42's
`@{upstream}..HEAD` marker as the safety predicate: it is empty without an
upstream and can include a commit reachable from another remote branch. Add a
separate check against all fetched `refs/remotes/*` (honestly phrased as “not
known reachable from any fetched remote”), require a clean/no-operation linear
range from HEAD, and warn when fetch data is stale. Test no-upstream, another-
remote reachability, merges, detached HEAD, stale refs, and partial failure.
This is the flagship follow-up after the basics; design first, then implement.

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
only the target path differs. Resolve it with `git rev-parse --git-path
info/exclude` (not `gitDir()/info/exclude`, which is wrong for linked worktrees),
then resolve a relative result against the worktree while accepting an absolute
one. Integration-test both ordinary and linked worktrees: the file disappears
from status without touching `.gitignore`.

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
QuickLookUI's `QLPreviewPanel` (system framework, zero third-party dependencies).
Changes previews the worktree file; commit detail must materialize `git show
<hash>:<literal-path>` rather than opening the current version. Use a bounded
temp cache with lifetime appropriate to `QLPreviewPanel`, plus cleanup on panel
close/app launch. For deleted/unavailable/oversized blobs, show an honest state.
Test added, modified, deleted, renamed, binary, and historical-only paths. Half
of “did I mean this file?” checks need no diff.

### M24 · Initialize a repository in an existing folder — S

Add “Create New Repository…” / “Initialize Here…” using `git init`, with an
initial-branch field and optional README/`.gitignore`. Validate the destination
before mutation, register only after success, and keep the sheet open on error.
Integration-test empty/non-empty folders, an already nested worktree, invalid
branch names, and a configured non-`main` Git default.

### M25 · Repository-wide history search — M

Current filtering only searches the commits already loaded. Add a separate Git
query for message, author/email, hash prefix, path, and ref/decorations with
pagination and jump-to-result. Clearly distinguish local filtering from
repository search; do not relayout a misleading subset graph. Parser tests
should cover non-ASCII metadata, literal path input, empty results, and results
outside the first loaded page.

### M26 · Extend automatic fetch safely across repositories — M

PR #23 shipped interval fetch for the active repository. Extend it, optionally,
to starred repositories one at a time, paused on battery saver/constrained
networks and never during another mutation. Persist/display the last successful
fetch and expose “Fetch All” in a cross-repository dashboard. Keep cross-repo
fetch off until cancellation/progress (P6) is solid. Test scheduler coalescing,
app sleep/wake, failure backoff, and that no credentials are prompted.

### M27 · Instant reopen from a validated snapshot — M

Persist a compact last-known status/branch/history prefix for immediate window
restoration, mark it visibly stale, then validate in the background. Version
the schema, cap its size, and never treat a failed refresh as clean. This pairs
with P2 model eviction and must not persist diff/source content. Test corrupt
and old schemas, moved repositories, stale dirty state, and atomic replacement.

---

## Visual & layout

### V0 · Make the shell responsive at its declared minimum width — M

At 860 pt, a 200 pt sidebar plus fixed 360 pt detail leaves little room for
graph lanes, a fixed date column, subject, and author. Changes asks for two
320 pt panes, while its one-line Generate/count/Amend/Commit row cannot survive
localization or larger text. In this task, let Changes stack/collapse panes
below a threshold and allow commit controls to wrap; F27 and F28 cover the
inspector and toolbar independently. Exercise an English-expansion pseudo-
locale, larger accessibility text, the narrowest window, and a wide external
display.

### V1 · Diff line numbers + gutter — S/M

Add old/new line-number columns and a +/- gutter to `DiffView`. Requires hunk
parsing to track running line numbers (extend `DiffParser`: emit line numbers on
each `DiffLine`, or a parallel array). Monospaced alignment; dim gutter color.
For combined `@@@` conflict hunks, either render one gutter per parent plus
result or deliberately show no numbers—an old/new pair is incorrect. Parser
tests cover ordinary/multiple hunks and merge-conflict combined headers.

### V2 · User-controlled diff/detail text sizing — S/M

Fixed text sizes do not adapt well to large accessibility text or dense review.
Add a persisted compact/comfortable font scale for diff and commit-detail text,
with sensible system-relative defaults; line-number gutters, row height, tabs,
and horizontal scrolling must remain aligned. Test the smallest/largest setting,
Increase Contrast, long Unicode lines, and window-width transitions.

### F17 · Diff backgrounds don't span the scroll width (ragged blocks) — S/M

In `DiffView`'s two-axis `ScrollView` + `LazyVStack`, each line's `.background`
only extends to its own text width (the horizontal axis proposes nil width and
`maxWidth: .infinity` collapses to the ideal). Addition/deletion bands end
mid-pane at different x-positions — visibly scruffy next to every other git
client. The same structure defeats width caching, so parent publishes re-layout
the visible set. **Fix (one pass):** measure the longest line once per parsed
diff (the `ParseCache` from #30 already exists as the natural home) and lay
rows out at `max(measured viewport width, measured longest-line width)`. Measure
and cache away from `body`, expand tabs consistently, and test short diffs,
long Unicode/tabbed lines, resize, and horizontal scroll.

### V3a · Ignore-whitespace diff toggle — S

Put a persisted per-repo “Ignore whitespace” toggle in the sticky diff header
and pass `-w` through tracked, staged, commit, and untracked `--no-index` paths.
The loading identity/cache key must include the option. Integration-test a
whitespace-only file on both sides and rapid toggling while a diff is loading.

### V3b · Side-by-side diff — M

Add a unified/split display toggle. Factor deletion/addition-run pairing out of
#14's intraline emphasis, preserve unpaired lines, align line-number gutters,
and virtualize rows rather than materializing two complete text copies. Parser
tests cover unequal runs, no-newline markers, multiple hunks, long lines, and
binary/truncated sentinel rows.

### V3c · Diff navigation and export — S/M

Add previous/next file and hunk commands with visible buttons and shortcuts,
plus Copy Full Diff and Save Patch. Keep selected side/path in the command's
identity and disable export when output is truncated unless the user explicitly
loads the full patch. Test boundary wrapping, empty/binary diffs, and filenames
requiring literal pathspec handling.

### V3d · Native binary and image diffs — M

Detect binary/image paths before presenting an empty textual patch. Show file
metadata for arbitrary binaries and native Quick Look; for supported images,
materialize both revisions and offer side-by-side and overlay-slider modes.
Define pairs exactly: unstaged index↔worktree, staged HEAD↔index, and commit
selected-parent↔commit (require parent choice for merges); additions/deletions
are one-sided. Include side/hash/parent/path in cache identity. Use bounded temp
storage and handle added, deleted, renamed, oversized, unavailable blobs without
blocking main.

### V4 · Decoration overflow "+N" is a dead end — S

`+N` for commits with >3 refs is plain text. Make it a popover listing every
decoration (clickable → checkout for branches, copy for tags). Small win, big
repos with many tags (linux-style) currently lose information.

### F47 · Diffstat bars in commit-detail files — S/M

Commit-detail file rows show only status. Extend the existing single commit-file
query to collect `--numstat` additions/deletions (never spawn per row), parse
rename/copy and binary `-` values, and render aligned counts plus a subtle
relative bar. Keep huge generated files from dominating the scale. Pure tests
cover ordinary, renamed, copied, binary, zero-line, quoted, and Unicode paths;
verify color is not the sole status cue.

### F48 · Hover details on graph nodes — S

Give each graph dot a stable hit target and a native hover help/popover with
subject, author, exact date, short hash, refs, and unpushed state—all from the
loaded commit, with no Git call. It must not interfere with row selection,
scrolling, or lane drawing, and needs an equivalent VoiceOver description.
Test the hit geometry at compact/comfortable density and multi-lane rows.

### V9 · Date column width — S

Fixed 110 pt truncates with longer localized formats; measure or use
`fixedSize` + layout priority. Verify with a pseudo-localization build
(×LL length strings).

### V11 · File-type icons / language-color dots — S/M

Status letters only today. SF Symbol per extension (swift, py, md, json, png…)
or GitHub-linguist color dots (ship a tiny bundled JSON keyed by extension).
Renders in Changes rows and CommitDetail file lists.

### V12 · Accessibility pass — M

History/changed-file rows use tap gestures rather than standard selectable
controls, graph strips are opaque to VoiceOver, and chips/status letters/dots
lack meaningful labels. Give rows standard selection/focus behavior plus
combined labels and custom actions; speak commit/author/date/refs/unpushed,
modified/added/untracked/conflicted, dirty state, and ahead/behind phrases.
Changes must expose select/stage/unstage/discard; Branches must expose selection,
checkout/merge/rename/delete; History must expose selection/open/copy. Announce
operation and error banners. Acceptance: complete ordinary commit/push and
branch-checkout flows with VoiceOver and Full Keyboard Access; audit Increase
Contrast, Reduce Motion, color filters, larger text, and pseudo-localization.

### V13 · Restore the main window from every app lifecycle state — S/M

Runtime-test closing the main window while Activity or Settings remains open,
then activating from Dock, application menu, and Finder. If the main scene does
not return, add an “Open GitEnough Window” command and correct Dock reopen
handling without allowing duplicate main windows. Add whatever lifecycle seam
is feasible, plus a documented manual macOS test matrix.

### F26 · Truncated paths have no tooltip — S

File rows truncate middle (`ChangesView`, `CommitDetailView`) but don't set
`.help(file.path)`; sidebar rows same for the abbreviated path. One modifier
per row.

### F27 · Fixed 360 pt commit-detail pane — S/M

The detail column is hard-fixed at 360 pt (a deliberate anti-drift choice per
the comment in `HistoryView`). On a 27" display the history list is cavernous
while file paths in the detail truncate; at 860 pt it crowds out history.
Replace it with a collapsible/resizable Inspector, persist the user's width,
and auto-collapse below a tested window threshold while retaining an obvious
reopen control. Test resize/restoration at minimum and wide widths, long paths,
and large text.

### F28 · Toolbar branch picker can dominate the toolbar — S

`.fixedSize()` on the picker label lets a 60-char branch name push the
fetch/pull/push cluster off-window. Cap with `.frame(maxWidth: 260)` + middle
truncation.

### F29 · Ref chips: HEAD chip crowding — S (design)

`RefChip` renders HEAD + branch as two chips on the same commit
("HEAD" + "main"), spending row width twice for one fact. Collapse
`HEAD -> main` into a single accented chip ("● main"), keep plain "HEAD" only
for detached. Before code, add a small state sheet for attached, detached,
multiple-local, tag, remote HEAD, overflow, dark and high-contrast cases. Pairs
with A5 (lane-colored chips) and V4 (+N popover).

### F30 · Selection highlight is two disjoint rectangles — S

Graph strip and row text each paint their own `accentColor.opacity(0.20)`
(`GraphStripView` + `CommitRowView`), meeting at a visible seam when lane
counts squeeze widths. Paint one full-row background behind an HStack of
[strip, row] instead.

---

## Interaction & UX

### U0 · Make the everyday path self-explanatory — M (design first)

The toolbar presents Fetch, Pull, Push/Publish, branch, tabs, and status as
separate facts; the user still has to infer the next step. Prototype one
context-aware primary Sync control: “Fetch,” “Pull 3,” “Push 2,” or “Publish
Branch,” with a menu for variants. Add counts to the relevant tab (“Changes
7”), and consider a restrained Stage → Message → Commit → Push progression in
the Changes pane. Before code, commit a state/label matrix and narrow/wide
wireframe covering every capability. The Repository menu should expose Commit,
Stage All, Unstage All, and Stash with the exact predicates as buttons. Validate
with keyboard-only walkthroughs of fresh clone, first publish, ordinary commit,
behind/diverged branch, detached HEAD, in-progress operation, and no remote.

### U0a · Put primary branch actions in sight — S/M

Checkout, “Merge into `<current>`,” Rename, and Delete are mostly hidden behind
context menus or double-click. Give the selected branch a compact action area
or trailing primary button. Always display the actual remote selected for
publish, push, and PR actions rather than treating the first configured remote
as truth. Test long/slash-named branches, multiple remotes, remote-only branches,
and a 500-row list with Full Keyboard Access.

### U0b · Report outcomes and disabled reasons — S/M

A spinner disappearing is weak confirmation. Show short nonmodal outcomes such
as “Pulled 4 commits,” “Pushed 2,” and “Fetched just now,” with an Activity link
for details. Disabled controls need a reason in help/accessibility text: create
the first commit, add a remote, publish/set upstream, finish the current
operation, or wait. Add recognized recovery hints beneath raw errors (pull
first, remove stale index lock, configure identity); never hide the Git output.

### F49 · Say what a successful fetch discovered — S/M

“Fetched just now” still hides the useful result. Capture remote-tracking tips
immediately before and after a successful app fetch, compute newly reachable
commit counts per updated branch, and show “3 new commits on origin/main” (or a
compact multi-branch summary) with an Open History action. Do not label commits
already reachable before fetch as new, and do not persist a misleading count
across ref rewrites. Test fast-forward, force-update, deleted/new branches,
multiple remotes, zero changes, and a fetch followed by an immediate pull.

### U0c · Make file identity and diff context unambiguous — S/M

Render renames/copies as `old/path → new/path`, emphasize basenames with the
parent path secondary, and speak/read status words instead of relying on raw
letters. Establish one sticky diff-header component containing filename,
staged/unstaged side and statistics; V3a–V3d and F24 plug whitespace,
navigation/export, binary handling, and Quick Look into that component. Hard-
reset copy must explicitly say untracked files are preserved. Tests pin rename
presentation, side labels, status accessibility strings, and long-path layout.

### U0d · Add an intentional clean/empty Changes state — S

When clean, collapse inert stage sections and the commit form into a positive
“Working tree clean” state with the next useful sync action. No stashes, no
branches/remotes, and no filter matches similarly need task-oriented Clear,
Create, Add Remote, or Publish affordances. Show sidebar paths primarily to
disambiguate duplicate names (or on hover/roomy mode), and turn the permanent
drop footer into an active drag overlay or empty-sidebar instruction.

### F51 · Turn Welcome into a useful launch surface — S/M

The static Welcome view should present clear Add Existing, Clone, and Initialize
actions, plus recent valid repositories when there is no registered selection.
Show why a missing recent path cannot resume and offer Remove/Locate instead of
silently doing nothing. Keep primary actions keyboard reachable and avoid
duplicating the sidebar once #82 has selected a valid repository. Test empty
first launch, all repositories missing, restored selection, and recent-list
deduplication.

### U1 · Keyboard navigation in History, Changes, and Branches — M

History is a `ScrollView` with tap rows, while the other primary lists have no
coherent focus contract. Introduce Up/Down selection in all three panes; Return
opens commit detail, opens the selected file diff, or performs the clearly
labelled branch primary action. Preserve focus/selection as files move between
staged and unstaged sections and keep the graph highlight synchronized with
`selectedHash`. Add ⌘C for the selected commit hash/path/branch name. Test empty
sections, filtering, list refresh, repo switching, and Full Keyboard Access.

### U2 · Stage/unstage/discard shortcuts — S

⌘⇧↑/⌘⇧↓ (or ⌥↑/⌥↓) for stage/unstage selected change; ⌫ opens the discard
confirmation; ⌘⇧N new branch. Wire in `ChangesView` via `.keyboardShortcut`
on the row actions or hidden menu commands.

### F50 · Keyboard-shortcut cheat sheet — S

Add a Help → Keyboard Shortcuts (⌘/) sheet grouped by Repository, Changes,
History, and Branches. Generate rows from the same action descriptors used by
menus so labels and availability cannot drift; include a search field and a
short Full Keyboard Access note. Test duplicate/conflicting key equivalents and
ensure every advertised shortcut has a live command.

### U4 · Double-click conventions — S

Keep local-branch double-click as Checkout; make remote-branch double-click
perform the existing tracking checkout; make history double-click open/focus
commit detail. Never assign a destructive action to double-click. Use the same
methods/capability checks as visible controls, add `.help`/accessibility hints,
and test current branch, remote-name collision, detached state, and busy state.

### U5 · Preferred editor integration — S/M

“Open in Terminal” is not enough for the most common file workflow. Detect
Xcode, VS Code, and JetBrains applications, let the user choose a per-app
preferred editor, and add Open File/Repository in Editor beside Finder and
Terminal actions. Use `NSWorkspace` application URLs rather than constructing
shell commands. Fall back gracefully when the preferred app is removed.

### U6 · Background-completion notifications — S/M

Long fetch/push finishing while unfocused is invisible. Local user notification
(UNUserNotificationCenter, permission requested lazily on first background op;
errors only by default). Respect a Settings toggle.

### U7 · Open-on-remote deep links — M

Reuse `ForgeRepo` detection to add forge-aware labels (“Open on GitHub,” “Open
on GitLab,” “Open on Forgejo,” “Open on Bitbucket”) for repo, current branch,
selected commit, and file-at-commit. Extend its tested URL builders for those
deep-link shapes, including supported self-hosted GitLab/Forgejo and
bitbucket.org; use neutral “Open on Remote” only when a generic safe URL is
known, otherwise hide the action.

### U8 · Stash everywhere — S

#44 makes Stash available for staged-only changes. Finish the discoverability
work with a Repository menu item + ⌘⇧S, and make the status bar's “N stashed” a
popover listing entries with Preview (M8), Apply, Pop, and guarded Drop. Menu,
Changes, and popover must share one capability predicate. Extend `StashEntry`
with `%H`: ordinals such as `stash@{2}` renumber after external operations, so
re-resolve and verify the expected OID on the repo queue immediately before
Apply/Pop/Drop. Test external insertion, reorder/removal, stale confirmation,
and that the wrong stash can never be dropped.

### F32 · Stage/unstage icons flip meaning with no animation — S

The row action button switches `plus.circle`/`minus.circle` instantly as the
file jumps lists; the file appears to teleport. A `withAnimation` on the list
change (or matchedGeometryEffect at higher effort) makes stage/unstage legible.
Micro-polish with outsized perceived-quality payoff. Under Reduce Motion, use a
brief opacity cross-fade or no transition rather than spatial movement.

### F33 · Destructive dialogs can act on stale captures — S

Confirmation dialogs (`Discard`, `Hard reset`, `Force delete`) act on state
captured in `@State` vars that survive re-presentation; "Discard Changes" on a
stale `fileToDiscard` after a background refresh swaps the list is possible.
Clear the captured item when the snapshot no longer contains it (mirror the
selection-following logic added in #16).

---

## Aesthetics

### A0 · Unify the app's visual language — M (design first)

The cobalt toolbox icon is distinctive but loses Git identity at 16–32 px; the
asset accent is warm coral, graph lanes use a separate palette, and most UI
surfaces fall back to stock gray. Define one small semantic palette connecting
the icon, active branch, graph lane, selection, primary sync action, and status
pills; reserve orange/red for warning and destruction. Produce simplified
small-size icon variants and branded-but-quiet empty states. Verify light/dark,
Increase Contrast, and common color-vision filters before implementation. The
design gate is a checked-in token table plus icon/contact sheet at 16, 32, 64,
and 128 px; no broad recolor starts until those artifacts are reviewed.

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

### F34 · The commit box reads as an afterthought — S/M (design)

A borderless `TextEditor` with a 1 pt stroke, a tiny Generate button, and the
72-char counter crammed inline. Suggestion: give the subject its own
single-line field (auto-advancing to a body field on ⏎ — this also makes the
72-char rule structural instead of advisory), move Generate into the field as
a trailing sparkle icon, and let the box grow with content up to ~6 lines.
First check in a narrow/wide and empty/typing/generating/error wireframe plus a
focus/Return-key state table; implementation must preserve multiline paste,
amend warnings, draft persistence, spell checking, and large text.

### F35 · Present AI text as a proposal, not an overwrite — S/M

#81 prevents stale responses from replacing newer input, but a valid response
still takes over the editor. Keep the user's draft and show one to three compact
proposal cards with Accept, Replace, Regenerate, and Dismiss/Undo. Never alter
the draft or staged state until explicit acceptance. A pure reducer test should
cover draft → request → edit → proposals, regeneration, acceptance, undo, and
commit/repository invalidation; cap concurrent requests and patch content.

### F36 · No motion anywhere — S (design)

Banners appear/disappear with a hard cut (`RepoDetailView` merge/error
banners), rows pop in on refresh. Two `withAnimation(.snappy)` transitions —
banner slide+fade, list diff animation — would remove most of the "prototype"
feel. First define a tiny motion spec (trigger, duration, curve, interruption,
Reduce Motion fallback); deliberately skip graph motion and never animate a
destructive confirmation or progress value merely for decoration.

---

## Novel / delightful

### Q1 · Reflog-powered Undo (⌘Z) — M/L — the killer feature

`git reflog` is right there, but blindly assuming `HEAD@{1}` is not safe because
hooks, tools, and external Git can add entries. First design an app-owned journal
recording operation kind plus exact pre/post HEAD/index/worktree identities and
whether the post-state was pushed. Phase 1 previews Undo for commit/reset/
checkout performed by GitEnough, refuses pushed or externally-diverged state,
and shows exactly what becomes staged/unstaged. Execute only after confirmation
and journal the undo itself; test external intervening refs, detached/unborn
HEAD, dirty trees, app restart, partial failures, and redo refusal. Phase 2 is a
read-only Safety Timeline combining that journal with reflog.

### Q2 · Command palette (⌘⇧P) — M

Fuzzy-searchable actions + repos + branches + commits ("checkout feature",
"fetch", "discard all", "open in terminal"). A tiny scoring function is pure and
testable; subsumes U5-style quick switchers. Natural extension surface for
everything in this backlog.

### Q3 · "Trace branch" graph interaction — M

Click/hover a lane: its whole ancestry lights up, everything else fades
(IntelliJ-style). Pure reachability computation over the loaded commit graph
(parents map) — fully unit-testable; rendering picks per-node emphasis alpha.

### Q4 · Optional "Generated with GitEnough" footer — S

✨ Generate may append a configurable human-readable footer
(`🤖 Generated with GitEnough`). It is **off by default**, lives in Settings →
AI, and is added only when the user accepts a proposal. If interoperability is
desired instead, use a real parseable trailer such as `Generated-With:
GitEnough`; do not call the emoji sentence a Git trailer.

### Q5 · Local activity sparklines — S/M

Cache 30-day `git log --since` counts per repository/day and render a tiny,
low-contrast sparkline in sidebar rows; the selected repo can additionally show
the current author's streak in the status bar. Never query per render or per
refresh. Zero network, useful texture, and easy to disable with Reduce Motion
even though it remains static.

### Q6 · Repo Launchpad — M

Add an optional cross-repository dashboard grouping summary-cache data into
Needs Commit, Needs Push, Needs Pull, Conflicted, and Synced. Rows jump directly
to the relevant tab/action; “Fetch All” runs serially with progress and cancel,
never starts a second operation for a busy repo, and reports partial failures.
The dashboard must issue no per-render Git calls and must label stale summaries.
Test grouping transitions, removed/missing repos, ordering, and batch control.

### Q7 · Toolbox latch when everything is safely synced — S

When the selected repository is clean, has an upstream, is neither ahead nor
behind, has no operation/conflict, and has a recent successful fetch, briefly
settle the toolbox/branch mark into a restrained “latched” state labelled as
synced with the last fetched state. It is soundless, never blocks input, never
runs for clean-but-unpublished work or after failed/stale/no-network fetch, and
becomes static under Reduce Motion. Pin the predicate and show the design at
16/32 px before adding the micro-animation.

### Q9 · Ambient "dirty tree" nudge — S

Working tree dirty for > N minutes → subtle tint/badge on the Changes tab
segment. No modal nagging.

### Q11 · Graph rainbow easter egg — S

One-shot palette animation on the History tab: ⌥-clicking the History tab
title replays the graph's palette assignment as a ~0.8 s cascade. Zero value,
pure joy; a deliberate easter-egg surface beats a build flag. Disable the
animation under Reduce Motion while keeping a harmless static palette flash.

### Q12 · Drag a commit onto a branch — M

Phase 1 is deliberately only “Cherry-pick C onto B.” Accept local branches not
checked out in another worktree, require a clean/no-operation repository, and
show a preview explaining that GitEnough will check out B and remain there if a
conflict occurs. Record the original ref; on success offer Return to Original
Branch, while conflict recovery stays on B using the normal banner. Reject
self/ancestor no-ops and merge commits unless the user chooses a parent. Tests
cover cancellation, checkout failure, conflict, linked-worktree target, detached
origin, and successful return. Rebase-on-drop is a later design, not phase 1.

### Q13 · Gravatar avatars in history — S

`Insecure.MD5(lowercased email)` (CryptoKit) →
`gravatar.com/avatar/<hash>?d=identicon&s=32` in a 16 pt circle beside the
author in each history row. Because the hash still discloses identity to a
third party, make this an explicit opt-in and cache results away from scrolling.
One `AsyncImage`; zero dependencies.

### Q14 · "Explain this commit" (AI) — S/M

Detail-pane button → send the commit's patch (capped, like the commit-message
flow) to the configured LLM → plain-English summary sheet. Reuses
`CommitMessageGenerator` plumbing with a different system prompt. Great for
archaeology in unfamiliar repos.

### Q15 · AI-assisted conflict resolution — M/L

Build only after C2's deterministic three-way preview. Send bounded, explicitly
disclosed base/current/incoming hunks through the validated endpoint; never the
repository or unrelated files. Parse the response as a proposal in a temp file,
reject encoding/size violations and remaining conflict markers, and show a
three-way-to-result diff. Apply only after explicit acceptance, preserve a local
pre-accept copy for Undo, and do not auto-stage or mark resolved. Tests cover
malformed/truncated/hostile output, stale conflict identity, request cancellation,
privacy caps, apply failure, undo, and a conflict changed while the model runs.

### Q17 · Commit-subject autocomplete from history — S

Offer recent repo subjects as autocomplete/suggestions while typing in the
commit box (repo-local, no network). Subtle, surprisingly handy for repetitive
chores ("Bump …", "Fix typo …").

### F37 · AI: PR description from the branch — S/M

`git log <resolved-base>..HEAD` + diffstat → the existing
`CommitMessageGenerator`
plumbing with a PR-description system prompt → paste-ready title+body sheet
next to "Open Pull Request" (which already knows the base branch). Reuses
everything; pure win for the app's AI identity.

### F38 · AI: "Since you were away" repo digest — M

Persist the last-seen relevant local/remote tip when closing a repository and,
on return, summarize the ancestry/range to the new tip into three bullets
(cached per old/new pair). Do not rely only on `--since=<lastOpenedAt>`: a newly
fetched commit can have an old author/commit date. When the baseline is missing
or no longer an ancestor after a force-push, use explicitly date-based fallback
wording. Test old-dated newly fetched commits, rewritten history, deleted refs,
first open, privacy caps, and cache invalidation.

### F39 · Branch cleanup assistant — S/M

"Clean up branches…" sheet listing local branches fully merged into the
resolved default branch (`git branch --merged <resolved-default>` or
`for-each-ref --merged=<resolved-default>`, minus current/protected), pre-
checked for bulk delete, with "also delete on remote" checkboxes where an
upstream exists.
The single most-wanted janitorial feature in every git GUI; trivially testable
in the integration harness. Pairs with F15-remainder.

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
workflow; resolve with `git config --path --get commit.template`, then normalize
any remaining relative result against the worktree before reading. Mind #54:
the template seeds only a box with no persisted draft. Test local versus global
config, tilde/space/relative paths, missing/unreadable files, and linked
worktrees.

### F43 · Menu-bar extra: "N repos need attention" — M

Optional `MenuBarExtra` listing repos that are dirty/behind (from the summary
cache — zero extra git calls), one click to open. Off by default per the
no-nagging philosophy (Q9's spirit).

---

## Suggested next pickups (highest value first)

1. **C5a/C5b** endpoint/key and on-disk activity privacy (source and secrets are
   the highest-cost data to send or retain incorrectly)
2. **C1/C6** generation-safe summaries and honest selected-diff failure states
3. **C5c** bounded Git detection plus cancellable signing stalls
4. **P0**, then **P9/P3/P4**: establish reproducible fixtures and the test seam,
   then centralize refresh/state ownership before changing the watcher or
   reducing Git process overhead
5. **C2/C3** conflict semantics and merge-tool leases (highest mutation risk)
6. **C5d/C5e** spoof-proof parser framing and per-command ref safety
7. **P1/P2** event-driven watching plus inactive-model lifecycle (fixes stale
   nested edits and eliminates idle polling)
8. **P5/P6** bounded streaming, off-main diff parsing, cancellation, and network
   progress (the performance/reliability foundation)
9. **F17** diff width/backgrounds, then **V1/V3a–V3d** gutters, split mode,
   images, whitespace and navigation (most visible polish cluster)
10. **F16** multi-select staging plus **U2** shortcuts (everyday friction)
11. **F15-remainder/F39** remote-branch maintenance and cleanup assistant
12. **M2/M7** blame and file history (last classic read-only archaeology tools)
13. **U0/U0a/U0b** one obvious sync path, visible branch actions, and meaningful
    outcome/reason feedback
14. **V0/V12** responsive layout and the full keyboard/VoiceOver pass
15. **M18** pull-autostash rescue and **F18** branch search
16. **Q1** reflog Safety Timeline and **Q2** command palette (differentiators)
17. **M15** minimal interactive rebase, guarded by a new all-remote reachability
    predicate rather than #42's upstream-only display marker
