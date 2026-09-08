#!/bin/bash
# ============================================================================
#  Runs the whole thing on this Mac, for free.
#
#    server            on localhost:8080
#    quick tunnel      a public https URL, no domain, no account, no cost
#    publish           pushes the board AND the current tunnel URL to Pages
#
#  Cloudflare quick tunnels get a NEW URL every restart. That would normally
#  make them useless here, since the address is inside everyone's download --
#  so instead the address is published to GitHub Pages and the companion
#  looks it up. Restart this as often as you like; clients follow.
#
#  Leave this window open. Closing it stops both.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

PAGES_URL="${LEVELPACE_PAGES_URL:-https://monscorps.github.io/levelpace}"
DB="${LEVELPACE_DB:-server/levelpace.db}"
LOG=/tmp/levelpace-tunnel.log

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "cloudflared is not installed. Run:  brew install cloudflared"
  read -r -p "Press return to close." _
  exit 1
fi
if [ ! -f .token ]; then
  echo "No .token file. Create one:"
  echo "  python3 -c \"import secrets;print(secrets.token_urlsafe(24))\" > .token"
  read -r -p "Press return to close." _
  exit 1
fi

cleanup() {
  echo
  echo "  stopping..."
  [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
  [ -n "${TUN:-}" ] && kill "$TUN" 2>/dev/null
  exit 0
}
trap cleanup INT TERM

echo
# Something may already own the port -- most likely the launchd agent, which
# has KeepAlive set and will simply restart if killed. Reuse it rather than
# fight it: two servers on one database is worse than one we did not start.
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "  a server is already running on :8080 -- reusing it"
  echo "  (that is probably the launchd agent; this script does not need to"
  echo "   start its own. To use only this script instead, run:"
  echo "     launchctl unload -w ~/Library/LaunchAgents/com.levelpace.server.plist)"
  SRV=""
else
  echo "  starting server on :8080"
  LEVELPACE_TOKEN="$(cat .token)" \
    python3 server/levelpace_server.py --port 8080 --db "$DB" &
  SRV=$!
  sleep 2
  if ! kill -0 "$SRV" 2>/dev/null; then
    echo "  ! the server exited immediately. Check the error above."
    read -r -p "Press return to close." _
    exit 1
  fi
fi

echo "  opening a free tunnel (no domain needed)"
rm -f "$LOG"
cloudflared tunnel --url http://localhost:8080 --no-autoupdate > "$LOG" 2>&1 &
TUN=$!

# The URL only appears in cloudflared's output, so wait for it.
URL=""
for _ in $(seq 1 30); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | head -1)
  [ -n "$URL" ] && break
  sleep 1
done

if [ -z "$URL" ]; then
  echo
  echo "  ! the tunnel did not report a URL. Last output:"
  tail -20 "$LOG"
  cleanup
fi

echo
echo "  public address: $URL"
echo

# Publish the board AND this address, so every companion picks it up.
LEVELPACE_UPLOAD_URL="$URL" \
  python3 server/levelpace_server.py --db "$DB" --publish docs --base-url "$PAGES_URL"

if git rev-parse --git-dir >/dev/null 2>&1; then
  git add docs
  if git diff --cached --quiet; then
    echo "  (board unchanged)"
  else
    git commit -q -m "chore: publish board and upload address $(date -u +%Y-%m-%dT%H:%MZ)"
    git push -q 2>/dev/null && echo "  pushed -- clients will pick up the new address within a minute" \
      || echo "  ! push failed; run 'git push' yourself"
  fi
fi

echo
echo "  Everything is up. Your mates need nothing but the addon and the companion."
echo "  Board: $PAGES_URL"
echo
echo "  Leave this window open. Ctrl-C or close it to stop."
echo

# Re-publish periodically so new submissions reach the board, and so a
# restarted tunnel's address gets out.
while true; do
  sleep 3600
  LEVELPACE_UPLOAD_URL="$URL" \
    python3 server/levelpace_server.py --db "$DB" --publish docs --base-url "$PAGES_URL" >/dev/null 2>&1
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git add docs
    git diff --cached --quiet || {
      git commit -q -m "chore: hourly board publish $(date -u +%Y-%m-%dT%H:%MZ)"
      git push -q 2>/dev/null
    }
  fi
  echo "  [$(date '+%H:%M')] republished"
done
