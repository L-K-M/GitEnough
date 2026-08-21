# Open pull-request review — 55 PRs (#36–#90)

Review of every pull request open against `main` as of 2026-08-21, covering
mechanical state (CI, mergeability, entanglement), a verified landing order,
duplicate/superseded groups, and the cross-PR defects that git cannot flag
because they live in different files.

Everything below marked *verified* was produced by running the operation, not
by inspection: merges were actually performed against `origin/main` in a
scratch worktree, and CI conclusions were read from each PR's head commit.

**This machine has no Swift toolchain** (a macOS project in a Linux container),
so nothing here is a build or test result of my own. Compile-level claims rest
on each PR's own green `Build & Test` check, which runs `xcodebuild clean test`
on `macos-14`.

---

## 1 · Mechanical state

| Fact | Value |
|---|---|
| Open PRs | 55 (#36–#90), all targeting `main`, none draft |
| `Build & Test` green | **55 / 55** |
| `Review PR with GLM 5.2` | fails on ~40 / 55 — non-gating reviewer bot, not a code signal |
| Merge cleanly onto `main` *individually* | **55 / 55** |
| Conflicting pairs *between* PRs | **50** |

Contention hotspots — files by number of PRs touching them:

| File | PRs |
|---|---|
| `Model/RepoViewModel.swift` | 24 |
| `GitEnoughTests/GitIntegrationTests.swift` | 16 |
| `Git/GitClient.swift` | 15 |
| `UI/ChangesView.swift` | 9 |
| `Git/GitParsers.swift`, `UI/HistoryView.swift`, `UI/BranchesView.swift` | 8 each |

### Pairwise independence does not survive stacking

A greedy graph colouring of the 50-edge conflict graph proposes five waves of
mutually non-conflicting PRs. Only the first survives contact: merging wave 1
(33 PRs) succeeded, and then **every** PR in waves 2–5 conflicted against the
accumulated tree — 22 failures where the pairwise graph predicted none.

Treat the conflict graph as a lower bound on entanglement, never as a plan.
The landing order below was derived by re-testing against the real accumulated
tree after every merge.

---

## 2 · Recommended landing order (verified)

Close the four superseded PRs first (§3), then merge in this order. Each entry
was test-merged onto the accumulated result of all the entries before it.

```
77 59 63 47 38 44 45 46 48 49 51 52 58 60 61 65 69 70 75 88
37 39 54 62 64 67 76 78 82 86 87 89 57 66 80 72
```

**36 of the 51 non-superseded PRs land with zero conflicts in this order.**

Ordering matters semantically, not just mechanically. Plain ascending-PR-number
order also lands 36, but it lands #56 before #59 and #36 before #77 — in both
cases permanently blocking the better implementation. Putting the four
preferred supersets (#77, #59, #63, #47) first lands the same count while
keeping the right versions.

### Residue — 15 PRs needing hand resolution

| PRs | Conflicts in | Nature |
|---|---|---|
| #40, #42, #84 | `GitIntegrationTests.swift` only | **Trivial.** Each appends a new `func test…` at the same anchor. Resolution is "keep both". Verified: 2 hunks each, no disagreement. |
| #50 | `RepoViewModel.swift`, tests | Mostly additive |
| #41, #73, #81, #83, #43 | `RepoViewModel.swift` | Genuine same-function edits |
| #53, #55 | `HistoryView.swift` | Genuine same-region edits |
| #68, #79, #90 | `GitClient.swift`, `GitParsers.swift` | Genuine — each rewrites many call sites |
| #71 | `AppState.swift`, `AppCommands.swift` | Genuine |

---

## 3 · Duplicates and superseded PRs — close these four

| Close | In favour of | Evidence |
|---|---|---|
| **#36** | **#77** | `pr/36` is a literal git ancestor of `pr/77` — #77 contains #36's commits outright, plus `ChangeSelection`, staged/unstaged selection identity, and commit-file-diff loading state. Verified with `git merge-base --is-ancestor`. |
| **#56** | **#59** | Competing fixes for the same bug (slash-named local branches chipped as remote). #56 threads `remoteNames` into the parser; #59 asks git for `--decorate=full` and classifies on exact `refs/heads/` · `refs/remotes/` prefixes, additionally dropping `origin/HEAD` noise, handling the `HEAD -> tag:` case, and dropping forge namespaces (`refs/changes`, `refs/merge-requests`). #59 is strictly better and needs no plumbing. |
| **#74** | **#47** | Near-identical diffs — same predicate, same `TextField` placeholder change. #47 additionally orders the cheap hash-prefix check before the two localized folds. |
| **#85** | **#63** | #63 covers stage/unstage/discard via `FileChange.affectedPaths`; #85 covers discard only. Both correctly exclude **copies** (a staged `C` carries `originalPath`, but resetting its source would clobber unrelated worktree edits) — #63 via `if isRename`, #85 via `stagedStatus == .renamed`. #63 is the superset. |

---

## 4 · Cross-PR defects — invisible to git

These pairs touch **different files**, so they merge without conflict and CI
stays green on each PR in isolation. They only misbehave once both have landed.

### 4.1 · #48 × #79 — the fallback error message stops naming the command

`#79` centralizes the read-only guard, inserting `--no-optional-locks` at
`argv[2]`, right after the leading `-C <worktree>`:

```
["-C", "/repo", "--no-optional-locks", "status", "--porcelain=v2"]
```

`#48`'s `GitShell.displayCommand` strips only leading `-C` pairs, then returns
`argv.first`. After both land, the synthesized empty-stderr failure reads:

```
git --no-optional-locks failed with exit code 128.
```

which names no command — exactly the bug #48 exists to fix ("git -C failed with
exit code 128"). Verified by simulating both transforms.

**Fix:** have `displayCommand` skip leading global flags after the `-C` pairs.
`GitActivityLog.normalizedArguments` (added by **#64**) already does this
correctly — it strips `--no-optional-locks` explicitly, which is why #64 × #79
is fine and #48 × #79 is not. Reuse that logic rather than duplicating it.

### 4.2 · #89 re-introduces the bug #73 fixes

`#73` replaces split-at-first-slash upstream parsing with longest-prefix
matching against configured remotes, because remote names may themselves
contain slashes:

```swift
// #73 — Remote.preferred(for:among:)
remotes.filter { upstream.hasPrefix($0.name + "/") }
       .max(by: { $0.name.count < $1.name.count })
```

`#89` (opened later) promotes `preferredRemote` to a property for the status
bar and adds a new **static** helper that keeps the old logic:

```swift
// #89 — RepoViewModel.preferredRemote(upstream:remotes:)
upstream.split(separator: "/").first          // ← the bug #73 removes
```

The two conflict, so a human resolves them — and resolving in favour of #89
(the newer, larger PR) silently reverts #73 and enshrines the regression in
#89's new unit tests.

**Fix:** land both, but the merged `preferredRemote` must call
`Remote.preferred(for:among:)`. #89 keeps its property/status-bar surface; #73
keeps the matching rule.

### 4.3 · #54 × #81 — two `didSet` blocks on the same property

Both add a `didSet` to `RepoViewModel.draftCommitMessage`:

- **#54** persists the draft to `UserDefaults` per repository.
- **#81** bumps `draftCommitMessageRevision` and invalidates any in-flight AI
  generation, so typing cancels a late-arriving suggestion.

Swift allows only one `didSet` per property, so this *is* a conflict — but a
resolver taking one side wholesale loses the other behaviour silently, and
neither PR's tests cover the other's. The merged observer must do both, and
must keep #54's init-time restore going through `_draftCommitMessage =
Published(initialValue:)` so restoring a draft doesn't count as user typing.

### 4.4 · #57 × #83 — this merge breaks a test whichever side you take

Neither is an ancestor of the other (verified); both rewrite the same two
methods, and both are green alone.

#57 gives `pull()` a two-branch guard:

```swift
errorMessage = remotes.isEmpty
    ? "Can't pull: this repository has no remotes configured. Add a remote first."
    : "Can't pull: the current branch has no upstream branch to pull from. …"
```

#83 replaces it with the single no-upstream message and drops the no-remotes
branch. But #57 ships `RepoViewModelTests.testPullWithoutUpstreamFailsGracefully`,
which asserts exactly that wording:

```swift
XCTAssertTrue(viewModel.errorMessage?.contains("no remotes") ?? false)
```

A fresh view model has no remotes *and* no upstream, so under #83's guard the
message never contains "no remotes" and **#57's test fails**. Resolving the
conflict in favour of #83 — the larger, more structural PR, the natural
instinct — turns CI red on `main` even though both PRs were green.

**Fix:** keep #57's two-branch `pull()` guard and #83's `PushCapability`. They
are complementary; only the pull wording collides. #57's *push* test stays green
either way, because `PushCapability.resolve` returns `.unavailable(.noRemotes)`
with matching wording.

### 4.5 · #71 × #83 — two mechanisms for the same staleness bug

Both fix "SwiftUI Commands observe `AppState`, not the nested `RepoViewModel`,
so menu enablement goes stale", by different means:

- **#71** subscribes to the *active* view model's `objectWillChange` and
  forwards it, storing an `AnyCancellable` and re-subscribing on selection
  change.
- **#83** calls `objectWillChange.send()` from inside `onStatusChange` when the
  changed repo is the selected one.

Landing both leaves two overlapping mechanisms and double invalidation
(harmless, but two things to keep correct). Pick one — #71's is the more
general, #83's the cheaper — and drop the other during conflict resolution.

### 4.6 · Longest-prefix remote matching is written three times

The "remote names can contain slashes, so match the longest configured prefix"
rule is implemented independently in three open PRs:

| PR | Location |
|---|---|
| #73 | `Remote.preferred(for:among:)` |
| #84 | `GitClient.deleteRemoteBranch` |
| #89 | `RepoViewModel.preferredRemote` (as the *buggy* short form — §4.2) |

Three copies of a subtle rule is three places to regress it, as #89 already
demonstrates. Consolidate on a single helper on `Remote`.

### 4.7 · #42 hand-rolls the read-only flag

`#42`'s `unpushedCommitHashes()` passes `--no-optional-locks` inline rather
than going through #79's `runRead`. Correct as written, but it is precisely the
drift #79's doc comment says centralizing prevents. Route it through `runRead`
when both land.

---

## 5 · Interactions checked and found sound

Recorded so they are not re-audited.

- **#58 × #68.** #58 strips `GIT_LITERAL_PATHSPECS` from the inherited
  environment; #68 sets it as an explicit override for `git mergetool`.
  Overrides are applied *after* sanitization
  (`childEnvironment.merging(overrides) { _, override in override }`), so #68's
  hardening survives #58. Verified by reading the merge point.
- **#64 × #79.** `normalizedArguments` already removes `--no-optional-locks`,
  so activity-log display and the paste-safe copy stay correct.
- **#66 and `Branch`'s memberwise init.** #66 adds a non-defaulted `refName`.
  `Branch(` is constructed in exactly **one** place in the whole repo
  (`GitParsers.swift:171`) — no test fixture builds one, so nothing breaks.
  #40 (`upstreamGone`) and #90 (`lastCommitDate`) both add defaulted fields.
  All three still need to land together deliberately: they contend over
  `parseBranches` and #66 changes the `%(upstream)` field's meaning.
- **#80's gate cannot deadlock.** `perform` funnels success and failure through
  a single `DispatchQueue.main.async`, so `operationGate.finish(id)` is always
  reached. Verified against `perform`'s body on `main`.
- **#80's `dispatchPrecondition(.onQueue(.main))`** is safe: the only non-UI
  caller of a mutating op is `AppState.autoFetchIfDue`, reached from a `Timer`
  added via `RunLoop.main.add`.
- **#38** removes the per-call `formatOptions` assignment that made
  `parseDate`'s shared `ISO8601DateFormatter` a data race. The claim that the
  default is exactly `[.withInternetDateTime]` is correct, so `%aI` still
  parses.

---

## 6 · Behaviour changes worth a maintainer's explicit nod

Not defects — deliberate choices whose blast radius is wider than the PR title
suggests.

- **#78** makes `markResolved` *throw* when conflict markers remain, and
  `RepoViewModel` no longer pre-checks. Cancelling an external merge tool used
  to be a silent no-op; it now raises an error banner. "Fail closed" is the
  right instinct, but a routine cancel becoming a visible error is a UX shift.
- **#80** applies `.disabled(viewModel.isBusy)` to the whole Changes and
  Branches lists, so a background fetch blocks read-only browsing and selection,
  not just mutation.
- **#65** downgrades the on-activation refresh to `includeHistory: false`,
  delegating history invalidation to the 2.5 s `RepoWatcher`. External commits
  made while backgrounded now surface within one poll interval instead of
  immediately — a deliberate trade for removing a visible hitch on large repos.
- **#72** drops `--tags` from ordinary fetch and pull. Default reachable-tag
  following still applies; this only stops force-updating every tag.

---

## 7 · Per-PR review depth

Honest accounting of how closely each PR was read.

- **Read in full, line by line (41):** #36 #37 #38 #39 #40 #42 #43 #45 #47 #48
  #54 #56 #57 #58 #59 #60 #61 #62 #63 #64 #65 #66 #68 #71 #72 #73 #74 #75 #76
  #77 #78 #79 #80 #81 #82 #83 #84 #85 #87 #89 #90
- **Skimmed at diffstat level only (14):** #41 #44 #46 #49 #50 #51 #52 #53 #55
  #67 #69 #70 #86 #88 — all small, UI-local, and green. No claim is made about
  their internals beyond that.

The code quality across the set is consistently high: every PR carries doc
comments explaining *why*, parsers and pure logic are separated for testing,
and most already fold in one or more rounds of prior review feedback.

---

## 8 · Suggested sequence

1. Close **#36, #56, #74, #85** as superseded (§3).
2. Merge the 36-PR verified order in §2.
3. Resolve the three trivial test-append residues (**#40, #42, #84**) — keep
   both test methods.
4. Land the `Branch`/`parseBranches` cluster (**#40, #66, #90**) as one
   deliberate change.
5. Resolve the remaining residue. Two of them need a specific decision rather
   than a mechanical merge:
   - **#83** on top of the already-landed #57 — keep #57's two-branch `pull()`
     guard or CI goes red (§4.4), and pick one menu-invalidation mechanism
     between #71 and #83 (§4.5).
   - **#73** and **#89** — the merged `preferredRemote` must use #73's
     longest-prefix matching, not #89's split-at-first-slash (§4.2).
6. Apply the remaining cross-PR fixes in §4 (#48 × #79, #54 × #81, the
   triplicated remote matching, #42's inline flag). None of them produces a
   conflict marker, and none is caught by any PR's own CI.
