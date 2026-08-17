#!/usr/bin/env bash
# Cuts a release: bumps the version, commits, tags "v<version>", and with --push
# pushes branch + tag — which triggers .github/workflows/release.yml to build,
# package (.zip + .dmg), and publish the GitHub Release. CI derives the released
# version from the tag, so the tag is the source of truth — this just keeps the
# committed MARKETING_VERSION and the README version line in step so *local/dev*
# builds report the same number.
#
#   scripts/release.sh 0.2.0          # bump MARKETING_VERSION + README, commit, tag v0.2.0
#   scripts/release.sh 0.2.0 --push   # …also push the commit + tag (CI then publishes)
#   scripts/release.sh                # tag the current MARKETING_VERSION as-is
#
# Usage: scripts/release.sh [X.Y[.Z]] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail

export RELEASE_APP_NAME="GitEnough"
export RELEASE_KIND="xcode"
export RELEASE_XCODE_PROJECT="GitEnough.xcodeproj"
export RELEASE_XCODE_SCHEME="GitEnough"
export RELEASE_CI_NOTE="CI (release.yml) will now build, package (.zip + .dmg), and publish the GitHub Release for the tag."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
