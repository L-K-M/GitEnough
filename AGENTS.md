# AGENTS.md

Guidance for AI coding agents working in the **GitEnough** repository.

## What GitEnough Is

GitEnough is a native macOS git client — the everyday 95 % of GitHub Desktop
(fetch, pull, push, branch, merge, stash, commit) with an IntelliJ-style
branch/merge history graph and LLM-written commit messages.

Everything below the UI also builds and tests on Linux as a SwiftPM library
(see **Two builds** below); the SwiftUI front end is still macOS-only.

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
| Builds | the whole app, macOS | `GitEnough` library — everything except `UI/` |
| Platforms | macOS 14+ | macOS and Linux |
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
swift build
swift test
```

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
  The graph Canvas and the commit list rows share `GraphMetrics` (in `Graph/`)
  so their row heights stay in sync.

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
