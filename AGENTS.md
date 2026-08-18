# AGENTS.md

Guidance for AI coding agents working in the **GitEnough** repository.

## What GitEnough Is

GitEnough is a native macOS git client — the everyday 95 % of GitHub Desktop
(fetch, pull, push, branch, merge, stash, commit) with an IntelliJ-style
branch/merge history graph and LLM-written commit messages.

## Tech Stack

- **Language:** Swift (latest stable), macOS 14+ deployment target.
- **UI:** SwiftUI (NavigationSplitView two-pane shell, Canvas for the graph),
  AppKit where needed (NSWorkspace, NSPasteboard, NSOpenPanel).
- **Git:** shells out to the user's own `git` binary (GitShell/GitClient) — no
  libgit2, no bundled git. Arguments are always passed as arrays, never through
  a shell; `--` separates pathspecs from revisions; read-only queries pass
  `--no-optional-locks`.
- **LLM:** OpenAI-compatible chat-completions client (Z.AI GLM default). API key
  in the Keychain via KeychainStore; everything else in UserDefaults.
- **Dependencies:** none. Zero third-party packages; keep it that way.

## Build & Run

The Xcode project uses Xcode 16 file-system–synchronized groups, so new files
added under `GitEnough/` or `GitEnoughTests/` are picked up automatically — no
`project.pbxproj` edits needed. **Requires Xcode 16+.**

`scripts/build.sh` builds and reveals the app (stub for the shared `lkm-build`
engine). Or directly:

```bash
xcodebuild -project GitEnough.xcodeproj -scheme GitEnough -configuration Debug build
xcodebuild -project GitEnough.xcodeproj -scheme GitEnough -destination 'platform=macOS' test
```

## Layout

- `GitEnough/Git/` — GitShell (process runner), GitClient (typed ops),
  GitParsers (pure, tested), DiffParser, models.
- `GitEnough/Graph/` — GraphLayout: the lane-assignment algorithm for the
  history graph (pure, tested). Input must be newest-first topo-ordered.
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
- `GitEnough/Tools/` — MergeTool detection (git mergetool integration).
- `GitEnough/UI/` — SwiftUI views. `GraphMetrics` ties the graph Canvas and the
  commit list rows to the same row height — keep them in sync.

## Conventions

- Follow standard Swift API Design Guidelines; one type per file; file name
  matches the primary type.
- Parsers and the graph layout stay **pure and side-effect free** so the unit
  tests can cover them exhaustively. If you change git output formats, extend
  `GitParsersTests` and the end-to-end `GitIntegrationTests`.
- No force-unwraps outside tests.
- Every mutating repo operation goes through `RepoViewModel.perform` so the UI
  stays consistent (activity spinner → refresh → error banner).
- Secrets only ever go into the Keychain. Never log or persist API keys.

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
- `GitIntegrationTests` — builds a real repo in a temp dir and drives
  GitClient end to end (staging, merging, conflicts, stash). Runs in CI on
  macos-14 where git exists.
