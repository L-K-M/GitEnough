# GitEnough

**Latest release:** v<!-- version -->0.1.0<!-- /version --> · [Download](https://github.com/L-K-M/GitEnough/releases/latest)

A native macOS git client that is *just good enough*: the everyday 95 % of GitHub
Desktop — clone, stage, commit, pull, push, branch, merge — with the two things
Desktop never gave you: a proper **IntelliJ-style branch/merge graph** and
**AI-written commit messages** from your staged diff.

> [!IMPORTANT]
> LLM Disclosure: GitEnough was built with substantial help from large language models. Much of the code arrived through AI-authored commits and `claude/*` pull-request branches, with agent guidance kept in [`AGENTS.md`](AGENTS.md)


## What it does

- **Two-pane window.** Repositories on the left (with live branch / dirty /
  ahead-behind summaries), the selected repository on the right. Drag any folder
  into the sidebar to add it; clone straight from a URL. Star the repos you
  care about — they pin to the top of the list in every sort order. Filter the
  list as you type, and sort it manually, by name, or by recently opened.
- **Watch folder.** Point Settings → General at a folder (say `~/code`) and
  GitEnough scans it about once a minute, automatically adding every repository
  it finds — directly inside, or one folder deep. Removing a repo from the
  sidebar keeps it out for good.
- **History graph.** A color-coded lane graph of `git log --all` — branch
  fan-outs, merge-ins, octopus merges, tag/branch/HEAD chips on the commits —
  with a detail pane (files changed, per-file diff) next to it. Context menus:
  create branch here, check out, cherry-pick, revert, reset (soft/mixed/hard).
- **Changes.** Staged/unstaged lists with one-click (un)staging, a per-file
  colored diff, discard-to-trash for untracked files, stash, and amend.
  **⌘↩ commits.**
- **Smart commits.** The ✨ Generate button sends the staged diff (stat + patch)
  to an OpenAI-compatible LLM endpoint — **Z.AI GLM** by default, OpenAI or any
  custom/self-hosted endpoint in Settings — and writes a conventional commit
  message for you. The model picker loads the provider's model list itself
  (with a manual text field as fallback), and the API key lives in the
  **Keychain**, never in plain text.
- **Merge conflicts.** A merge banner, per-file resolution (ours/theirs), and
  one click into your **external merge tool** — FileMerge, Kaleidoscope, Beyond
  Compare, Araxis, P4Merge, Meld, DeltaWalker, Sublime Merge and KDiff3 are
  auto-detected and driven through `git mergetool`. The tool never blocks the
  rest of the app; when it closes, GitEnough checks the file itself and stages
  it if the markers are gone.
- **Branches & stash.** Switch by double-click, create/rename/delete/merge from
  the context menu, tracking-checkouts for remote branches, stash apply/pop/drop.
- **Pull requests.** The toolbar button or ⌥⌘P opens the current branch's pull
  request on **GitHub**, **GitLab** or **Forgejo/Gitea** in your browser — or,
  when none is open yet, the forge's create-a-PR page. The lookup is an
  unauthenticated best-effort API call (no tokens involved); for private repos
  the create page is opened, where the forge shows an "already has a pull
  request" banner once you're signed in. Self-hosted remotes are auto-detected
  (Forgejo/Gitea's API is probed first, then GitLab's).

Under the hood GitEnough shells out to **your own git** (no libgit2, no bundled
fork): it behaves exactly like the command line you already know, respects your
config, hooks and credential helpers, and adds zero third-party dependencies.

## Requirements

- macOS 14 (Sonoma) or newer for the app itself. A Linux port is under way —
  see [Linux](#linux) below.
- The **Xcode Command Line Tools** (`xcode-select --install`) — that's where
  `git` comes from. GitEnough offers to install them on first launch if missing.
- For smart commit messages: an API key for [Z.AI](https://z.ai) (GLM), OpenAI,
  or any OpenAI-compatible endpoint.

## Install

Download `GitEnough-x.y.z.dmg` from
[Releases](https://github.com/L-K-M/GitEnough/releases/latest) and drag the app
to Applications. The CI build is ad-hoc signed but **not notarized**, so
Gatekeeper will warn on first launch: right-click → **Open** → **Open** (once),
or run `xattr -dr com.apple.quarantine /Applications/GitEnough.app`.

## Build from source

Requires Xcode 16+ (the project uses file-system–synchronized groups).

```bash
scripts/build.sh          # Release build, reveals GitEnough.app in Finder
scripts/build.sh --debug --run
xcodebuild -project GitEnough.xcodeproj -scheme GitEnough test   # run the tests
```

## Linux

GitEnough runs on Ubuntu with a **GTK 4** front end. Same core, same git
plumbing, same lane graph — a second way to look at it, not a second
implementation.

```bash
sudo apt install libgtk-4-dev libsecret-tools    # build deps + the keyring tool
swift build -c release --product gitenough-gtk   # Swift 6.0+; CI pins 6.2.1
.build/release/gitenough-gtk ~/code/myproject    # or launch with no arguments
```

The window is the two-pane shell you'd expect: repositories on the left,
History / Changes / Branches on the right, the lane graph drawn with Cairo, a
colour-coded diff beside the file lists, and the commit box with ✨ Generate.
Folders can be passed on the command line; GitEnough is single-instance, so
pointing a second launch at another folder opens it in the running window.

`Package.swift` builds the core library out of the same directories the Xcode
project uses — only `GitEnough/UI/` (SwiftUI, macOS-only) is left out — and the
GTK front end lives in `Linux/`. Where the core needs the desktop it goes
through `GitEnough/Platform/`: `xdg-open` for links, the freedesktop.org Trash
spec for discarded untracked files, libsecret's `secret-tool` for the API key,
and merge-tool detection that looks for Meld, KDiff3, Kompare, Diffuse and
friends on `PATH`.

There are no SwiftPM dependencies on Linux either: GTK is reached as a system
library through `pkg-config`, the same trade the app already makes by shelling
out to `git` instead of linking libgit2.

The core on its own needs nothing but the toolchain — useful on a server or in a
CI job that only wants the tests:

```bash
GITENOUGH_NO_GTK=1 swift test    # drops the front end from the package
```

Not yet ported from the macOS UI: Settings (configure the LLM endpoint on macOS,
or by hand), the watch folder, drag-and-drop reordering, cherry-pick/revert/
reset context menus, and merge-conflict resolution. The core supports all of
them — they just have no GTK surface yet.

## Releasing

```bash
scripts/release.sh 0.2.0 --push   # bump, commit, tag, push → CI builds the release
```

Pushing a `v*` tag builds the app unsigned-but-ad-hoc-signed, packages DMG + zip,
publishes the GitHub Release, and byte-verifies the uploaded assets. See
[CICD.md](CICD.md).

## Privacy

GitEnough talks to exactly two kinds of hosts: your git remotes (via `git`
itself, with your own credentials) and the configured LLM endpoint only when
you explicitly press ✨ Generate, Load Models, or Test Connection. Generate and
Test Connection send diff text; Load Models requests the provider's model list.
Simply opening Settings makes no request. API keys are stored in the macOS
Keychain — or, on Linux, the system keyring via the Secret Service; GitEnough
never writes a key to a file. There is no telemetry, no analytics, no crash
reporting.
