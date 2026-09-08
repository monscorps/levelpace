#!/bin/bash
# ============================================================================
#  Publish the leaderboard to GitHub Pages.
#
#  Writes the whole board out as flat files into docs/, commits, and pushes.
#  GitHub Pages then serves it on a real HTTPS URL that stays up whether or
#  not this machine is on.
#
#  This is the READ path. Uploads still go to the running server -- Pages is
#  static and cannot accept a POST.
#
#  One-time setup on GitHub:
#    Settings -> Pages -> Source: "Deploy from a branch"
#                         Branch: main,  Folder: /docs
#
#  Run this by hand, or on a schedule (see the bottom of this file).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

DB="${LEVELPACE_DB:-server/levelpace.db}"
OUT="docs"
BASE_URL="${LEVELPACE_PAGES_URL:-}"

# A missing database is NOT an error. Publishing an empty board is the right
# first move: it proves the whole path works -- publish, commit, push, Pages --
# before anyone has submitted anything, and the board renders an honest
# "nobody has posted a level yet" rather than looking broken.
if [ ! -f "$DB" ]; then
  echo
  echo "  No database at $DB yet, so this will publish an EMPTY board."
  echo "  That is worth doing: it gets GitHub Pages working end to end before"
  echo "  anyone submits. It fills in on the next publish after a real upload."
  echo
  mkdir -p "$(dirname "$DB")"
fi

echo
echo "  Publishing $DB -> $OUT/"
echo

python3 server/levelpace_server.py --db "$DB" --publish "$OUT" \
        ${BASE_URL:+--base-url "$BASE_URL"}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo
  echo "  Written to $OUT/, but this is not a git repository, so nothing was"
  echo "  pushed. Create the repo first."
  echo
  read -r -p "Press return to close." _
  exit 0
fi

# Only the published output. Deliberately narrow: this runs unattended on a
# schedule, and a blanket 'git add -A' would sweep up whatever else happened
# to be in the working tree.
git add "$OUT"

if git diff --cached --quiet; then
  echo
  echo "  No change since the last publish. Nothing to push."
  echo
else
  git commit -q -m "chore: publish leaderboard snapshot $(date -u +%Y-%m-%dT%H:%MZ)"
  if git push -q 2>/dev/null; then
    echo
    echo "  Pushed. GitHub Pages usually updates within a minute."
    [ -n "$BASE_URL" ] && echo "  $BASE_URL"
    echo
  else
    echo
    echo "  Committed, but the push failed. Check your remote and credentials:"
    echo "    git push"
    echo
  fi
fi

# ----------------------------------------------------------------------------
# To publish automatically every hour, run this once:
#
#   ( crontab -l 2>/dev/null; \
#     echo "0 * * * * cd '$(pwd)' && ./publish-to-pages.command >> /tmp/levelpace-publish.log 2>&1" \
#   ) | crontab -
#
# Remove it again with:  crontab -e
# ----------------------------------------------------------------------------

if [ -t 0 ]; then read -r -p "Press return to close." _; fi
