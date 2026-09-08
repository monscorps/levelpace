#!/usr/bin/env bash
# ============================================================================
#  Cut a release.
#
#    ./release.sh 0.4.0
#
#  Bumps the version in the TOC (the single source of truth), runs the tests,
#  builds both zips, tags, and publishes a GitHub Release.
#
#  Why this matters more than it looks: without a stable download link you end
#  up messaging zips to ten people and half of them stay on an old build,
#  comparing numbers that were computed differently. One link fixes that, and
#  the addon tells people when they are behind it.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  CURRENT=$(sed -n 's/^## Version:[[:space:]]*//p' LevelPace/LevelPace.toc)
  echo "usage: ./release.sh <version>     (current: ${CURRENT:-unknown})"
  exit 1
fi

if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "version must look like 1.2.3 -- the addon compares these numerically" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty. Commit or stash first:" >&2
  git status --short >&2
  exit 1
fi

echo "==> tests"
./tests/run.sh

echo "==> bumping TOC to $VERSION"
# The TOC is the one place the version lives; Core.lua reads it back out with
# GetAddOnMetadata, and the server publishes it from here too.
perl -pi -e "s/^## Version:.*/## Version: $VERSION/" LevelPace/LevelPace.toc
grep '^## Version:' LevelPace/LevelPace.toc

echo "==> build"
./build.sh >/dev/null
ls -la dist/*.zip

echo "==> commit and tag"
git add LevelPace/LevelPace.toc
git commit -q -m "chore: release v$VERSION"
git tag -a "v$VERSION" -m "LevelPace v$VERSION"
git push -q && git push -q --tags

echo "==> GitHub release"
if ! command -v gh >/dev/null 2>&1; then
  echo "gh not installed; tag pushed but no release created." >&2
  exit 0
fi

gh release create "v$VERSION" \
  dist/LevelPace.zip \
  dist/LevelPace-Leaderboard.zip \
  --title "LevelPace v$VERSION" \
  --notes "$(cat <<NOTES
**LevelPace.zip** — the addon. Extract into \`Interface\\AddOns\\\` so you get
\`Interface\\AddOns\\LevelPace\\LevelPace.toc\`.

**LevelPace-Leaderboard.zip** — server and uploader. Not an addon; put it
anywhere. Only needed if you are sending stats to a board or hosting one.

See the [README](https://github.com/monscorps/levelpace#readme).
NOTES
)"

echo
echo "done. Stable link for everyone:"
echo "  https://github.com/monscorps/levelpace/releases/latest"
echo
echo "Publish the board so clients see the new version number:"
echo "  ./publish-to-pages.command"
