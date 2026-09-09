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

echo "==> stamping docs/api/version.json"
# The companion copies this into the addon folder, and the addon prints
# "version X is available" from it. It used to be whatever the retired local
# server last wrote, which was 0.5.0 forever.
python3 - "$VERSION" <<'EOF'
import json, sys, time
p = "docs/api/version.json"
with open(p, "w") as f:
    json.dump({"addonVersion": sys.argv[1],
               "downloadUrl": "https://github.com/monscorps/levelpace/releases/latest",
               "published": int(time.time())}, f, indent=2)
    f.write("\n")
EOF
cat docs/api/version.json

echo "==> build"
./build.sh >/dev/null
ls -la dist/*.zip

echo "==> commit and tag"
git add LevelPace/LevelPace.toc docs/api/version.json
git commit -q -m "chore: release v$VERSION"
git tag -a "v$VERSION" -m "LevelPace v$VERSION"
git push -q && git push -q --tags

echo "==> GitHub release"
if ! command -v gh >/dev/null 2>&1; then
  echo "gh not installed; tag pushed but no release created." >&2
  exit 0
fi

# The release page IS the link you hand out, so the notes matter more than
# usual -- most people will never see the README. RELEASE_NOTES.md is written
# for a player, not a developer; edit it before each release.
NOTES_FILE="RELEASE_NOTES.md"
if [ ! -f "$NOTES_FILE" ]; then
  echo "no $NOTES_FILE -- the release page would be blank" >&2
  exit 1
fi

# GitHub attaches "Source code (zip)" and "Source code (tar.gz)" to every
# release automatically and there is no way to remove them. So the two files
# that matter have to WIN on name alone -- someone scanning four downloads
# should not have to think. The old names lost that contest badly:
# "LevelPace-Leaderboard.zip" was actually the uploader, not the leaderboard.
rm -rf dist/upload && mkdir -p dist/upload
cp dist/LevelPace.zip             "dist/upload/1-ADDON-LevelPace.zip"
cp dist/LevelPace-Leaderboard.zip "dist/upload/2-UPLOADER-LevelPace-Companion.zip"

gh release create "v$VERSION" \
  "dist/upload/1-ADDON-LevelPace.zip" \
  "dist/upload/2-UPLOADER-LevelPace-Companion.zip" \
  --title "LevelPace v$VERSION" \
  --notes-file "$NOTES_FILE"

echo
echo "done. Stable link for everyone:"
echo "  https://github.com/monscorps/levelpace/releases/latest"
echo
echo "Publish the board so clients see the new version number:"
echo "  ./publish-to-pages.command"
