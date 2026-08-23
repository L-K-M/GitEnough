# CI/CD — building, testing & releasing GitEnough

GitEnough ships via **GitHub Actions** on macOS runners, same shape as its
sibling apps (Zap, Jetty, TopDrawer):

| Workflow | Trigger | What it does |
|---|---|---|
| [`ci.yml`](workflows/ci.yml) | every pull request + push to `main` | Two jobs. **Build & Test** (`macos-14`): `xcodebuild clean test` with **no code signing** — builds the app and runs the XCTest suite (parsers, graph layout, and a full end-to-end test that builds a real repo in a temp dir). **Core + GTK (Ubuntu)** (`swift:6.2.1-noble`): `swift build` + `swift test` for the platform-independent library, then builds the GTK 4 front end, so neither half of the Linux port can rot |
| [`release.yml`](workflows/release.yml) | pushing a `v*` tag | Release build **without Developer ID signing**, ad-hoc signed so it launches on Apple Silicon, packaged as **DMG + zip**, published as a GitHub Release, then **byte-verified** by re-downloading the assets |
| [`zai-code-review.yml`](workflows/zai-code-review.yml) | PR opened/synchronized | Reviews the diff with **Z.AI GLM** (`L-K-M/zai-code-review`, needs the `ZAI_API_KEY` repo secret; no-op without it) |

Both macOS jobs run on `macos-14` with a **pinned Xcode** (`16.2`), the Linux
job runs in a **pinned official Swift image**, and every third-party action is
**pinned to a commit SHA**. There are no third-party Swift dependencies, so
there's nothing to cache.

> The Linux job builds the SwiftPM package (`Package.swift`): the core library,
> its tests, and the `gitenough-gtk` executable. Releases are still macOS-only —
> Linux users build from source.

> **Signing/notarization is intentionally off.** Releases are not signed with a
> Developer ID and not notarized — no certificates or secrets needed. Users
> right-click → Open once (the release notes say so), or strip the quarantine
> attribute. See the Zap repo's CICD.md for how to add Developer ID later.

## Cutting a release

```bash
scripts/release.sh 0.2.0 --push
```

The stub (`scripts/release.sh`) execs the shared `lkm-release` engine: bump
`MARKETING_VERSION` in the pbxproj + the README `<!-- version -->` marker,
commit, tag `v0.2.0`, push branch + tag. The tag push triggers `release.yml`;
CI derives the version from the tag.

To redo a botched release, delete the tag and the Release on GitHub, then re-tag.

## Local builds

```bash
scripts/build.sh            # incremental Release build → reveal in Finder
scripts/build.sh --clean    # reset wedged Xcode daemons, wipe build/, rebuild
scripts/build.sh --check    # print the resolved config, build nothing
```

The core library, on macOS or Linux — the same suite CI's Ubuntu job runs:

```bash
swift build && swift test
```

The Linux app (needs `libgtk-4-dev`):

```bash
swift build -c release --product gitenough-gtk
```

`scripts/build.sh` is a stub for the shared `lkm-build` engine
(<https://github.com/L-K-M/release-tool>).
