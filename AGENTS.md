# AGENTS.md

Guidance for AI coding agents working in the **GitEnough** repository.

## What GitEnough Is

GitEnough is a native macOS git client — the everyday 95 % of GitHub Desktop
(fetch, pull, push, branch, merge, stash, commit) with an IntelliJ-style
branch/merge history graph and LLM-written commit messages.

It runs on Linux too, with a GTK 4 front end over the same core (see **Two
builds, one source tree** below). The SwiftUI front end stays macOS-only.

## Tech Stack

- **Language:** Swift (latest stable), macOS 14+ deployment target.
- **UI:** SwiftUI (NavigationSplitView two-pane shell, Canvas for the graph),
  AppKit where needed (NSWorkspace, NSPasteboard, NSOpenPanel).
- **Git:** shells out to the user's own `git` binary (GitShell/GitClient) — no
  libgit2, no bundled git. Arguments are always passed as arrays, never through
  a shell; `--` separates pathspecs from revisions; read-only queries pass
  `--no-optional-locks`.
- **LLM:** OpenAI-compatible chat-completions client (Z.AI GLM default). API key
  in the Keychain via KeychainStore (libsecret's `secret-tool` on Linux);
  everything else in UserDefaults.
- **Platform seam:** `GitEnough/Platform/` — the only place that knows which OS
  it is on. Everything else in the core is plain Foundation.
- **Dependencies:** none. Zero third-party packages; keep it that way.

## Build & Run

### Two builds, one source tree

| | Xcode project | SwiftPM package |
|---|---|---|
| Builds | the whole app, macOS | `GitEnough` library (everything except `UI/`) + `gitenough-gtk` |
| Platforms | macOS 14+ | library: macOS and Linux · GTK app: Linux |
| Tests | all of `GitEnoughTests/` | all of `GitEnoughTests/`, same files |

`Package.swift` points its targets at the **existing** `GitEnough/` and
`GitEnoughTests/` directories rather than a `Sources/` tree, and names the
library module `GitEnough` — the same module name the app target has. That is
what lets one `@testable import GitEnough` serve both builds and keeps the
Xcode file-system-synchronized groups working untouched. A new directory under
`GitEnough/` that the SwiftUI layer must not see has to be added to the
package's `exclude:` list.

The Xcode project uses Xcode 16 file-system–synchronized groups, so new files
added under `GitEnough/` or `GitEnoughTests/` are picked up automatically — no
`project.pbxproj` edits needed. **Requires Xcode 16+.**

`scripts/build.sh` builds and reveals the app (stub for the shared `lkm-build`
engine). Or directly:

```bash
xcodebuild -project GitEnough.xcodeproj -scheme GitEnough -configuration Debug build
xcodebuild -project GitEnough.xcodeproj -scheme GitEnough -destination 'platform=macOS' test
```

On Linux (Swift 6.0+; CI pins 6.2.1), or on macOS to check the core in
isolation:

```bash
swift build                            # on Linux this includes the GTK app
swift test
GITENOUGH_NO_GTK=1 swift test          # core only; no gtk4 needed
```

The GTK targets are declared inside `#if os(Linux)` in `Package.swift`, so a
macOS `swift build` never asks for gtk4. On Linux they are part of the package,
and SwiftPM builds every target — so `swift build` and `swift test` both want
gtk4 installed. `GITENOUGH_NO_GTK=1` drops the front end from the graph for
anyone who only wants the headless core. The core is a **separate module** from
the front end, which is why its declarations are `public` — on macOS that is a
no-op (one module), on Linux it is what makes the split real.

## Layout

- `GitEnough/Git/` — GitShell (process runner), GitClient (typed ops),
  GitParsers (pure, tested), DiffParser, models.
- `GitEnough/Graph/` — GraphLayout: the lane-assignment algorithm for the
  history graph (pure, tested). Input must be newest-first topo-ordered.
  GraphMetrics: the geometry constants — lane width, row height, the
  compression curve — shared by the graph canvas and the commit rows.
- `GitEnough/Forge/` — forge integration for the "Open Pull Request…" command:
  ForgeRepo (remote URL → website URL shapes, pure, tested) and
  PullRequestFinder (unauthenticated "which PR is open for this branch?" API
  lookup — GitHub, GitLab v4, and Forgejo/Gitea; unknown hosts get Forgejo then
  GitLab probes, everything else falls back to opening the forge's compare
  page). No forge tokens, ever.
- `GitEnough/Model/` — RepoStore (sidebar list, persistence, discovery
  exclusions), AppState (selection, view-model cache, watch-folder scans),
  RepoViewModel (per-repo state + ops; all git calls on one serial DispatchQueue
  per repo), RepoWatcher (cheap .git mtime polling), RepoDiscovery (watch-folder
  filesystem scan), GitActivityLog (per-repo rolling command log feeding the
  status bar), GitActivityStore (persistent app-wide JSONL command history).
- `GitEnough/AI/` — LLMConfiguration, CommitMessageGenerator, KeychainStore.
- `GitEnough/Platform/` — the macOS/Linux seam: Platform (open a URL, move to
  Trash, XDG/Application Support directories), ProcessRunner (helper processes
  and PATH lookup), FreedesktopTrash and SecretService (the Linux backends for
  the Trash and the Keychain), plus small stand-ins for the Combine and SwiftUI
  API the model layer uses (`ObservableObject`, `@Published`,
  `move(fromOffsets:toOffset:)`) which compile to nothing on macOS.
- `GitEnough/Tools/` — MergeTool detection (git mergetool integration).
- `GitEnough/UI/` — SwiftUI views, macOS-only and outside the SwiftPM library.
- `Linux/CGtk/` — a system-library target over gtk4 via pkg-config, plus the
  shim header that re-exposes what Swift can't import from C macros.
- `Linux/GitEnoughGTK/` — the GTK 4 front end. `GTK/` holds the interop layer
  (pointer casts, signal-to-closure glue, GValue property setters, and
  `DispatchMainQueueBridge`, which drains libdispatch's main queue from GLib's
  loop so the view models' `DispatchQueue.main` hops work unchanged). The rest
  is one file per pane.

Both front ends draw the graph from `GraphRowDrawing` in `Graph/` — lane
positions, bezier control points, palette. Change the geometry there, not in a
front end, or the two will drift.

## Conventions

- Follow standard Swift API Design Guidelines; one type per file; file name
  matches the primary type.
- Parsers and the graph layout stay **pure and side-effect free** so the unit
  tests can cover them exhaustively. If you change git output formats, extend
  `GitParsersTests` and the end-to-end `GitIntegrationTests`.
- No force-unwraps outside tests.
- Every mutating repo operation goes through `RepoViewModel.perform` so the UI
  stays consistent (activity spinner → refresh → error banner).
- Secrets only ever go into the system secret store — the Keychain, or the
  Secret Service on Linux. Never log or persist API keys, and never fall back
  to a plain file when the secret store is unavailable.
- The core must not know which front end is attached. It has no GTK or SwiftUI
  imports, and it publishes state the same way for both.
- **Nothing outside `Platform/` imports AppKit or Security.** A core file that
  needs the desktop (open a URL, trash a file, find an application) grows a
  `Platform` call instead; `#if canImport(AppKit)` belongs in `Platform/`,
  `Tools/MergeTool.swift` and the UI.

## Critical Constraints

- **Never run git interactively**: the shell sets `GIT_TERMINAL_PROMPT=0` and
  `GIT_EDITOR=true`; commands must fail fast rather than block on prompts.
- **Serial git access per repo**: all GitClient calls for a repo run on its
  view model's serial queue. Don't call GitClient from the main thread.
- **Long-running external processes never run on the repo queue**: merge tools
  (opendiff & co. block until the app quits) run detached on a global queue and
  refresh on exit. A blocking call on the serial queue jams every repo op
  behind it.
- Untracked-file "discard" moves to the Trash (recoverable), never unlink.
- Don't add dependencies. Don't add telemetry.

## Testing Notes

- `GitParsersTests` — porcelain v2, log, refs, stash, name-status, quoted paths.
- `GraphLayoutTests` — linear, diamond merge, octopus, convergence, lane reuse.
- `ForgeRepoTests` / `PullRequestFinderTests` — remote-URL parsing and the
  per-forge website/API URL shapes (GitHub, Forgejo/Gitea, GitLab, generic).
- `RepoDiscoveryTests` / `RepoStoreTests` — watch-folder scanning (depth,
  hidden/package dirs, repo boundaries, visited cap) and the "removal sticks"
  exclusion contract.
- `FreedesktopTrashTests` / `PlatformTests` — the Trash spec (records, naming,
  volume trashes), helper processes, PATH lookup, XDG directories and merge-tool
  detection. Platform-independent, so they run in both builds.
- `LinuxFoundationShimTests` — the `ObservableObject`/`@Published`/`move`
  stand-ins. Compiled out on macOS, where the real implementations apply.
- `GitIntegrationTests` — builds a real repo in a temp dir and drives
  GitClient end to end (staging, merging, conflicts, stash). Runs in CI on both
  macos-14 and Ubuntu, where git exists.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Completion checklist

- The requested behavior is implemented without unrelated changes.
- Relevant checks pass for the latest code.
- Important review findings are addressed or rejected with reasons.
- Deferred suggestions, remaining risks, and validation gaps are disclosed.
- The final response accurately states whether work is committed, pushed,
  and merged.

<!-- shared-rules:end -->
