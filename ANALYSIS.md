# GitEnough — Analysis & Backlog (ANALYSIS.md)

A living, shovel-ready backlog for GitEnough: every entry below is a concrete,
self-contained task with suggested approach and test plan, ready for an LLM (or
human) to pick up. This document consolidates eight independent full-codebase
reviews with everything learned while implementing the first five waves of
fixes: `glm.md` ×2, `kimi.md`, `fable.md`, `flash.md`, `sol.md`, and `k3.md`
from the earlier waves, and `opus.md` from wave 5 (2026-09-06). As those
eight review branches are retired, each finding was re-audited against
`main` (2026-09-11); everything they raised is
either shipped or already captured here, and the last live stragglers were
rescued into the **"Rescued from the review branches"** section below.

**Maintenance rule:** when an entry ships, delete it here (the git history
preserves it); when a new issue is found, add it with the same level of
concreteness.

Wave 5's six PRs are merged. What their review rounds raised and they did *not*
do lives in **"Review follow-ups from the wave-5 PRs"** below — each with the
measurement or `file:line` that makes it checkable, so none has to be
re-derived.

**How much to trust an entry.** Entries carry their own evidence, and the rule is
uniform: an entry that quotes a `file:line`, shows git output, or says "verified
against git 2.43" was **checked directly** — those are confirmed. An entry that
describes a symptom without either is a **lead**: a place to start looking, worth
reproducing before you plan around it.

This matters most for the wave-5 (`opus.md`) sections. Their adversarial
verification pass completed for only 3 of 13 review dimensions — 19 verdicts
against 185 raised findings — because the reviewing session hit its limit
mid-run. So the unquoted wave-5 entries are not *wrong*, they are *unconfirmed*,
and the first task in picking one up is confirming it.

Effort: **S** ≤ ~30 min · **M** half a day · **L** multi-day.

---

## Status snapshot (do not re-implement)

**Waves 1–3 are integrated into `main`.** PRs #1–#35 (wave 1) and the 51
non-superseded PRs of #36–#90 (waves 2–3) are merged; #36, #56, #74 and #85 were
superseded duplicates closed in favour of #77, #59, #47 and #63. The seven
cross-PR defects that merged without a conflict marker — invisible to every PR's
own CI — were fixed in the integration merge rather than deferred (X1–X5, since
removed as shipped).

The per-PR index of what each of those changes covers, the verified landing
order, and the reasoning behind each judgement-call resolution live in
**`docs/open-pr-review.md`**. It is not duplicated here; consult it before
assuming anything below is unimplemented.

**Wave 5 (2026-09-06)** shipped six changes from `opus.md`, each on its own
branch:

| PR | Covers |
|----|--------|
| #96 | Push sends an explicit `refs/heads/x:refs/heads/y` refspec instead of letting `push.default` decide — under `matching`, one force push rewrote every branch present on both sides. `PushCapability` rewritten around `forcePushTarget` as the single decision; force push withheld when the remote was *guessed* from a contested upstream; the confirmation dialog freezes the exact argv and refuses if it no longer matches at tap |
| #97 | A failed `restore --staged` no longer leaves a staged *deletion* — restore-first, with the unborn-HEAD fallback verified *after* the failure rather than inferred from it, and a compensating `reset` repairing the residual race; `discard` carries the same shape. A symlinked `.gitignore` is refused, since git will not read one. `.gitignore` appends are computed in bytes so a bare CR at the join can't destroy the preceding rule |
| #98 | Diff classification is a hunk state machine, so a diff line whose content starts with `--` or `++` stops rendering as a file header; every patch read passes `--no-color --no-ext-diff`, so a configured `diff.external` can no longer replace what the pane shows and what the model is handed |
| #99 | GTK lists no longer stage, check out, and apply stashes on a *single* click (`activate-on-single-click = 0`), matching the macOS front end's double-click; per-row tooltips |
| #100 | "Stage All" refuses while any path is unmerged, instead of `git add -A` staging conflict markers and clearing the unmerged state. One shared constant behind both the refusal and the tooltip, so they cannot describe the hazard differently — modify/delete conflicts have no markers at all |
| #101 | Every git child gets `/dev/null` on stdin, so a command that asks a question fails fast instead of blocking forever on the launching terminal's tty. That makes `git mergetool --no-prompt` load-bearing rather than a convenience, which is now pinned by a test — both rows of the matrix exit 1, so only a marker file distinguishes them |

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
- **#58 does not defeat #68.** #58 strips `GIT_LITERAL_PATHSPECS` from the
  *inherited* environment; #68 sets it as an explicit override for
  `git mergetool`. Overrides are merged after sanitization
  (`childEnvironment.merging(overrides) { _, override in override }`).
- **#64 survives #79.** `GitActivityLog.normalizedArguments` already strips
  `--no-optional-locks`, so activity display and the paste-safe copy stay
  correct once the flag is centralized.
- **#66's non-defaulted `Branch.refName` breaks no fixture.** `Branch(` is
  constructed in exactly one place in the repo (`GitParsers.swift`); no test
  builds one directly. (#40 and #90 add defaulted fields. All three still
  contend over `parseBranches` and should land as one deliberate change.)
- **#80's mutation gate cannot wedge.** `perform` funnels success and failure
  through a single `DispatchQueue.main.async`, so `operationGate.finish(id)` is
  always reached. Its `dispatchPrecondition(.onQueue(.main))` is also safe: the
  one non-UI caller, `AppState.autoFetchIfDue`, runs on a `RunLoop.main` timer.
- **#38's formatter change is correct.** `ISO8601DateFormatter`'s default
  `formatOptions` is exactly `[.withInternetDateTime]`, so dropping the
  per-call assignment (the actual data race) still parses `%aI`.

---

## Correctness & safety

### X6 · The GLM review check times out on anything but a small diff — S

`Review PR with GLM 5.2` fails on roughly 40 of the 55 PRs open before the
wave-2/3 integration, and the cause is not flakiness: the Z.ai request times
out. The job log shows the diff sent as one chunk and retried three times, each
attempt cut off at ~300 s — `API call failed for chunk 1/1, 2 file(s), 26369
patch chars … Request timed out` ×3, then `All review chunks failed.`

**Correction.** An earlier version of this entry blamed an unset
`MAX_DIFF_CHARS` and prescribed setting it so large diffs "split into several
requests". Reading `L-K-M/zai-code-review` disproves both halves:

- `MAX_DIFF_CHARS` does not split anything. `limitFilesByDiffChars` *drops whole
  files* once a total budget is exceeded, so setting it would have bought a
  green check by silently reviewing less — the opposite of the goal.
- Chunking is governed by a hardcoded `MAX_CHUNK_SIZE = 50000`. The failing diff
  was 26 369 patch chars, so it was correctly a single chunk. Nothing about the
  splitting was wrong.

The real cause is the hardcoded `REQUEST_TIMEOUT_MS = 300_000`, which is too
tight for this API even on small work. Successful reviews cluster right against
the ceiling rather than comfortably under it — 3m13s, 4m09s, 4m11s, 4m46s,
4m53s — so a run that "passes" at 4m53s is one that nearly missed. The request
is not streamed, so a crossed deadline discards the entire completion and the
retry restarts from zero.

Fix: L-K-M/zai-code-review#1 adds a `REQUEST_TIMEOUT_MS` input (default
unchanged at 300000). Once that is released, set it in
`.github/workflows/zai-code-review.yml` — around `600000` gives ~2× headroom
over the observed worst case — and raise that job's `timeout-minutes` above
`3 × timeout` so the retry budget still fits. This is a `pull_request_target`
workflow holding repository secrets, so treat the edit as privileged: keep the
existing same-repo `if:` gate, and re-pin the action SHA deliberately rather
than tracking a tag.

**Status: blocked on that upstream release, not on anything in this repository.**

**Timing correction (2026-09-07).** The 3–5 minute cluster above is stale, and
reading it as current will make you call a healthy run dead. Wave-5 rounds on
these diffs chunk into **four** sequential API calls, and successful rounds took
**49–59 minutes** — the 300 s ceiling is *per chunk*, so total job time scales
with chunk count. During this wave a round was nearly abandoned as timed out at
56 minutes and completed normally at 59. "No result yet at 45 minutes" is not a
timeout; distinguish by reading the job log, where a real timeout says
`Request timed out` and rate limiting says `HTTP 429` in well under a second.

**Two operational traps that cost real time this wave, neither of them about
this workflow's configuration:**

- **A PR whose merge ref GitHub cannot compute gets _no_ checks at all.** The
  symptom is the *absence* of checks, not red ones, so it reads as "still
  queued" indefinitely. After merging anything that conflicts an open PR, check
  `git merge-tree --write-tree origin/main origin/<branch>` rather than waiting.
- **Pushing a conflict-resolution merge cancels the in-flight review round.**
  Two PRs each lost a ~50-minute round that way, on the exact commits whose
  review mattered most. Sequence merges so a dependant's round lands *before*
  you merge the PR that will conflict it.

**Do not confuse this with the other red GLM check — `HTTP 429`.** Wave 5 opened
five PRs in quick succession and two of their review runs failed like this:

```
Processing 2 file(s) in 1 chunk(s) … 25000 max patch characters
API call failed … (attempt 1/1) after 804ms: Z.ai API: HTTP 429.
API call failed … (attempt 2/3) after 443ms: Z.ai API: HTTP 429.
API call failed … (attempt 3/3) after 429ms: Z.ai API: HTTP 429.
```

That is account-level rate limiting: it fails in **under a second** per attempt
on a 2,733-character patch, where X6 sits at exactly 300 s on a large one. The
two are told apart by the timing, not the outcome. The practical mitigation is
operational rather than code: **pace pushes across PRs**, since concurrent runs
against one account are what triggers it. Raising `REQUEST_TIMEOUT_MS` will do
nothing for a 429.

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

### C5b · Create the activity history `0600` — S  ·  *rescoped: half shipped*

**Redaction already shipped.** `GitActivityLog.redactCredentials` exists and is
applied to argv (`GitActivityLog.swift:172`, `:200`) and to stderr tails
(`:127`). The original entry asked for redaction *and* file permissions; only
the second half remains, and it is three lines rather than the S/M implied.

The JSONL is written with `Data.write(to:options:.atomic)` and no
`.posixPermissions`, so it lands at `0644 & ~umask`. Because `.atomic` renames a
fresh temp file over the old one, a user who chmods it to `600` has that undone
by the next compaction. On macOS the containing directory is usually `0700`, so
the exposure is limited; on Linux `~/.local/share` is `0755`, so the file is
genuinely world-readable.

Fix: pass `.posixPermissions: 0o600` on create, and re-apply the mode after
every atomic compaction (the rename is what loses it). Test: assert mode `0600`
after creation, after append, and after compaction — the third is the one that
regresses.

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

### glm-B5 · Repo renamed on disk keeps a stale sidebar name forever — S

`Repository.name` is snapshotted at registration and persisted. Rename the
folder on disk (or re-clone under a new name) and the sidebar label, window
title, and activity history keep the old name indefinitely — the path is
right, the label is wrong, and the only remedy is remove + re-add, which loses
star/manual-order/last-opened metadata. **Fix:** opportunistically refresh the
display name during `AppState.refreshSummaries` (path's `lastPathComponent`)
via a `RepoStore.refreshName(_:for:)` that preserves identity, order, stars,
and the last-opened key. Test: store-level round-trip (rename while registered;
identity and order unchanged, label updated; a *different* repo whose name
equals the new one does not collide — identity stays path-based).

### glm-B6 · Dropping a *file* on the sidebar produces a misleading error — S

The sidebar drop handler accepts any `fileURL`. Dropping a regular file inside
a repo can't become a Process cwd, so validation fails with “not inside a git
repository” — misleading for the common “I dragged the README of the repo I
want” case. **Fix:** resolve dropped files to their parent folder before
validating (a dropped file almost always means “add the repo containing it”),
and reject obviously-non-representable drops (no folder, no parent) with a
message that says what was dropped. Test: unit-drive the URL→folder resolution
helper (file → parent, folder → itself, root → rejected).

### glm-B9 · `fetch --all` fans out to every configured remote — S/M

`fetch()` runs `git fetch --all --prune --tags` (#72 removes the `--tags`
forcing). On repos with several remotes (collaborator forks, multiple
upstreams) every fetch button press and auto-fetch interval hits all of them —
slow, and `--prune` on a remote whose branches were deleted there produces
surprising ref deletions. **Fix:** default the button to the preferred remote
(`fetch(remote:)`, a one-argument variant), keep “Fetch All Remotes” as the ⌥
variant or a Repository-menu item. Test: integration — two remotes, fetch the
preferred one, assert only its refs moved.

### glm-G3 · The error banner's lifecycle loses failures — S

`errorMessage` is a single optional string: a second failure overwrites the
first unread one, and every new `perform` clears it at start, so a queued op
start can erase an error the user never saw. **Fix:** never auto-clear an
unread error on the *next* op start (mark-seen on dismiss only; the newest
error can coexist with the busy state), and keep V7/#51's expand/copy
affordances. Test: VM-level with the injected-client seam (P9) — two failures
in a row both reachable until dismissed.

---
## Correctness & safety — wave 5 (`opus.md`)

*Consolidated from `opus.md` (wave 5); the `file:line` citations in each entry
below are the record.*

### o-L1 · The GTK history graph goes stale on checkout, push and branch creation — S

`HistoryPane.historySignature()` (`Linux/GitEnoughGTK/HistoryPane.swift:73`) is
`[head, tail, count, columnCount, canLoadMoreHistory].joined(separator: "/")`,
and `rebuild()` skips `rebuildCommitRows()` when it is unchanged. Three things a
row *draws* are absent from it: `commit.decorations` (the ref chips, and
`Commit.isHead`, derived from them at `GitModels.swift:33`),
`viewModel.unpushedHashes` (whether the dot is hollow), and therefore the HEAD
double ring.

So `git checkout other-branch` leaves every loaded hash, the count and the lane
count identical — the list is not rebuilt, and the HEAD ring and branch chips
stay on the branch you *left*, while the header bar and status line update
correctly right beside them. Push and branch creation have the same shape.

**Fix:** fold the decoration set and `unpushedHashes` into the signature (hash
them rather than concatenating). **Test:** signature changes across a checkout
that moves no commits.

### o-L2 · The unstaged list shows each partially-staged file's *staged* status letter — S

`FileChange.displayStatus` (`GitModels.swift:168`) is
`stagedStatus ?? unstagedStatus ?? .modified`, and both lists render through it,
so a file in both shows its **X** column in both. Porcelain v2 emits the two
columns separately for exactly this reason:

- `AM` — stage a new file, keep editing: the Changes row says *Added* though the
  unstaged change is a modification.
- `MD` — stage an edit, then delete: the row says *Modified* while the file is
  gone from disk.
- `AD` — the row says *Added* for a file that no longer exists.

The badge is the row's only status signal (`UI/CommonViews.swift:100`) and is
coloured by the same wrong value, so a **deletion renders green**.

**Fix:** the row already knows its side — `FileRow` is built with
`actionIcon: "minus.circle"` for staged and `"plus.circle"` for unstaged
(`ChangesView.swift:137`, `:168`). Add
`func displayStatus(staged: Bool) -> Status` returning
`staged ? (stagedStatus ?? .modified) : (unstagedStatus ?? .modified)` and have
both front ends call it. GTK already threads `staged: Bool` into `row(_:staged:)`
(`ChangesPane.swift:134`), so only its call site changes. **Test:**
`GitParsersTests` already parses `AM`/`MD`/`AD`; assert both sides of each.

### o-L3 · A failed git read publishes a healthy-looking summary over the sidebar's warning — M · *merge with C1*

`collectSnapshot` launders every read failure into empty data, so a repository
whose git calls are failing publishes a summary that looks clean rather than one
that looks broken. Same area as **C1** (generation-safe summaries) and should be
one change: make the snapshot carry a typed failure and have the sidebar render
it, rather than have absence and emptiness be the same value.

### o-L5 / o-L12 · Three offered merge tools pass a `--tool=` name git rejects — S

`MergeTool.known` offers `gitName` values git does not accept for
`git mergetool --tool=`. **Refinement (o-L12):** the failure is not that the
names are invented — it is that git's accepted set is version- and
platform-dependent, and the list is a hardcoded guess. **Fix:** derive the
offered set from `git mergetool --tool-help`, which prints exactly the names the
user's git will take, and intersect it with the executables actually found on
disk. That makes the list correct by construction on every git version instead of
correct on the one it was written against.

### o-L6 · The Changes diff pane never reloads when a file changes but its status letter does not — M

`RepoViewModel.selectFile` (`RepoViewModel.swift:850`) is the only writer of
`selectedFileDiff`, called from exactly one place: a selection change
(`ChangesView.swift:55`). The only thing that moves the selection on refresh is
`.onChange(of: viewModel.status)`, and `ChangeSelection.updated(for:)` rebuilds
from the new `FileChange`, whose equality is path plus status columns. Edit an
already-modified file again and the `FileChange` is unchanged → selection
unchanged → `onChange` does not fire → no reload. `apply` never touches
`selectedFileDiff` either.

The everyday loop breaks: select `Foo.swift`, read the diff, fix the typo in your
editor, come back. Status is still ` M`, so **the pane still shows the diff from
before the fix** — exactly when you are reading it to decide whether to stage.
Compounds with **o-P1** (the watcher cannot see nested edits at all); fix them
together.

**Fix:** let the view model own the Changes selection. Add a stored
`selectedChange: (FileChange, staged: Bool)?`, set and cleared in `selectFile`,
and call `reloadSelectedFileDiff()` at the end of `apply` — repeating the body
*without* setting `isLoadingDiff` or clearing the text first, so the pane updates
in place instead of flashing a spinner every poll, while still bumping
`fileDiffGeneration` so it beats anything in flight. Cost: one extra `git diff`
per applied snapshot, only while a file is selected. **Test:** select a modified
file, rewrite it on disk, refresh, assert `selectedFileDiff` changed.

### o-L7 · "Mark Resolved" cannot accept a deletion, so modify/delete conflicts dead-end — S

For the everyday modify/delete conflict, all three in-app resolutions fail:

- **Theirs** runs `git checkout --theirs` (`GitClient.swift:715`) → *"path 'f'
  does not have their version"*. There is no their-version to take.
- **Ours** has the mirror problem in the reverse case.
- **Mark Resolved** reads the file before staging, so once the user deletes it by
  hand — the *correct* resolution — it fails with *"The file 'f' couldn't be
  opened because there is no such file."*

The user is stuck in a conflicted merge with no way out but **Abort**, which
throws away every other resolution they have made.

**Fix:** `markResolved` should stage whatever the resolution *was* — if the path
no longer exists on disk, `git rm --cached -- :(literal)<path>`, else `git add`.
The conflict row should also offer **Delete the file** for unmerged entries whose
stage-2 or stage-3 blob is absent; porcelain v2's `u` records already carry the
three stage hashes (a zero OID means "absent on that side") and `GitParsers`
currently discards them (`GitParsers.swift:165-172`).

**Related, already shipped:** PR #100 stops `Stage All` from silently resolving
this shape. That guard makes the dead-end *more* visible, not less — o-L7 is the
way out of it.

### o-L9 · `localNameForRemote` splits at the first slash, so slash-named remotes produce wrong local branches — S

`Branch.localNameForRemote` (`GitModels.swift:64`) takes everything after the
first `/`. For a remote literally named `up/stream`, tracking `up/stream/feature`
offers to create a local branch called `stream/feature`. `Remote.split` already
solves this correctly by longest configured prefix; route this through it.

### o-L10 · Rename destinations are C-unquoted twice — S

A rename whose destination path needs C-quoting is unquoted once by the
name-status parser and again downstream, so a path containing a literal
backslash-escape sequence is corrupted. **Test:** a rename to a path containing
`\t` as two literal characters.

### o-L11 · A history-less snapshot can clobber `canLoadMoreHistory`, silently killing "Load older commits…" — S

An empty history result overwrites the flag rather than leaving it alone, so one
transient failure permanently disables pagination for that repository until
relaunch. **Fix:** only update the flag from a snapshot that actually carried
history.

### o-L13 · `discard` on a corrupt HEAD ref silently unstages instead of reporting the breakage — S

Found while testing PR #97's guard. Verified against git 2.43 with
`refs/heads/<branch>` pointing at garbage:

```
$ git rev-parse --verify --quiet HEAD ;  echo $?     # → 1
$ git reset -q HEAD -- ':(literal)a.txt' ; echo $?   # → 0   ← succeeds
$ git ls-files -- a.txt                              # → (empty)
```

`git reset HEAD` falls back to the empty tree against an unresolvable HEAD, so
`GitClient.discard` returns success having merely *unstaged* the path — the user
asked to revert the file to HEAD's content and instead got their edit left on
disk as untracked, with the operation reported as done.

Nothing is destroyed (the worktree content survives, which is what
`testDiscardOnACorruptHeadRefUnstagesRatherThanDestroying` pins), so this is an
honesty bug rather than a data-loss one. Note the asymmetry that makes it easy to
miss: `git restore --staged` *fails* on the same repository, which is why
`unstage`'s `isUnbornHEAD()` guard is load-bearing and `discard`'s is not.

**Fix:** distinguish "unborn" from "unresolvable" at the call site — `discard`
should refuse and say the repository's HEAD is broken rather than degrade
silently. Same family as **o-L3** and **C1**: absence and failure must not be the
same value.

### o-L14 · Opening an untrusted working copy runs code from it — M · **decided: fix by trust, not by flag**

Raised on PR #98 about `diff.<driver>.textconv`, which is an **arbitrary
executable named by the repository being viewed** — so rendering a diff in a repo
that arrived with a hostile `.git/config` or `.gitattributes` runs it.

**Corrected after measuring** (an earlier version of this entry had the asymmetry
backwards): git also runs that repository's *hooks*, but only when the user
commits, checks out or merges — a deliberate action. **textconv runs on render.**
Against git 2.43, a single `git diff --no-color --no-ext-diff -- <path>` with no
hooks present and no mutating command executed the filter **twice**, once per
side; `--no-ext-diff` does not suppress it, being a different mechanism. So for
the most common untrusted-repo case — clone it, look at it — textconv is the
*first* repo-named executable reached, not a smaller addition to the hooks hole.
Both still arrive together in a downloaded zip or bundle.

So "opening an untrusted working copy is safe" is not a property this app has,
and suppressing textconv alone would not give it one — it would only cost every
legitimate binary-format diff (`pdf` → `pdftotext` and friends), which is the
whole reason `patchReadFlags` deliberately omits `--no-textconv`
(`GitClient.swift:268`).

**Fix, as one deliberate piece of work rather than a flag:** decide the policy
first, then implement it whole.

- Detect the risk at *add* time, not at render time: on registering a repository,
  check for `.git/hooks/*` that are executable and non-sample, and for
  `diff.*.textconv` / `diff.*.command` / `core.fsmonitor` / `core.pager` in the
  repo-local config. Any hit gets a one-time "this repository can run code on
  your machine — it was probably cloned normally, but if you downloaded it, look
  first" prompt, with the offending entries listed.
- A per-repository "trusted" bit persisted alongside the sidebar entry, defaulting
  to trusted for anything cloned *by* GitEnough (which cannot carry a config) and
  untrusted for anything added by folder pick or discovery that trips the check.
- Only then is a `--no-textconv` / `core.hooksPath=/dev/null` mode worth adding,
  gated on that bit, because only then does it mean something.

Compare `git`'s own `safe.directory` and VS Code's Workspace Trust: the useful
part is the *prompt on first contact*, not the flag.

**Widened (2026-09-07, PR #97): the repository can also choose where the app
*writes*, not only what it *runs*.** Everything above is about repo-named
**code** — textconv, hooks, `core.pager`. #97 found the other half. A clone can
ship `.gitignore` as a symlink (mode `120000`, materialised by checkout), so
`.gitignore -> ~/.zshrc` turned one "Ignore" click into an append to the user's
shell config. No code execution required, and nothing in the app's threat model
covered it.

That instance is closed, and the reason is stronger than containment: **git
itself will not read a symlinked `.gitignore`.** It opens working-tree pattern
files without following symlinks, so a single-hop link raises `ELOOP` and the
rule is silently never applied — "Too many levels of symbolic links" is
`strerror(ELOOP)`, not evidence of a cycle. Verified on a one-hop link to a
regular file that `cat` reads through fine while git refuses it, and pinned on
git 2.43 (Ubuntu CI) and 2.55 (macOS CI) by
`GitIgnoreTests.testGitIgnoresASymlinkedGitignoreEntirely`. Older git *did*
follow the link, so for those users the refusal is conservative rather than
matching git. Following it wrote rules where git never looks, so there was no
legitimate configuration to preserve.

**The generalisation is the part that matters here:** any feature that writes
into the worktree *by path* has this exposure, and the guard has to be at the
write. The next one is **M21** ("Ignore Locally" via `.git/info/exclude`) —
`.git/info/exclude` is inside `.git`, so a checkout cannot plant a symlink
there, but the same lstat-before-write discipline should be stated when it
ships. **Stronger end state, not yet done:** `open(url.path, O_RDWR | O_NOFOLLOW)`
on the append path makes the *open* the enforcement point, closing the
check-then-use gap a pre-check leaves. Declined three times during #97 on the
grounds that the remaining race needs a same-user local process that already has
code execution — unlike the shipped-symlink vector, which is static and fully
caught. Worth doing when this entry's trust work lands.

**Decision (2026-09-06, repository owner).** Raised three times during PR #98's
review, which pushed for shipping `--no-textconv` as a deny-by-default interim
mitigation. Declined in favour of doing this properly: textconv stays enabled, so
binary-format diffs keep working, and the exposure closes when the trust prompt
above lands. That makes this entry the *mitigation*, not a nice-to-have — treat
its priority accordingly rather than as a general-hardening item.

### o-G3 · Publish ignores `remote.pushDefault` and `branch.<name>.pushRemote` — S

Raised on PR #96. `PushCapability.resolve` picks the publish destination with
"`origin` if it exists, else whichever remote git lists first". That matches
git's *implicit* default but not its *configured* one: git consults
`branch.<name>.pushRemote`, then `remote.pushDefault`, before falling back.

So a user who has deliberately set `remote.pushDefault = fork` gets their branch
published to `origin` — **and** `branch.<name>.remote` rewritten to point there,
since publish passes `-u`. Same class as the two `resolve` defects PR #96 fixed:
the app deciding a destination the user already specified.

**Fix:** read `branch.<name>.pushRemote` then `remote.pushDefault` (one
`git config --get` each, or fold them into the existing branch `for-each-ref`)
and prefer them over the name heuristic. Thread the value into `resolve` the way
`remotes` already is, keeping the heuristic as the last fallback. **Test:** a
configured `remote.pushDefault` beats `origin`; `branch.<name>.pushRemote` beats
both.

### o-L15 · `GitError.exitCode = -1` is an unnamed sentinel used fourteen ways — S

Raised three times across PR #100's review, and the reviewer is right that a
magic number carrying a meaning is worse than a named one. `-1` appears at
fourteen `GitError` construction sites and means "GitEnough synthesized this, it
is not a git exit code" — covering "git isn't installed"
(`GitShell.swift:250`), "failed to launch git" (`:271`), and eleven client-side
refusals such as "Branch names must not start with —".

**Not currently a bug**: nothing anywhere branches on it. Every consumer tests
`== 0` or `!= 0` (`ActivityLogView.swift:57`, `GitActivityLog.swift:49`,
`GitActivityStore.swift:193`), and `GitActivityLog.Entry.exitCode` is only ever
written from a real process exit, so a synthesized error never reaches the
activity log at all.

**Fix:** one named constant used at *all fourteen* sites —
`GitError.synthesized` or an `exitCode` of `nil` with the type made honest about
"there was no process". What to avoid is a *second* sentinel for one call site,
which is the shape the review suggested: it would leave the convention
half-migrated, so `-1` would then mean "synthesized, except sometimes", which is
worse than one uniform magic number. Reconsider with urgency the day any UI does
branch on it, e.g. to show an install-git screen.

### o-G4 · Carry git's own upstream remote name instead of parsing the shorthand — S/M

`RepoStatus.upstream` holds only the shorthand (`origin/main`), so every consumer
has to split it back into a remote and a branch — and remote names may contain
slashes, which makes that split genuinely ambiguous. With `origin` and
`origin/features` both configured, `origin/features/x` is two well-formed
readings and the string cannot say which.

`Remote.split` guesses by preferring the reading whose branch half equals the
local branch name, then longest prefix. PR #96 made `PushCapability.resolve`
**refuse** when neither reading matches, because the guess resolved to `.push`
and `.push` enables force push — one confirmation could `--force-with-lease` a
ref on a remote the user never chose.

**What remains is the case where a match is wrong.** A local `features/x`
tracking `origin/features`'s branch `x` produces the same shorthand and matches
the *other* reading, so it resolves confidently to `origin` + `features/x`. The
heuristic cannot detect its own failure, and
`PushCapabilityTests.testSplitUsesTheLocalBranchToBreakANestedRemoteTie` pins
that wrong answer — deliberately, but it means CI defends it until this lands.

**Fix:** git already knows. Add `%(upstream:remotename)` (and
`%(push:remotename)` where they differ) to the `for-each-ref` that builds the
branch list, carry it on `RepoStatus` as `upstreamRemote: String?`, and have
`resolve` prefer it whenever present. `Remote.split` stays as the fallback for
snapshots that lack the field, and the two tie-break tests become coverage of
that fallback rather than of the primary path.

**Also closes** the `.ambiguousUpstream` refusal as a user-facing state: with an
authoritative remote name there is nothing left to be ambiguous about, so the
refusal becomes unreachable in normal operation rather than something a user with
nested remote names has to work around.

**A second, sharper repro (raised on #96, 2026-09-07).** The case above has the
same branch name on both sides, which makes the tie-break's failure feel like a
coin flip. This one breaks it through a different door, with the branch names
*differing*:

- remotes `origin` and `origin/dev` both configured
- local `dev` tracking `refs/heads/dev/dev` on `origin` (after
  `git push -u origin dev:refs/heads/dev/dev`), so the shorthand is
  `origin/dev/dev`
- candidates: `origin` → `dev/dev`, and `origin/dev` → `dev`
- the tie-break matches `dev`, so `split` returns `origin/dev` and
  `isAmbiguous` returns **false** — a confident wrong answer

Correct per config is `origin` + `dev/dev`. Pin this one when
`%(upstream:remotename)` lands; it is the case a fallback-only implementation
would still get wrong.

**What shipped in the meantime (#96), so the residual is bounded rather than
open.** `Remote.split` reports `remoteWasGuessed`, force push is withheld
whenever it is true, and the push progress line names the remote it chose so a
guessed destination is at least visible. A plain push to a guessed remote is
still allowed: refusing would turn Push into an error for *every* nested-remote
setup, which is worse than a recoverable push to one of two plausible refs —
`%(upstream:remotename)` removes the guess rather than the button. Also pinned:
`testASlashBearingLocalUpstreamIsIndistinguishableFromAVanishedRemote`, which
records a *limitation* deliberately — a local-tracking branch whose branch name
contains a slash (`branch.<n>.remote = "."`, upstream `feature/foo`) is reported
as a vanished remote. That assertion is expected to **fail** when this entry
lands, and to be flipped then, rather than the limitation quietly disappearing.

**While you are here:** `Remote.isAmbiguous` and `Remote.split` are two entry
points that must encode the same tie-break, and `resolve` calls both. Consider
one `Remote.resolveUpstream(...)` returning `resolved` / `ambiguous` /
`unmatched`, so a caller cannot consult half the contract — the divergence is
most likely precisely while this change is being made. `Remote.preferred` also
splits *without* the local-branch tie-break, so a status-bar label can name a
different remote than a push would target; harmless today, worth aligning.

### o-R1 · `GitShell.gitURL` is written on main and read from every repo queue — S

`reprobe()` writes `gitURL` from the main thread while every repo's serial queue
reads it. Unsynchronized cross-thread access to a `var` — benign in practice
today, undefined by the language. **Fix:** a lock, or make it atomic via a serial
queue of its own.

### o-R2 · `start()` is not idempotent, so the GTK app does everything twice — S

Verified by reading: a second `start()` re-registers handlers and re-runs
initialization rather than returning early. **Fix:** an `hasStarted` guard.

### o-R3 · `AppState` ignores its injected `UserDefaults` for drafts — S

`AppState` takes a `UserDefaults` for testability but reads drafts from
`.standard`, so tests touch the developer's real defaults. Same family as **o-T2**
below, which is the more serious instance.

---

## Review follow-ups from the wave-5 PRs (`#96`, `#97`, `#100`, `#101`)

Raised during those PRs' review rounds, judged real, and deliberately **not**
done there — each was either out of the PR's scope or a ripple large enough to
deserve its own change. Every one carries the measurement or the file:line that
makes it checkable, so none needs re-deriving.

### w5-1 · Append the `.gitignore` rule when a later `!` negation wins — S

`RepoViewModel.ignore` reaches its append branch only when
`client.isIgnored(path:)` said **no**. If `GitIgnore.appendedBytes` then returns
empty, the literal rule is already in the file *and* git still does not ignore
the path — which only a later negation produces. That case now throws an
actionable error; it used to return quietly, reporting success and writing
nothing.

Throwing is not the right end state. gitignore is **last-match-wins**, so
appending the rule again does re-ignore the path (measured, git 2.43):

```
/build          →  git check-ignore build/x.o   exit 1  (not ignored)
!/build
/build          →  git check-ignore build/x.o   exit 0, .gitignore:3:/build
```

**Fix:** let `GitIgnore.appending` skip its duplicate suppression at this one
call site — a parameter, or a separate entry point that always emits the rule —
and append. The duplicate check is right in general and wrong here, because the
caller has already asked git and been told the rule is not taking effect.

### w5-2 · Make the `.gitignore` open the enforcement point — S

`requireRegularIgnoreFile` stats the path; the append branch opens it later with
`FileHandle(forUpdating:)`, which follows symlinks. A link swapped in between is
written through. Replace with `open(url.path, O_RDWR | O_NOFOLLOW)` wrapped in
`FileHandle(fileDescriptor:closeOnDealloc:)`, mapping `ELOOP` and `EISDIR` to
the existing messages. The creation branch is already safe — `.atomic` renames
over the path rather than following it. See **o-L14**; declined three times
during #97 because the race needs a same-user process that already has code
execution, unlike the shipped-symlink vector that guard actually closes.

### w5-3 · Drive the `.gitignore` refusals through the public path — S/M

Every symlink-refusal test calls `RepoViewModel.requireRegularIgnoreFile`
directly. Nothing executes `ignore` end to end against a symlinked `.gitignore`,
so a refactor that stopped calling the guard from one of the two branches would
keep the whole suite green. Same gap for the byte-append contract: no test
asserts the *on-disk* result after `ignore` on a file ending in a bare CR. Needs
a view model, a repo fixture and the async `perform` path.

### w5-4 · Pin `isUnbornHEAD`'s four-state matrix, and check it on old git — S

The safety of `unstage`/`discard` rests on `rev-parse` and `symbolic-ref`
separating unborn from corrupt (measured on git 2.43 only):

| state | rev-parse | symbolic-ref | verdict |
|---|---|---|---|
| healthy | 0 | 0 | not unborn |
| garbage ref contents | 1 | 128 | not unborn |
| well-formed SHA, no object | 0 | 0 | not unborn |
| genuinely unborn | 1 | 0 | **unborn** |

Only prose enforces it. Build each state in a temp repo and assert the matrix,
and run it against the oldest supported git — if an older `symbolic-ref` exits 0
for a corrupt target, a corrupt repo is classified unborn and reaches
`rm --cached -f`, which `-f` makes destructive.

### w5-5 · Skip reftable repositories before mutating them — S

`corruptHeadRef` writes a garbage loose ref and *then* infers the reftable
backend from "HEAD still resolves". On reftable it leaves a stray loose ref file
and both corrupt-ref tests skip — so the regression they pin has no coverage on
the backend git is moving toward. Query `extensions.refstorage` (or
`rev-parse --git-ref-format` on 2.45+) first, keep the post-hoc guard as a
backstop, and ideally add a reftable-native corruption variant.

### w5-6 · Kill the `"Can't push: "` prefix contract — S

`UnavailableReason.forcePushMessage` rewrites `message` by stripping a hardcoded
prefix that every case hand-writes. Reword one case's opening and that reason
silently keeps the push verb in force-push contexts. Move each sentence into a
private `detail` with no verb, and compose `message` and `forcePushMessage` from
it. Declined three times during #96 because
`testEveryUnavailableReasonCarriesThePushPrefix` polices it — that test is now
genuinely exhaustive (its fixtures are built *inside* the exhaustive switch, so
a new case cannot compile without one), but structural beats policed.

### w5-7 · Validate push operands by throwing, not by trapping — S

`pushArguments` guards the empty-name case with `precondition`, which survives
release builds: a parser regression means a crash rather than an error, in a
core feature. It guards a genuinely destructive shape — an empty source side
makes `refs/heads/:refs/heads/x`, which git reads as a **delete** — so it cannot
simply go. Make the builders `throws` (rippling to the confirmation-dialog
builder and every test), or return `PushCommand?`. Declined four times during
#96 on ripple size; the reasoning has not changed, only the count.

### w5-8 · Publish auto-picks `remotes.first` when there is no `origin` — S/M

On the no-upstream path `resolve` falls back to `origin`, else `remotes.first`,
and `pushOrPublish` runs `push -u` — so one click binds `branch.<n>.remote` to
whichever remote git happens to list first. This is **inconsistent with the
deliberate refusal one block above**, where a configured-but-missing upstream
refuses rather than falling back precisely because that heuristic is unsafe. A
product decision: either add a "choose a remote" reason for the multi-remote,
no-`origin` case, or state why publish may guess where push may not.

### w5-9 · Smaller, all checkable — S each

- **`parseVersion`'s unanchored fallback** now takes the last dotted token, so
  `shim 3.5: git 2.20` reads (2, 20). A banner with *no* dotted token after a
  wrapper's own is still unreachable-by-construction rather than proven; add
  cases if a real wrapper shape turns up.
- **Warm `supportsForceIfIncludes` at app launch**, not via `queue.async` in
  `RepoViewModel.init`. The current warm-up is best-effort; a view body that
  wins the race blocks on `swift_once` for one `git --version`. A stored,
  asynchronously-populated property removes the race rather than usually winning
  it.
- **Carry a typed reason on `PushCommand`** instead of the dialog inferring the
  cause from `refusesUnintegratedRemoteWork`. The boolean says the flag is
  absent; the copy asserts *why*, and only the version gate produces that today.
- **Bind a worktree into `PushCommand`** so `push(_:)` cannot run a command
  built for another repository. Theoretical — the dialog pairs one command with
  one client — but the type is meant to make this class impossible.
- **Measure whether `FileHandle.nullDevice` leaks a descriptor per git spawn**
  (`/proc/<pid>/fd` count across a loop of invocations, both platforms) before
  caching it. Caching needs `nonisolated(unsafe)` on a non-`Sendable` type to
  save one `open("/dev/null")` per process spawn, so only do it if measured.
- **The three `GitClient` copy constants** (`stageAllRefusalPrefix`,
  `conflictStagingConsequence`, `namingFiles`) are internal because `UI/`
  compiles into the same module. They go public together if the GTK front end
  ever grows the Stage All tooltip.
- **`discard`'s unborn branch may be dead code.** `git reset -q HEAD -- <path>`
  *succeeds* on an unborn HEAD in git 2.43 (exit 0, index emptied), so the
  fallback is only reachable on older git. Confirm the floor before removing it.
- **#98's two follow-ups:** a positive control on the staged-path guard in
  `testDiffReadsIgnoreAConfiguredExternalDiffDriver`, and a test pinning the
  `diff --combined` header shape.

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

**One item here needs none of the restructuring and can be done today:**
`GitClient.gitDir()` shells out for a value that is fixed for the life of a
`GitClient`, and is re-run on every snapshot. Memoizing it is an independent S
with no coupling to the rest of this entry.

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

### P8 · Make history pagination incremental and memory-bounded — M

**Cheaper than this entry has read since it was written.**
`GitClient.log(limit:skip:)` **already takes `skip:`**, and no caller passes it
(verified by grep). The process plumbing exists; what is missing is only
`loadMoreHistory` using it and the graph layout carrying resume state. See
**P4-opus** for the layout half, which is the real work.

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
## Performance & architecture — wave 5 (`opus.md`)

### o-P1 · The watcher cannot see edits below the worktree root — M · *sharpens P1*

`RepoWatcher.signature` (`RepoWatcher.swift:59`) hashes the mtimes of a fixed
list of `.git` entries **plus the worktree root directory's own mtime**. A
directory's mtime changes only when its *direct* entries change, so editing
`Sources/App/Model.swift` moves neither `.git` nor the repo root. Nothing fires.

P1 frames this as architecture ("tiered FSEvents observation"). The symptom is
worth stating plainly because it is the app's most common "is this thing broken?"
moment: with GitEnough open on a second monitor beside your editor — the layout
the two-pane design invites — the Changes list is stale for as long as you look
at it. On macOS `applicationDidBecomeActive` papers over it whenever you ⌘-tab;
on Linux nothing does (**o-X3**), so it never recovers.

Two further blind spots in the same signature, both verified:

- `refs/remotes` is watched, but a tracking ref lives at
  `refs/remotes/<remote>/<branch>` — an external `git push` bumps
  `refs/remotes/origin/`'s mtime, not `refs/remotes/`'s. The toolbar keeps
  offering "Push 3" forever.
- `gitDir` is the *per-worktree* git dir, so in a linked worktree every ref lives
  in the common dir and **none of it is watched at all**.

**Cheap fix, no new API:** keep the mtime fast path and add what it provably
misses — the resolved `refs/heads/<head>` and `refs/remotes/<upstream>` files
(the view model already has `status.head` and `status.upstream`; hand them to the
watcher from `apply`), plus `git rev-parse --git-common-dir`. For worktree edits,
fold in a content signal *only* while the Changes tab is frontmost and the tree is
already dirty (`git status --porcelain=v2 -z`, hashed) — one extra process per
2.5 s for the visible repo only. The full FSEvents/inotify design stays the right
destination; this makes the app honest in the meantime.

### o-P2 · Every history row rescans the whole commit array to find HEAD — S

`HistoryView.headRow` is a computed property — `commits.firstIndex { $0.isHead }`
— and every materialized row evaluates it as `isHeadRow: row == headRow`. 300
comparisons per row at the default page size, unbounded after "Load older
commits…" (the page grows by 300 with no cap). **Fix:** compute it once per
render pass.

### o-P3 · `onChange(of:)` rebuilds the whole hash array on every body pass — S

The comparand is rebuilt rather than stored. **Fix:** hold the derived value.

### o-P4 · "Load older commits…" re-reads and re-lays-out the entire history — M · *with P8*

`GitClient.log(limit:skip:)` **already takes `skip:`** and nothing passes it. The
missing pieces are `loadMoreHistory` using it and `GraphLayout` carrying resume
state so the second page lays out against the first rather than from scratch. See
**P8**, which this makes concrete.

### o-P5 · Superseded commit and diff loads still run — S · *with P6*

Arrow-keying down the history list queues one git process per row. The results
are already generation-guarded so nothing stale is *applied* — but every
superseded read still executes. **Fix:** cancel or coalesce at issue time, not at
apply time.

### o-P6 · Each snapshot re-answers "where is the .git directory?" — S · *independent slice of P4*

`GitClient.gitDir()` shells out for a value fixed for the life of the client.
Memoize it. No coupling to the rest of P4.

### o-P8 · The activity log bounds stderr but not argv — S

`stderrTail` caps stderr at 4,000 characters (`GitActivityLog.swift:148`), while
`normalizedArguments` (`:192`) applies `redactCredentials` — a regex
`replacingOccurrences` — to **every** argument with no bound at all.

Stage a branch switch that touched 20,000 files and one click produces 20,000
regex evaluations, a multi-megabyte single-line `command` string retained in
`items`, a multi-megabyte JSONL line on disk, and a `Text` that Core Text must
lay out in full before `.truncationMode(.middle)` can hide it.

**Fix:** bound argv the way stderr is bounded — keep the first ~64 arguments and
append `"…and N more"`. The activity log is diagnostics; it does not need the
20,000th pathspec.

### o-P9 · Discovery does O(found × registered) symlink resolutions on the main thread, every minute — S

`RepoStore.addDiscovered` (`RepoStore.swift:209`) calls
`Repository.normalizedPath` inside two nested `contains` closures, and that is
`standardizingPath` + `resolvingSymlinksInPath()` — several `lstat`s each. A
watch folder with 40 repos, 40 registered and 10 previously removed is 40 × 50 =
2,000 resolution pairs on the main thread every 60 seconds *and* on every
activation, in the overwhelmingly common case where the answer is "nothing new".
**Fix:** normalize each side once into a `Set` before the loop.

### o-P10 · Discovery stats the watch folder on the main thread, and never coalesces — S

Two independent problems in `AppState.scanDiscoveryFolder` (`AppState.swift:304`):

- The `FileManager.default.fileExists(atPath: root.path)` guard runs **before**
  the hop to the utility queue. On an unresponsive SMB/NFS/sshfs mount — exactly
  what people point a watch folder at — `stat(2)` blocks for the mount timeout,
  tens of seconds on a hard NFS mount, on every 60-second tick and every
  activation. The app is unusable rather than slow, and nothing explains why.
- There is no in-flight guard. All five callers (timer, activation,
  `ContentView.onAppear`, two Settings buttons) can fire in quick succession and
  each gets its own concurrent block. A scan slower than the tick — 4,000
  directories over SMB is minutes — accumulates one new full walk per minute,
  forever.

**Fix:** move the `fileExists` check inside the background block, and serialize on
a dedicated queue behind an `isScanning` flag checked on main.

### o-P11 · Discovery re-reads every repository's `.git/config` on every scan — S

`RepoDiscovery` (`RepoDiscovery.swift:89`) asks for `.isDirectoryKey` and throws
the prefetched value away, re-statting each child through
`fileExists(atPath:isDirectory:)` (`:33`), then reads and parses each candidate's
`.git/config` to decide bare/submodule. A 40-repo watch folder is ~120 stats and
40 whole-file reads and parses every minute, forever, to re-derive answers that
have not changed since launch. **Fix:** read `.isDirectoryKey` off the returned
URLs (cached on them — a lookup, not a syscall) and memoize the bare/submodule
verdict keyed by path and `.git` mtime.

### o-P12 · The diff is fully split and grapheme-counted before the line cap applies — M · *with P5*

`DiffParser.parse` does `components(separatedBy: "\n")` — materializing every
line of the whole string — and `reserveCapacity(min(diff.count / 40, …))`, where
`diff.count` walks the entire string counting graphemes. Both happen *before* the
`maxLines` cap can help. **Fix:** iterate lazily and stop at the cap.

### o-P13 · The graph stores every segment twice — S

Each segment is recorded from both endpoints. Halving it is mechanical and cuts
the layout's allocation in half on wide graphs.

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

### k3-M2 · `git maintenance` affordance for large repos — S

For the "opened a monorepo" case: one Repository-menu item running
`git maintenance run` (commit-graph, incremental gc — safe, online, and it
speeds up every later `log --topo-order` the History tab runs). Cheap,
genuinely useful, and on-brand for a client that stays close to the CLI.
Test: integration — run on a temp repo, assert exit 0 + commit-graph presence.

### glm-M3 · Changes totals bar — S

A one-line summary of the staged (or all) changes — "+123 −45 across 4 files” —
from `git diff --numstat` / `--cached --numstat` (cheap: no patch bodies).
Gives the Changes tab the “PR summary” feel and answers “how big is this commit
about to be” at a glance. Reuses F47's numstat plumbing; renders above the file
list, green/red colored counts, unique-path count (rename = one file). Test:
pure aggregation over numstat fixtures (renames, binaries `- -`, zero-line).

### glm-U3 · “Discard All Changes…” — S/M

Rows act one at a time and “Stage All” exists, but the symmetric destructive
bulk action is absent — the thing people expect from the Changes section
header. Same confirmation pattern as reset --hard (name the count, keep the
Trash semantics for untracked files, honoring #75's failure reporting). Pairs
with F16 multi-select (which subsumes it if that lands first). Test:
integration — mixed staged/unstaged/untracked batch, assert worktree clean and
untracked files in the Trash.

### glm-U5 · “Open in Terminal” honors installed terminals — S

`Open in Terminal` hardcodes `open -a Terminal`. macOS has no clean
default-terminal API, so probe `/Applications` for iTerm2, WezTerm, Warp,
Kitty, Alacritty (in a user-configurable priority order, persisted) before
falling back to Terminal. Test: pure priority resolution with injected
installed-app sets; `open -a` argument shape per terminal (some need `--path`).

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

### k3-V3 · Diff soft-wrap toggle — S

Minified/generated one-line files (package-lock.json, .pbxproj) force an
endless horizontal scroll: the two-axis `ScrollView` offers no alternative.
Add a persisted wrap toggle that drops the horizontal scroll axis and lets
lines wrap (per repo or global — decide and document). Must compose with F17's
width measurement (wrap mode skips the longest-line pass entirely), V1's
gutter (line numbers follow the wrapped row), and V2's text sizing. Test very
long single lines, Unicode, toggling mid-scroll, and horizontal-scroll
persistence when wrapping is off.

### V4 · Decoration overflow "+N" is a dead end — S

`+N` for commits with >3 refs is plain text. Make it a popover listing every
decoration (clickable → checkout for branches, copy for tags). Small win, big
repos with many tags (linux-style) currently lose information. Natural
extension (k3-Q1): give the chips themselves a context menu / ⌘-click — local
branch → Check Out / Rename, tag → Copy Name / Delete, remote → Open on Forge
(reuses `ForgeRepo`). Chips are inert text today; turning metadata into
navigation is the cheapest big "feel" win available.

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

**There is one structural cause under most of this, worth fixing first.**
History is a `LazyVStack`, not a `List` — so it has no list semantics for
VoiceOver and no keyboard selection at all, and no amount of per-row labelling
fixes that. Doing **U1** first is most of V12, U1, U4, F16 and F30 at once, and
doing V12 before U1 means labelling rows that are about to be rebuilt.

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

### glm-V5 · Publish/Push toolbar swap causes a layout jump — S

The toolbar button swaps label (`Publish` ↔ `Push`) after a snapshot apply;
labels differ in width, so the toolbar visibly pops on the first push of a new
branch. Prefer a stable single control whose *menu* grows a “Publish branch to
<remote>” first item when there is no upstream, or keep both buttons and
disable the inapplicable one. Must stay consistent with the shared
`pushOrPublish()` entry point (#57) and #43's force-push menu.

### glm-V7 · Lane squeeze has no minimum width — M  ·  *upgraded: it is a correctness bug, not only aesthetics*

`GraphMetrics.laneWidth(for:)` divides by column count with no floor; at 40+
lanes, lanes collide into an unreadable smear under `maxGraphWidth`.

**This entry read "S, low priority" and both halves were wrong.** Only the dot
scales with lane compression — stroke widths and the hollow-dot inset do not —
so past roughly 66 concurrent lanes `nodeRadius` drops *below* the hollow-dot
inset. On macOS the unpushed-commit dot is then **not drawn at all**, and on
Linux Cairo is asked for a negative radius. An invisible unpushed marker is a
correctness failure in the one signal the graph exists to carry. See **o-H3**,
which is this entry with the mechanism worked out.

### glm-A3 · Diff pane lacks a sticky header — S

No file name, no +x/−y, no hunk count at the top of the diff pane; the user
must infer the file from the list selection, which scrolls away on long diffs.
One sticky header line above the scroll area — path (with the glm rename
“old → new” form where applicable), status badge, colored insertion/deletion
counts from the parsed lines — reuses zero new plumbing beyond a count pass.
Test: pure counts over parsed DiffLine fixtures (additions/deletions/hunks;
truncated diffs show “…” totals).

---

## The history graph — wave 5 (`opus.md`)

*The graph is the product's differentiator; these are ordered by how badly each
one misleads.*

### o-H1 · A leftward fold runs along the next row's centre line, threading through unrelated commits — S

Rightward joins get an S-curve. The leftward fold — by far the more common, since
lanes always fold back toward the trunk — puts **both** control points on the
*destination row's centre line* (`GraphRowDrawing.swift:143-149`):

```swift
case .joinExisting:
    shape = .curve(from: start, to: end,
                   control1: .init(x: start.x, y: end.y),
                   control2: .init(x: start.x + (end.x - start.x) * 0.55, y: end.y))
```

With `P1.y == P2.y == P3.y` the vertical component collapses to
`y(t) = y₀ + Δy(1 − (1−t)³)`. At `t = 0.5` the curve is already **87.5 %** of the
way down — 3.4 pt above the centre line at the 27 pt row height — while `x` has
covered only 33 % of the span. The curve dives to the destination row's centre
line and then travels horizontally *along* it.

So in any repo with three or more live lanes, a fold from column *f* to *t < f*
passes through the middle of the row-(r+1) node whenever that node's column lies
between them — lanes 0–5, a fold 5→1, next commit in lane 3 is an everyday shape.
The dot paints after the strokes so it stays on top, but the edge emerges from
both sides of it *at its equator*, which reads unmistakably as "this commit is on
that merge path". For a graph whose entire job is showing which commit is on
which path, that is the worst available failure.

**Fix:** route the horizontal travel through the gap *between* rows, where no dot
lives, using the same curve family as the rightward join — so one segment kind
stops having two shapes:

```swift
let boundary = end.y - rowHeight / 2
shape = .curve(from: start, to: end,
               control1: .init(x: start.x, y: boundary),
               control2: .init(x: end.x,   y: boundary))
```

**Test:** `GraphRowDrawingTests` already inspects geometry — sample a 5→1 fold at
`t ∈ {0.25, 0.5, 0.75}` and assert no sample lies within `nodeRadius` of any node
centre on the destination row.

### o-H2 · Every macOS strip repaints its neighbour's half unclipped — S

Each strip paints two rows' worth of segments, so overlapping strips double-draw
the shared band. Visible as a darker seam on translucent strokes. **Fix:** clip
each strip to its own bounds.

### o-H3 · Only the dot scales with lane compression — M · *this is glm-V7's mechanism*

Stroke widths and the hollow-dot inset do not scale with `laneWidth`, so crowded
graphs smear, and past ~66 lanes `nodeRadius` drops below the inset: the unpushed
dot is **not drawn at all** on macOS, and Cairo is asked for a negative radius on
Linux. **Fix:** scale the inset and stroke width with lane width, and floor
`nodeRadius` above the inset.

### o-H4 · One new commit at the top recolours the whole graph — M · **worth doing for its own sake**

A lane's colour is a monotonic counter incremented in the order lanes open while
walking newest-first (`GraphLayout.swift:114-118`, and `:146` for a merge's extra
parents). Nothing ties the colour to the commits, so inserting one row at the top
that opens a lane shifts `nextColor` for **every** lane opened below it.

A `git fetch` that brings in a remote branch whose tip is the newest commit by
date puts that tip at row 0; it takes hue 0, and every other lane shifts one hue.
The trunk you have been reading as blue for ten minutes is suddenly green, with no
user action and no change to the history you were looking at.

This is also the one place the product can be *better* than IntelliJ rather than
merely equal to it — IntelliJ has the same instability.

**Fix:** seed the colour from the commit that opens the lane, and probe only on
collision with a *live* lane:

```swift
func stableColor(for hash: String) -> Int {   // FNV-1a: deterministic across runs
    var h: UInt64 = 0xcbf29ce484222325
    for byte in hash.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
    return Int(h % UInt64(GraphPalette.hues.count))
}
```

Then a branch keeps its colour across refreshes, across "Load older commits…",
and across sessions — the colour becomes an identity the user can learn rather
than a decoration that shuffles. **Test:** lay out a window, prepend a new branch
tip, assert every pre-existing lane's `colorIndex` is unchanged. **That test
fails today.** Unlocks **o-D3**.

### o-H5 · A merge with a duplicate parent leaks an immortal phantom lane — S

The algorithm rests on "at most one lane expects any given hash". `git commit-tree
-p X -p X` breaks it, and the duplicate lane is never closed — it runs to the
bottom of every subsequent render. Rare but reachable, and cheap to guard:
de-duplicate a commit's parent list at layout entry. **Test:** `GraphLayoutTests`
with a duplicate-parent merge; assert `columnCount` returns to 1 below it.

### o-H6 · Typing in the filter yanks the commit list sideways — S

Filtering changes `columnCount`, which changes the graph strip's width, which
shifts every row's text. **Fix:** keep the strip's width stable while a filter is
active (or reserve the unfiltered width).

### o-H7 · Dead lane code, and a public helper that contradicts the real colouring — S

A `public` colour helper returns something the renderer does not use, so any
caller trusting it draws different colours than the graph. **Fix:** delete the
dead path and the misleading helper.

---

## Visual & interaction — wave 5 (`opus.md`)

### o-U1 · History's list is not a `List`, and that one fact causes five backlog entries — M · **highest-leverage UI change**

History is a `LazyVStack` with tap gestures. It therefore has no list semantics
for VoiceOver, no keyboard selection, no multi-select, and no system row
chrome. **Fixing this is most of V12, U1, U4, F16 and F30 at once**, and doing
any of those first means building on something about to be replaced.

### o-V1 · The commit box is 76 pt tall and proportional, which fights the feature next to it — S

The box the ✨ button writes into is barely two lines tall and rendered in a
proportional face, so a generated subject+body must be scrolled to read and
`72`-column conventions are invisible. **Fix:** monospaced, taller, with a subject
rule at 50 and a body guide at 72.

### o-V2 · The tag chip is the least legible thing in the history list — S

### o-V3 · Two colour vocabularies describe the same things — S

Status letters and graph lanes use unrelated palettes for overlapping meanings.
Pick one. Prerequisite for **A0**.

### o-V4 · There is no spacing or radius scale — S

Padding and corner radii are literals chosen per view. **Fix:** one small scale
in a single file, applied. Also prerequisite for **A0**.

### o-V6 · Filtering the history throws the graph away — S

The graph strip empties while a filter is active, so the one view that shows
*where* a commit sits is absent exactly when you are looking for a commit.
**Fix:** keep the unfiltered layout and dim non-matching rows, rather than
re-laying out the filtered subset.

### o-U3 · There is no Find anywhere — S

No ⌘F in history, changes, or the diff. **Fix:** start with the diff pane, which
is where long content actually lives.

### o-U4 · The menu bar contains no working-tree commands — S

Stage, unstage, discard, stash and commit exist only as on-screen controls, so
none is keyboard-reachable or discoverable, and none can carry a shortcut.

### o-U5 · Conflicted files cannot be inspected — M

There is no way to see the conflict itself without an external merge tool — no
diff, no three-way view, not even the file's text. **Fix:** show the conflicted
file's worktree content in the diff pane, marker-aware. Pairs with **o-L7** and
**o-X4**.

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

## SwiftUI front end — wave 5 (`opus.md`)

*Numbered `o-UI*` to avoid colliding with the platform-seam `o-PS*` entries.*

### o-UI1 · Amend silently rewrites the previous commit message — S

Ticking Amend with text already in the box replaces the previous commit's message
with no indication that the old one is being discarded. **Fix:** load the
previous message into the box when Amend is ticked (and restore the draft when
it's unticked) — the standard behaviour, and it makes the rewrite visible.

### o-UI2 · Every changed-file row hits the filesystem twice per render — S

A per-row `FileManager` call inside a `body`. At 2,000 changed files that is
4,000 syscalls per render pass. **Fix:** compute once per snapshot.

### o-UI3 · The Changes and Branches lists go dead during any network operation — S

`isBusy` disables the whole pane, so a slow fetch makes reading the diff, scrolling
the branch list, and selecting a file impossible for its duration. **Fix:** gate
only the *mutating* controls, which is what the guardrail series (#57/#71/#80/#83)
was actually for.

### o-UI4 · Switching tabs throws away the History tab's state — S

Scroll position, selected commit and loaded page count all reset on a tab switch,
so "check something in Changes and come back" costs a re-read and a re-scroll.

### o-UI5 · "Remove from GitEnough" is one unconfirmed click that deletes the draft — S

The row action is destructive of unsaved work (the per-repo commit draft, #54) and
has no confirmation and no undo. **Fix:** confirm, or make it undoable — this is a
natural first customer for **Q1**.

### o-UI6 · "Load older commits…" gives no feedback and can be clicked repeatedly — S

No spinner, no disabled state, so an impatient second click queues a second full
history read. **Fix:** disable while loading (and see **o-P4**, which makes the
read cheap enough that it matters less).

### o-UI7 · The commit-detail header has no scroll container — S

A long subject or a many-parent merge overflows and is simply unreachable.

### o-UI8 · Switching commits leaves a stale file selected — S

The file selection is not cleared when the selected commit changes, so the detail
pane shows a file from the previous commit.

### o-UI9 · `abbreviatingHome` matches a bare string prefix — S

Home `/Users/bob` turns `/Users/bobby/repo` into `~by/repo`. **Fix:** compare path
*components*, not string prefixes. **Test:** the `bob`/`bobby` pair — it is one
assertion and it fails today.

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

### glm-A1 · Sidebar row hierarchy is flat — S (design)

Repo name / path / branch+counts are three equal-weight lines; the branch line
carries two font sizes and three icons. Suggested order: name + star + dirty
dot (line 1), branch chip + ahead/behind (line 2), path only when hovered or in
an optional compact mode. Sketch first; the current layout is fine — this is
polish, and it must not regress the star's hover-reveal behavior or the
logical-filter affordances.

---

## Novel / delightful

### Q1 · The Safety Net — undo built on the app's own command log — L — the killer feature

*This entry was "reflog-powered Undo". It is re-pointed: the reflog is the wrong
substrate, and the right one already exists in the app.*

A raw reflog is a poor undo stack. It is **HEAD-only**, so it cannot see Discard
or any staging change; it is full of entries the user did not cause (hooks,
external git, other tools); and its names are git's rather than the app's.
Assuming `HEAD@{1}` is the last thing *you* did is unsafe for exactly that
reason.

GitEnough has better material. Every mutating operation already funnels through
`RepoViewModel.perform(_ activity:…)` carrying a human display name —
"Committing…", "Resetting…", "Discarding changes…" — and `GitActivityLog`
already records the exact argv, start and end times, and exit code.

**Approach.** At the top of `perform`, capture a **pre-image** and store it
beside the activity entry:

- `HEAD`'s hash (`rev-parse HEAD`),
- the index tree (`git write-tree` — cheap, and it makes staging undoable),
- for Discard, the Trash paths `TrashMover` already returns.

The Edit menu then gets a real `⌘Z Undo "Reset to 4f81c3a"`, naming the
operation the way the user saw it, implemented as the specific inverse:
`reset --hard <pre-image>` for a reset, `read-tree` for a staging change,
restore-from-Trash for a discard, `branch <name> <hash>` for a branch delete.

**Force Push is the one that cannot be undone locally.** The honest thing is to
say so in its confirmation rather than offer an Undo that would lie.

**Why this is more than "expose the reflog":** it is scoped to what *this app*
did, named in the app's own words, and covers operations the reflog cannot see.
It also turns the five destructive confirmations from "are you sure?" into "you
can take this back", which is a different product.

Phase 1: commit / reset / checkout / stage / discard, previewed before it runs,
refusing pushed or externally-diverged state. Journal the undo itself. Test
external intervening refs, detached and unborn HEAD, dirty trees, app restart,
partial failures, and redo refusal. Phase 2: a read-only Safety Timeline
combining that journal with the reflog.

### Q2 · Command palette (⌘⇧P) — M

Fuzzy-searchable actions + repos + branches + commits ("checkout feature",
"fetch", "discard all", "open in terminal"). A tiny scoring function is pure and
testable; subsumes U5-style quick switchers. Natural extension surface for
everything in this backlog.

### Q3 · "Trace branch" graph interaction — M

Click/hover a lane: its whole ancestry lights up, everything else fades
(IntelliJ-style). Pure reachability computation over the loaded commit graph
(parents map) — fully unit-testable; rendering picks per-node emphasis alpha.
Cheap first cut (glm-Q3): an alpha bump on just the hovered row's passing
lanes — zero graph algorithms, still reads as alive; keep it if the full
version stalls.

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
chores ("Bump …", "Fix typo …"). Ghost-text variant (glm-Q5): a one-line
suggestion under the box — the most recent subject sharing the draft's first
word — with zero autocomplete plumbing; Tab accepts, typing dismisses.

### F37 · AI: PR description from the branch — S/M

`git log <resolved-base>..HEAD` + diffstat → the existing
`CommitMessageGenerator`
plumbing with a PR-description system prompt → paste-ready title+body sheet
next to "Open Pull Request" (which already knows the base branch). Reuses
everything; pure win for the app's AI identity.

### k3-Q3 · AI-suggested branch names — S

The New Branch sheet gets a ✨ button: staged diff (or the current branch's
unpushed subjects) → configured LLM → a suggested name, editable before
creating. Reuses `CommitMessageGenerator` plumbing with a different prompt;
validate the suggestion through the same `check-ref-format` path as C4 before
enabling Create. Very on-brand.

### k3-Q4 · Merge commits say what's merging — S

The history row of a merge shows only the subject ("Merge branch 'x'").
Parsing the second parent into a subtle "← feature" suffix on the row (the
data is in `parents` + decorations) makes the graph legend-free. Pure mapping
from the loaded commit set (second-parent hash → its decorating branch, when
loaded); unit-testable without git.

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

### F42 · `.gitmessage` template support — S  ·  **fold into A10**

*Both are "tell the model what this repository expects". Doing them separately
means two passes over the same prompt builder; A10 is the larger of the two and
should absorb this.*

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

### glm-Q2 · Branch tips as cards — S (design)

With #90's recency in hand, the Branches tab's most-alive local branches
render beautifully as a small card grid above the plain list (name, relative
recency, dirty-tip dot, ahead/behind) — a dashboard instead of a
`git branch -a` dump. Design first; cap at the ~8 most recent tips, keep the
full list below, and preserve every existing row action in the cards' context
menus.

### glm-Q4 · "What would push send?" popover — S

When ahead > 0, make the status bar's ↑N (or A4's sync pill) a popover listing
exactly those commit subjects — the same single `rev-list @{upstream}..HEAD`
#42 already runs for its hollow dots; reuse its hash set against loaded
subjects and offer “Load more” when the set extends past the loaded window.
Turns a number into the answer people open a terminal for.

### glm-Q6 · Repo health tooltip in the sidebar — S

Hovering a sidebar repo shows a two-line tooltip: last fetch time (needs the
per-repo persisted timestamp Q16-style) plus the tip's recency (from the
summary sweep — extend `RepoSummary` with the tip date). Cheap "is this thing
alive?" signal without opening it; no new window, no new git calls beyond what
the sweep already does.

---
## Novel / delightful — wave 5 (`opus.md`)

### o-D2 · Merge and pull preflight: "this will conflict in 3 files", before you start — M · **cheap, and nobody does it well**

`git merge-tree --write-tree <base> <head>` (git 2.38+, 2022) performs a full
merge **in memory** and reports the conflicts without touching the index or the
worktree. One process, no repository mutation.

So the merge confirmation, which today reads *"Merge 'feature' into the current
branch?"*, can read *"Merge 'feature' into main? 14 files will merge cleanly.
2 files conflict: `Package.swift`, `README.md`."* The Pull button's tooltip can
carry the same answer before you press it, and the Branches list can mark which
branches would merge cleanly.

This converts the most-feared operation in the app from a leap into a decision,
and it needs one git command plus a parser that fits in a file.

**The exact contract, verified against git 2.43:**

```
$ git merge-tree --write-tree --name-only <main> feature
08b8be565765ece21ad2ad8efd66bf96a5923c3d      ← the merged tree
f.txt                                          ← conflicted paths, one per line

Auto-merging f.txt
CONFLICT (content): Merge conflict in f.txt   ← informational, on stderr
$ echo $?
1
```

Exit **0** = merges cleanly; exit **1** = conflicts, and the block between the
tree OID and the blank line is exactly the conflicted path list. Nothing is
written to the index or the worktree — the tree becomes unreferenced garbage if
unused. `--name-only` is what makes it parseable; without it the same block is
three-stage index entries. Parser: first line is the tree, then lines until blank
are paths, exit code is the verdict.

Guard on `git --version` and skip silently on older git — `GitClient.version()`
already exists.

### o-D3 · Lane colour as branch identity — S, **once o-H4 lands**

Once a lane's colour is stable across refreshes, it can be *used*: tint the branch
chip, the Branches row and the status bar with the same hue, so "the green branch"
becomes a thing the user can say. Free after o-H4; meaningless before it.

### o-D4 · Show the command before you run it — S

Every destructive confirmation ends with the literal git command it will run,
built from the same argument array the client executes so the two cannot drift.
PR #96 does this for Force Push; the pattern generalizes to merge, reset, discard,
branch delete and abort.

### o-D5 · Export a session as a shell script — S

`GitActivityStore` already holds paste-safe commands. "Export these 12 operations
as a script" turns the activity log into something you can hand to a colleague or
replay on another machine.

### o-D6 · "New since you last looked" — S

The app knows when you last had a repo selected (`repoLastOpened.v1`, #54). A
"3 new commits since Tuesday" marker in history costs one `rev-list` and answers
the question people actually open the app for.

### o-D7 · Does the message match the diff? — M

After generation, a second cheap pass asking "does this message describe this
diff?" catches the stale-message case — the one where you amend a commit and
forget the message still describes the previous change.

### o-D8 · Derive the command palette instead of maintaining one — M · *with Q2*

Q2's palette needs a command registry. Rather than hand-maintaining one, derive it
from the menu commands and `RepoViewModel`'s mutating methods, so a new operation
appears in the palette without a second edit — and the palette cannot drift out of
sync with what the app can actually do.

---

## Linux / GTK front end — wave 5 (`opus.md`)

*The GTK front end is compiled by CI and never executed (**o-T1**), so nothing
below was caught by a test. Several are "documented as working, isn't".*

### o-X1 · Watch-folder discovery and auto-fetch never run on Linux — S

`AppState.init` schedules the app's only recurring timer on Foundation's run loop
(`AppState.swift:99-104`) via `RunLoop.main.add(timer, forMode: .common)`.
`grep -rn RunLoop --include=*.swift .` returns exactly that one line, and nothing
anywhere calls `RunLoop.main.run()`. On Linux the process loop is GLib's
(`main.swift:3` → `App.swift:65` → `g_application_run`), and the one bridge that
exists, `DispatchMainQueueBridge`, drains **libdispatch's** main queue — it does
nothing for Foundation's `RunLoop`. **The timer is never serviced.**

- Settings → Repository discovery is inert. The GTK front end also has no "Scan
  Now" button and no activation hook (`grep -rn scanDiscoveryFolder Linux/` is
  empty), so discovery is 100 % non-functional on Linux.
- "Automatically fetch the active repository" (5/15/30/60 min) never fires.

Both are documented as working, in `README.md` and in the Settings copy.

**Fix:** a libdispatch timer, which both front ends already service —
`DispatchSource.makeTimerSource(queue: .main)`, scheduled `repeating: 60`.
`autoFetchIfDue`'s `dispatchPrecondition(.onQueue(.main))` still holds and macOS
behaviour is unchanged. **Test:** inject the interval, drive the timer, assert
the callback fires under `swift test` — which today fails on Linux and passes on
macOS, which is the point.

### o-X2 · The Linux sidebar never gets summaries, so every unvisited repo shows a filesystem path — S

`SidebarPane.subtitle` (`SidebarPane.swift:98`) falls back to `repo.path` when
`store.summaries` has no entry. `summaries` is filled from exactly two places:
`AppState.refreshSummaries()` and a view model's `onStatusChange` (which only
exists once `viewModel(for:)` has been called). **`grep -rn refreshSummaries
Linux/` returns nothing.**

So a Linux sidebar with ten repositories shows nine rows reading
`/home/user/code/whatever` and one — the one you clicked — reading
`main · uncommitted changes · ↑1`. The dirty marker, ahead/behind and the "Not a
repository" warning are invisible until a repo is selected, and stale
immediately after.

### o-X3 · Linux has no activation refresh at all — S

macOS refreshes everything in `applicationDidBecomeActive`
(`AppDelegate.swift:34-43`), and that hook is what quietly covers the watcher's
blind spots (**o-P1**): nested edits, external pushes, refs moved by a terminal.
GTK has no equivalent, so on Linux those blind spots are **permanent for the life
of the window**.

**o-X2 and o-X3 are one change** — a `notify::is-active` handler on the window
that calls `refreshSummaries()`, `scanDiscoveryFolder()`, and refreshes the
selected repo's view model.

### o-X4 · During a conflict, the Linux Changes pane is simply empty — M

`GitParsers.parseStatus` puts unmerged entries **only** into `status.conflicted`
(`GitParsers.swift:165-172`), never into `staged`/`unstaged`. GTK's `ChangesPane`
renders only `status.unstaged` and `status.staged` (`ChangesPane.swift:104-117`).
So mid-conflict the pane shows nothing at all, with no explanation. The macOS
front end has a whole conflict section (Ours / Theirs / Mark Resolved / Merge
Tool); GTK has none of it. **Fix:** port the conflict section. Note **o-L7**
before doing so — the modify/delete dead-end is in the shared model layer, so
porting the buttons as-is ports the dead-end too.

### o-X5 · The Linux ✨ Generate button is a permanently silent no-op — M

The button exists and does nothing. Either wire it to `CommitMessageGenerator` or
remove it; a control that never responds is worse than an absent one.

### o-X6 · Every history refresh rebuilds every row's widget tree — M

Not the signature problem of **o-L1** — this is the opposite case: when the
signature *does* change, every row is destroyed and rebuilt rather than updated.
**Fix:** a `GtkListBox` row recycle, or update in place.

### o-X7 · The GTK diff view resets its scroll position on every keystroke — S · *with P7*

### o-X8 · Staging a file drops the selection and leaves the wrong diff on screen — S

### o-X9 · The graph strip hardcodes "the list background" — S

macOS resolves it correctly (`Color(nsColor: .textBackgroundColor)`); only GTK
hardcodes, so a dark theme shows a light strip behind the lanes.

### o-X10 · The HEAD double ring is wider than its strip, so Linux clips it flat — S

### o-X11 · The row-height fix is a floor, not a cap, so a larger desktop font reopens the dashed-lanes bug — M

### o-X12 · The Linux build needs GTK ≥ 4.12 and nothing says so — S

`README.md` and `Package.swift` state no minimum. Below 4.12 the build fails with
a pkg-config error that names no version. **Fix:** state it, and check it in the
CGtk module's pkg-config requirement.

### o-X13 · The diff view colours nothing for any CRLF file — S

`DiffView.show` splits on the `"\n"` **Character**. In a CRLF diff, `"\r\n"` is a
single grapheme cluster, so the split never matches and the whole diff arrives as
one line — rendered monochrome, with no `+`/`−` colouring at all, for every
Windows-authored file. **Fix:** split on the unicode scalar, or on
`.newlines`. **Test:** a CRLF fixture through the GTK renderer.

### o-X14 · Removing a repository leaves its view model and watcher running forever — S

The view-model cache is never pruned on removal, so the watcher keeps polling a
repo the user removed — including one on a now-unmounted volume.

### o-X15 · The GTK commit button ignores the message, the amend flag, and `isBusy` — S

### o-X16 · The amend checkbox never reads back from the model — S

### o-X17 · GTK can amend an already-pushed commit with no confirmation — S

macOS warns (#15); GTK does not, so the Linux build will happily rewrite a commit
that is already on the remote and leave the user to discover it at push time.

### o-X18 · Picking a non-repository folder does nothing at all — S

No error, no message, no row. The macOS front end reports it.

### o-X19 · Per-repository global CSS and settings handlers, never removed — S

Leaks one `GtkCssProvider` and one handler per repository selected, for the life
of the process.

### o-X20 · The graph dot paints an opaque disc over the selection highlight — S

### o-X21 · README's "not yet ported" list understates the gap — S

The list omits conflict resolution (**o-X4**), AI generation (**o-X5**),
discovery and auto-fetch (**o-X1**), and sidebar summaries (**o-X2**). Someone
choosing the Linux build reads that list to decide. **Fix it with each port**,
not as a batch.

### o-X22 · No `.desktop` file and no window icon — S

The app cannot be launched from a desktop environment's launcher and shows a
generic icon in the task switcher.

---

## AI / commit-message generation — wave 5 (`opus.md`)

### o-A1 · The request body is unbounded, because only the patch is capped — S

`CommitMessageGenerator.prompt` caps the patch at `maxDiffCharacters = 12_000`
(`CommitMessageGenerator.swift:60`) and interpolates the `--stat` summary **in
full** (`:59`), deliberately, per the doc comment. But the *producer* has no cap
either: `stagedDiffStat()` runs `git diff --staged --stat --no-color` with no
`--stat-count`, so it emits one line per changed file.

Stage a vendored or generated tree — `git add -A` after an `npm install`, a
`vendor/` drop, a regenerated lockfile tree — and `--stat` is tens of thousands of
lines. 30,000 files is roughly **2 MB of stat text POSTed verbatim**. The request
either fails with a context-length error the user cannot act on, or succeeds and
costs a fortune.

The existing test hides it: `testPromptTruncatesHugeDiffs` passes an *empty*
stat (see **o-T3**). **Fix:** `--stat-count=200` (git appends its own
`… N more files`), or a `maxStatCharacters` keeping the head plus the final
`N files changed, …` line — the one line that actually matters.

### o-A2 · A staged Markdown code fence closes the prompt's own fence — S

The only thing separating untrusted repository content from instructions is a
three-backtick fence that the content can itself close. Any staged `.md` file
containing ```` ``` ```` ends the fence early, and everything after it is read as
instruction. **Fix:** use a fence longer than the longest run of backticks in the
payload (git's own approach), or a random delimiter, and say in the system prompt
that the delimited region is data.

### o-A3 · There is no wall-clock deadline on the request — S

### o-A4 · Cancelling a generation neither cancels the request nor says anything — S

### o-A5 · A Keychain read failure makes Save **delete** the stored key — M

`KeychainStore.read` collapses every `OSStatus` into nil
(`KeychainStore.swift:60`) — "no item stored" and "could not read the item"
become the same answer. That nil flows into the Settings field
(`SettingsView.swift:136`), and `save()` writes the field's contents with no
notion of "unchanged", where an empty string means **delete**.

So a locked keychain, a denied prompt, or any transient `SecItemCopyMatching`
failure shows an empty API-key field; the user presses Save for an unrelated
reason (changing the model, say) and **their key is destroyed**. `SecretService`
on Linux has the same shape.

**Fix:** `read` returns nil only for `errSecItemNotFound` and throws otherwise.
Settings tracks whether the field ever loaded successfully and treats "empty and
never loaded" as *leave alone*, with an explicit **Remove Key** button for when
deletion is what the user means.

### o-A6 · Local OpenAI-compatible servers cannot be used at all — S

Both network entry points hard-fail on a missing key *before* looking at the
endpoint (`:83`, `:148`), and Settings disables both discovery buttons on an
empty key (`SettingsView.swift:191`). Yet `LLMConfiguration`'s own documentation
sells exactly this configuration: a custom endpoint pointing at local llama.cpp,
Ollama, LM Studio or LiteLLM — none of which needs a key, several of which reject
an `Authorization` header outright.

This is also the best answer to the app's own privacy positioning: a local model
means the diff never leaves the machine. **Fix:** send `Authorization` only when
a key exists, and drop the guard for the custom provider (keep it for hosted
providers, where a missing key really is the error).

### o-A7 · An error payload returned with HTTP 200 is thrown away — S

The decode requires the exact `choices[0].message.content` shape and otherwise
throws `.malformedResponse`, whose description is a fixed string. The body —
which for OpenAI-compatible servers almost always contains
`{"error": {"message": "…"}}` — is never consulted. **Fix:** try the error shape
before giving up, and surface its message.

### o-A8 · `finish_reason` is ignored, so a truncated message lands in the commit box — S

### o-A9 · A base URL carrying credentials is persisted to UserDefaults in plaintext — S

A custom endpoint of the form `https://user:token@host/v1` is stored whole in
UserDefaults. Violates the "secrets only in the system secret store" rule.
**Fix:** strip and reject userinfo in the URL, pointing the user at the API-key
field.

### o-A10 · Show the model the repository's own conventions — M · **high value; absorbs F42**

`systemPrompt` hardcodes generic advice — "Use a Conventional-Commits prefix …
only when it clearly fits" — and nothing in the request tells the model what
*this* repository does. A project whose four thousand commits all read "Fix the
thing that broke" gets `fix: thing that broke`; one that requires `[JIRA-123]`
gets nothing; one that never uses Conventional Commits gets them anyway, at the
model's discretion.

That is the difference between a feature you press every time and one you pressed
twice.

**Fix:** `git log -n 20 --no-merges --pretty=%s` (plus the two most recent full
bodies) is one cheap read on a queue the code already uses, and the prompt builder
is a pure `static func`, so the whole thing is testable without a network. Feed
`commit.template` / `.gitmessage` in the same block, which closes **F42** at the
same time.

Worth stating what makes this more than a prompt tweak: it turns the feature from
"an LLM writes a commit message" into "GitEnough writes a commit message that
looks like it belongs in this repository".

---

## Forge — wave 5 (`opus.md`)

### o-G1 · "Open Pull Request" cannot fail visibly — S

`RepoViewModel.openPullRequest` (`RepoViewModel.swift:471`) ends with
`Platform.open(url)` and discards its `Bool`. On a Linux box with no `xdg-open`
— or a macOS install with no default browser — the spinner stops and nothing else
happens at all: no error, and no URL the user could copy. **Fix:** surface the
failure with the URL in the message, so it is at least copyable. Same root as
**o-PS2**.

### o-G2 · The PR lookup's stated worst case is not enforced — S

The doc comment bounds the probe sequence; the code does not. **Fix:** enforce
the bound, or correct the comment.

---

## Platform seam (`Platform/`) — wave 5 (`opus.md`)

### o-PS1 · `swift build` on macOS may not compile at all — S

Worth checking first, since it determines whether the documented core-only build
works for anyone. See **o-T4**: CI never builds it.

### o-PS2 · `Platform.open` is documented non-blocking and is not, and its failure is discarded — S

Two separate defects in one function: it blocks (contrary to its own doc comment,
and it is called from the main thread), and its `Bool` result is dropped by every
caller. **o-G1** is the user-visible face of the second half.

### o-PS3 · `ProcessRunner.run` has no timeout, so a locked keyring wedges the app — S

`secret-tool` against a locked keyring waits for a GUI unlock prompt that may
never come. With no timeout, the calling thread never returns. **Fix:** a
deadline, and a typed timeout error the Settings UI can explain.

### o-PS4 · `ProcessRunner.run` swallows stdin write errors — S

`GitShell.runWithStdin` distinguishes an expected `EPIPE` from a real write
failure; `ProcessRunner` does not. Port the same handling.

### o-PS5 · Merge-tool detection searches a different PATH than git does — S

Detection uses the process PATH; git children get `GitShell.childEnvironment`'s
augmented PATH. So a tool git *would* find can be reported missing, and vice
versa. **Fix:** search the same PATH the child will get.

### o-PS6 · `FreedesktopTrash` reserves the record name but not the file name — S

The `.trashinfo` record is created exclusively, but the file move is not, so two
concurrent discards can collide on the file name. **Fix:** reserve both, or
derive the file name from the reserved record name.

### o-PS7 · `FreedesktopTrash`'s shared `DateFormatter` is raced by concurrent discards — S

Same class of bug as the one #38 fixed in `GitParsers.parseDate`. **Fix:** the
same remedy — configure once, or use a per-call formatter.

### o-PS8 · `ObservableObjectPublisher`'s Linux shim delivers in `Dictionary` order — S

Subscribers are stored in a dictionary and notified in its iteration order, which
is unspecified and varies per process. macOS delivers in subscription order.
**Fix:** an ordered store, so the two platforms behave alike.

### o-PS9 · The Linux keyring has no writer — M

`SecretService` can read but the Settings UI has no path to *store* a key on
Linux, so the AI feature cannot be configured there at all. Pairs with **o-X5**
(the dead Generate button): both must land for the feature to exist on Linux.

### o-PS10 · `KeychainStore` imports `Security` from `AI/` — S

Direct violation of the stated rule that nothing outside `Platform/` imports
AppKit or Security. **Fix:** move the `Security` import behind a `Platform` call.

---

## Tests & CI — wave 5 (`opus.md`)

### o-T1 · The GTK front end is compiled by CI and never executed — M

The Linux job runs `swift build --build-tests`, `swift test`, and
`swift build --product gitenough-gtk`. The last proves the front end *compiles*;
nothing runs it, and **there is not one test in `GitEnoughTests/` that references
anything under `Linux/`**.

That is exactly why **o-X1**, **o-X2**, **o-X5**, **o-X6**, **o-X7**, **o-X8** and
**o-L1** could all ship: every one is a wiring defect in code that compiles
perfectly.

**Fix:** most of those defects live in logic that needs no display. Pull it out and
test it — `historySignature(commits:layout:unpushed:canLoadMore:)` as a free
function (**o-L1**), the selection-restoration rule (**o-X8**), the "should the
diff be rebuilt" predicate (**o-X7**). Each becomes a plain unit test in the shared
suite. For the rest, `xvfb-run` in CI plus a smoke test that constructs the window
and pumps the loop a few turns would have caught **o-X1** and **o-X2** immediately.

### o-T2 · `RepoDiscoveryTests` wipes the developer's real `UserDefaults` — S · **fix first**

`setUpWithError`/`tearDownWithError` (`RepoDiscoveryTests.swift:157-169`) call
`UserDefaults.standard.removeObject(forKey:)` for `repositories.v1`,
`excludedRepositories.v1`, `repoLastOpened.v1` and the starred key, and every test
in the file builds `RepoStore()` with the defaulted `.standard` (`:172`, `:189`,
`:228`, `:363`). Line 385 writes into it directly.

So **running the test suite deletes the developer's registered repositories, their
stars, their removal-exclusion list and their recently-opened timestamps.** It also
makes the tests order-dependent on whatever the machine happened to have, so a
green run locally is not the same run as CI's.

`AppStateSelectionTests` already does this correctly, with a per-test suite it
tears down — the pattern to copy is twelve lines away. **Fix:**
`UserDefaults(suiteName: "RepoStoreTests-\(UUID())")` per test, removed in
teardown, threaded through every `RepoStore(defaults:)`.

### o-T3 · The test that proves the prompt is bounded neuters its own input — S

`testPromptTruncatesHugeDiffs` passes an **empty** `diffStat`, so it exercises
only the half of the prompt that is capped and cannot see **o-A1** at all.
**Fix:** give it a 50,000-line stat and assert the *whole* prompt is bounded.

### o-T4 · The documented core-only build is never built — S

`AGENTS.md` and `README` both document `GITENOUGH_NO_GTK=1 swift test` as the
supported way to build the core without gtk4, and CI never runs it — the Linux job
installs `libgtk-4-dev` and builds everything. A change to `Package.swift`'s
conditional target graph would break the documented path silently. **Fix:**
`GITENOUGH_NO_GTK=1 swift build` before installing gtk4, which costs nothing and
proves the manifest branch.

### o-T5 · Documentation claims Linux features that do not work — S

README's Linux section and the Settings copy both describe the watch folder and
automatic fetch as working; per **o-X1** they are inert on Linux, and README's
"Not yet ported" list omits them. **Fix the code** (**o-X1** is small) rather than
the docs; if it is deferred, the list needs the entries.

---

## Rescued from the review branches (gap audit, 2026-09-11)

As the eight review branches are retired, every finding in each document was
re-checked against `main` at `55328b5`. Almost all had shipped or were already
captured above. The entries below are the exceptions: live in the current code,
absent from this backlog, and concrete. All are small, and most are polish or
performance, but o-UI10's first item is a correctness bug: a masked Keychain
save failure reported as success, which costs the user their API key on next
launch. Each carries the `file:line` that made it checkable.

### o-UI10 · The "smaller cuts" bundle from `opus.md` (Part 16 · S10) — S each

The backlog imported `opus.md`'s Part 16 items S1 through S9 as `o-UI1`…`o-UI9`
but dropped its S10 bundle. Seven items, each still live and independent:

- **Test Connection reports success over a failed key save.** `testConnection()`
  calls `save()`, then clears its status (`SettingsView.swift:261-263`), and on a
  working round-trip shows "Connection works" (`:276`) using the in-memory key
  (`:266`). A Keychain write that threw inside `save()` (`:225-227`) is masked, so
  the user believes a key is stored that is not, and loses it next launch. Not
  covered by o-A5 (a read failure deleting the key) or C5a (endpoint/credential
  scope). Fix: surface the save failure instead of niling it, or do not `save()`
  from Test.
- **The Add Repository sheet reopens showing the last failure.**
  `addRepositoryError` is set on a bad add (`AppState.swift:196`) and cleared only
  on the next success (`:206`); the sheet renders it (`AddRepositoryView.swift:72`)
  and Close only dismisses (`:81`), so reopening shows the stale error. Distinct
  from C4 (forms closing before git returns). Fix: clear it on the sheet's appear
  or dismiss.
- **`⌥⌘F` Fetch is live in the menu with no remotes.** The toolbar disables Fetch
  on `remotes.isEmpty` (`RepoDetailView.swift:108`); the menu item checks only
  `isBusy` (`AppCommands.swift:28`), so the shortcut fires `git fetch --all` over
  zero remotes. Fix: add the `remotes.isEmpty` guard to the menu item.
- **`⇧⌘B` opens New Branch pre-filled with the last name.** The toolbar clears
  `newBranchName` first (`RepoDetailView.swift:80`); the menu path does not
  (`AppCommands.swift:44`), and the sheet never resets it. Fix: clear it in the
  menu path too.
- **Activity History re-filters its whole store two to three times per render.**
  `filtered` (`ActivityHistoryView.swift:18`) is recomputed at `:34`, `:42`, and
  `:47`, and the body re-runs on every keystroke and every git command. P5 and P7
  scope this cost to the diff and History views, not this separate window. Fix:
  compute it once per body.
- **The toolbar progress spinner is inserted, not reserved.**
  `RepoDetailView.swift:96-102` conditionally inserts `ProgressView()` ahead of
  Fetch/Pull/Push, so the cluster jumps right the instant an op starts. Distinct
  from glm-V5 (the Publish/Push label-width swap). Fix: reserve the width and
  toggle opacity.
- **The history filter is a borderless `.plain` field.** `HistoryView.swift:286`
  styles the filter `.plain`, so it reads as a label rather than an editable
  field, unlike the sidebar's search field. Fix: use a search-field style.

### glm-P3 · The status bar re-filters the activity list on every keystroke — S

`runningActivityEntries` (`RepoViewModel.swift:60-62`) filters the 100-entry
`activityEntries` on each access; the status bar reads it
(`RepoDetailView.swift:401`) and `draftCommitMessage`'s `didSet` (`:98`)
republishes on every keystroke, so the filter re-runs once per character typed.
P7 is scoped to the History view, not this. Fix: maintain a stored
`runningCommands` in the `activityLog.onChange` hop and read that.

### glm-U2 · A conflict row gives no lasting "markers remain" signal — S

When an external merge tool exits with conflict markers still present, the only
feedback is a transient banner (`RepoViewModel.swift:706`); `ConflictRow`
(`ChangesView.swift:444-503`) shows a static unmerged badge with no
markers-remaining state, so the signal is lost the moment the banner is
overwritten (see glm-G3 on the banner's lifecycle). The conflict-inspection
entries (o-U5, C2, o-X4) concern viewing the conflict, not this. Fix: flag paths
left with markers on tool exit and mark those rows.

### kimi-4.3 · History ref chips have no per-chip width cap — S

`RefChip` sets `Text(label).lineLimit(1)` with no `maxWidth` or truncation
(`CommonViews.swift:36-37`), so one long branch or tag name grows the chip
without bound. F28 caps the toolbar picker, F29 collapses the HEAD chip, V4 adds
the `+N` overflow, and A5 tints chips, but none caps a single chip's own text.
Fix: give the chip a bounded width such as `.frame(maxWidth: 180)` and
`.truncationMode(.middle)`.

### flash-U4 · The `⌘↩` commit shortcut is undiscoverable — S

The Commit button carries `.keyboardShortcut(.return, modifiers: .command)`
(`ChangesView.swift:302-312`) but nothing surfaces it: the placeholder is just
"Commit message" (`:243`), with no hint and no `.help()`. o-V1 and F34 redesign
the commit box but add no shortcut hint. Fix: put the hint in the placeholder or
a caption near the button.

### flash-V6 · Sidebar rows have no leading repository icon — S

Sidebar rows render `Text(repo.name)` with no leading glyph
(`SidebarView.swift:265`); only the invalid-repo triangle, star, and dirty dot
appear inline. V11 scopes file-type icons to the Changes and CommitDetail lists;
glm-A1 reorders the row's hierarchy without a leading icon. Fix: add a leading
`folder` SF Symbol, or a per-type icon.

---

## Verified non-issues (do not re-audit)

*Checked directly during the reviews and found sound. Re-auditing these costs
time and produces nothing.*

**From the wave-2/3 pass:**

- **Graph width never includes trailing free lanes** — every lane is either
  occupied (drawn to the last row) or was claimed by a node, so `columnCount`
  never exceeds `maxNodeColumn + 1`.
- **The GLM-review workflow's `pull_request_target` gate**
  (`.github/workflows/zai-code-review.yml`) correctly restricts the privileged job
  to same-repo branches.
- **TimelineView minute-boundary alignment** does not help: relative-date
  rollovers are anchored at each commit's own second, not wall-clock minutes, and
  the staleness bound is <60 s either way.
- **#58 does not defeat #68.** #58 strips `GIT_LITERAL_PATHSPECS` from the
  *inherited* environment; #68 sets it as an explicit override for
  `git mergetool`, and overrides are merged after sanitization.
- **#64 survives #79.** `GitActivityLog.normalizedArguments` already strips
  `--no-optional-locks`.
- **#66's non-defaulted `Branch.refName` breaks no fixture.** `Branch(` is
  constructed in exactly one place (`GitParsers.swift`); no test builds one.
- **#80's mutation gate cannot wedge.** `perform` funnels success and failure
  through a single `DispatchQueue.main.async`, so `operationGate.finish(id)` is
  always reached.
- **#38's formatter change is correct.** `ISO8601DateFormatter`'s default
  `formatOptions` is exactly `[.withInternetDateTime]`.

**From wave 5:**

- **Integration tests do not skip silently.** Every git-dependent suite throws
  `XCTSkip` with a reason (`GitIntegrationTests.swift:13` and four others), which
  reports as a skip rather than a pass.
- **The `Package.swift` `exclude:` drift is self-enforcing.** A new directory
  under `GitEnough/` that imports SwiftUI breaks the Linux library build, which
  CI runs on every PR.
- **`GitIgnore.appending` and `escape` are correct.** The glob escaping, the
  leading `#`/`!` handling and the trailing-whitespace rules all match git's
  semantics. (The byte-arithmetic bug that shipped in #97 was entirely in the
  *caller*.)
- **`discard()`'s unborn-HEAD handling is correct.** It probes
  `rev-parse --verify HEAD` explicitly and documents why.
- **The macOS graph strip resolves its background correctly**
  (`Color(nsColor: .textBackgroundColor)`). Only GTK hardcodes (**o-X9**).
- **`GitShell.sanitizedEnvironment` and the SIGPIPE handling are sound.** The
  repository-local variable list matches `git rev-parse --local-env-vars` plus the
  pathspec-mode variables, `SIG_IGN` is installed process-wide and idempotently,
  and the stdin writer distinguishes expected `EPIPE` from real write failures.
- **`DispatchMainQueueBridge` is correct**, including consuming the eventfd token
  before `_dispatch_main_queue_callback_4CF` — the omission that would cause a
  100 % CPU spin.
- **Commit-detail and diff loads are already generation-guarded** against stale
  completions. The remaining problem is that superseded loads still *run*
  (**o-P5**), not that they are applied.
- **`diff.external` does not affect `--name-status`, `--name-only` or `--stat`.**
  Verified against git 2.43 with a driver that replaces the patch: `show
  --name-status` and `diff --name-only` come back untouched. So `commitDetail`
  and `conflictedPaths` never needed `--no-ext-diff`, and #98's flag scoping is
  exactly the set that did.
- **Porcelain v2 `u` entries never reach the staged/unstaged lists.**
  `GitParsers` routes them to `status.conflicted` alone (`:170`), which is why
  the row-level Stage action cannot reach a conflicted path and why the guard in
  #100 belongs on `stageAll` rather than on `stage(paths:)`.

---

## Suggested next pickups (highest value first)

*The list below is wave 5's ranking, merged with the standing one. Wave 5's top
five have shipped (PRs #96–#101); what remains starts at the sixth.*

### Broken things, in order of what they cost the user

1. **o-A5 · Stop a Keychain read failure from deleting the API key.** Pressing
   Save after a failed read destroys the stored key with no warning. This is the
   last remaining entry from wave 5's "the first five are not close".
2. **o-L3 + C1 · Stop a failed git read from publishing a healthy summary.** A
   missing repository currently renders as "Working tree clean" — the most
   reassuring thing the app could possibly say about a repository that is gone.
3. **o-T2 · Stop the test suite deleting the developer's real repository list.**
   Twelve lines, and it is currently a tax on everyone who runs `swift test`.
4. **o-X1 + o-X2 + o-X3 · Give Linux its heartbeat.** One `RunLoop` timer nothing
   runs makes the watch folder and auto-fetch inert; no `refreshSummaries` call
   makes the sidebar show filesystem paths; no activation hook makes every watcher
   blind spot permanent. Three small fixes, one coherent change, and they are the
   difference between "the Linux port works" and "it compiles".
5. **o-L1 · Make the GTK history signature describe what is drawn.** Checkout,
   push and branch creation all leave the graph showing the previous state.
6. **o-L5/o-L12 · Derive merge-tool names from `git mergetool --tool-help`.**
   Three of nine offered tools always fail, two with no error text.
7. **o-L2 · Show the right status letter on the right side.** A deleted file
   currently renders as a green "Added" row.
8. **o-A1 + o-A2 + o-A3 (+ o-A7, o-A8) · Harden the LLM request.** Bound the
   stat, use a delimiter the payload cannot forge, set a real wall-clock
   deadline. All five are the same request path and share a fixture.
9. **o-A6 + o-PS9 · Make local models usable**, on both platforms. The best
   answer to the app's own privacy positioning.

### The everyday loop

10. **o-L6 + o-P1 · Notice that a file changed.** Editing a selected file leaves
    the diff pane showing the previous content, and the watcher cannot see nested
    edits at all. One bug from the user's side; fix as one change.
11. **o-P5 · Stop running superseded loads.** Arrow-keying through history queues
    one `git show` per row and jams the repo queue behind them.
12. **o-U5 + o-X4 + o-L7 · Let people see and resolve a conflict.** Conflicted
    files cannot be inspected on macOS, are invisible on Linux, and modify/delete
    dead-ends with Abort as the only exit.
13. **o-P10 + o-P9 + o-P11 · Make discovery cheap and non-blocking.** A watch
    folder on an unresponsive mount currently freezes the app on every tick.

### The graph, which is the product

14. **o-H1 · Route the leftward fold between rows.** Today it runs along the next
    row's centre line and threads through unrelated commits — the worst thing a
    history graph can get wrong.
15. **o-H4 + o-D3 · Make lane colour stable, then make it mean something.** One
    fetched branch currently recolours the entire graph. Fix that and the colour
    becomes an identity usable everywhere a branch is named.
16. **o-H3 / glm-V7 · Scale stroke geometry with the lanes,** so a crowded graph
    is dense rather than solid — and so an unpushed dot cannot vanish entirely.
17. **o-H6 · Stop the list jumping sideways when you type in the filter.**

### Worth building because they are good

18. **o-A10 · Teach the commit-message prompt the repository's house style.** The
    cheapest change on this list with the largest effect on whether the headline
    feature gets used. Absorbs **F42**.
19. **o-D2 · Merge and pull preflight with `git merge-tree`.** One process, no
    mutation, and it turns the most-feared operation in the app into a decision.
    Nobody else in this category does it well.
20. **Q1 · The Safety Net.** Undo on the app's own command log rather than the
    reflog — it covers Discard and staging, which the reflog cannot see, and names
    operations the way the user saw them. **o-UI5** is its natural first customer.
21. **o-U1 · Make History a real list,** which is most of U1, U4, F16, F30 and
    V12 at once.
22. **o-V3 + o-V4 + F36 · One palette, one spacing scale, and some motion.** The
    difference between a competent native app and a considered one, and mostly
    modifiers rather than architecture. Prerequisites for **A0**.

### The standing backlog, unchanged in priority

23. **C5a/C5b** endpoint safety and the activity-history file mode (C5b is now
    three lines — see its entry)
24. **C6** honest selected-diff failure states
25. **C5c** bounded Git detection plus cancellable signing stalls
26. **P0**, then the contained perf fixes — **o-P6**, **o-P2**, **o-P8** — before
    any coordinator rewrite
27. **C2/C3** conflict semantics and merge-tool leases (highest mutation risk)
28. **C5d/C5e** spoof-proof parser framing and per-command ref safety
29. **P2** inactive-model lifecycle; **P1** proper event-driven watching *after*
    o-P1's cheap additions land
30. **F17** diff width/backgrounds, then **V1/V3a–V3d** gutters, split mode,
    images, whitespace and navigation
31. **F16** multi-select staging plus **U2** shortcuts
32. **F15-remainder/F39** remote-branch maintenance and cleanup assistant
33. **M2/M7** blame and file history
34. **U0/U0a/U0b** one obvious sync path, visible branch actions, outcome feedback
35. **V0** responsive layout
36. **M18** pull-autostash rescue and **F18** branch search
37. **Q2 + o-D8** command palette, derived rather than hand-maintained
38. **M15** minimal interactive rebase, guarded by a new all-remote reachability
    predicate rather than #42's upstream-only display marker
39. **glm-U3/glm-B9** bulk discard and preferred-remote fetch
40. **glm-Q4/glm-M3** push-preview popover and Changes totals bar

### Deliberately not recommended

- **Rewriting the refresh pipeline** (P3/P9) before the specific bugs above are
  fixed. P4/P5/P6/P7 each have a contained fix; the coordinator is a rewrite that
  would absorb them and delay all of them.
- **FSEvents/inotify** (P1) as the *first* move on the watcher. The cheap
  additions in **o-P1** recover most of the correctness at a fraction of the risk,
  and they make the eventual event-driven version easier to validate because the
  symptom is gone and the test exists.
- **Hunk-level staging** (M19). Genuinely wanted and genuinely large; everything
  above it is cheaper per unit of user pain.

---
