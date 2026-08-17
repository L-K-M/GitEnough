# CI/CD — building, testing & releasing GitEnough

GitEnough ships via **GitHub Actions** on macOS runners, same shape as its
sibling apps (Zap, Jetty, TopDrawer):

| Workflow | Trigger | What it does |
|---|---|---|
| [`ci.yml`](workflows/ci.yml) | every pull request + push to `main` | `xcodebuild clean test` with **no code signing** — builds the app and runs the XCTest suite (parsers, graph layout, and a full end-to-end test that builds a real repo in a temp dir) |
| [`release.yml`](workflows/release.yml) | pushing a `v*` tag | Release build **without Developer ID signing**, ad-hoc signed so it launches on Apple Silicon, packaged as **DMG + zip**, published as a GitHub Release, then **byte-verified** by re-downloading the assets |
| [`zai-code-review.yml`](workflows/zai-code-review.yml) | PR opened/synchronized | Reviews the diff with **Z.AI GLM** (`L-K-M/zai-code-review`, needs the `ZAI_API_KEY` repo secret; no-op without it) |

Both macOS jobs run on `macos-14` with a **pinned Xcode** (`16.2`), and every
third-party action is **pinned to a commit SHA**. There are no third-party
Swift dependencies, so there's nothing to cache.

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

`scripts/build.sh` is a stub for the shared `lkm-build` engine
(<https://github.com/L-K-M/release-tool>).
