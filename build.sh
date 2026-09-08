#!/usr/bin/env bash
# Package LevelPace for a Windows WoW 3.3.5a client.
# Lua is platform-independent; this just converts line endings to CRLF so the
# files open cleanly in Notepad, and zips with the folder at the root.
set -euo pipefail
cd "$(dirname "$0")"
OUT=dist
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R LevelPace "$OUT/LevelPace"
# The player-facing guide ships INSIDE the addon zip too, because that is the
# download someone opens first.
cp packaging/FOR-YOUR-MATES.txt "$OUT/LevelPace/READ-ME-FIRST.txt"
cp README.md "$OUT/LevelPace/README.txt"
# LF -> CRLF for every text file in the package
find "$OUT/LevelPace" -type f \( -name '*.lua' -o -name '*.toc' -o -name '*.txt' \) -print0 |
  while IFS= read -r -d '' f; do
    perl -pi -e 's/\r?\n/\r\n/' "$f"
  done
( cd "$OUT" && zip -qr LevelPace.zip LevelPace )
echo "built $OUT/LevelPace.zip"

# ---- leaderboard package -----------------------------------------------------
# Everything under ONE clearly-named top folder. Shipping loose server/ and
# uploader/ directories invited the reasonable question "which of these goes in
# my AddOns folder?" -- the answer is none of them, and the packaging should
# say so before anyone has to ask.
LB="$OUT/LevelPace-Leaderboard"
rm -rf "$LB" && mkdir -p "$LB"
cp -R server "$LB/server"
cp -R uploader "$LB/uploader"
cp server/README.md "$LB/README.md"
cp packaging/START-HERE.txt "$LB/START-HERE.txt"
cp packaging/FOR-YOUR-MATES.txt "$LB/FOR-YOUR-MATES.txt"
cp packaging/*.bat "$LB/"
cp packaging/*.command "$LB/" 2>/dev/null || true
cp packaging/server.txt "$LB/server.txt"
mkdir -p "$LB/inbox"
printf 'Drop a friend LevelPace.lua here (subfolders are fine), then run\nimport-inbox.command, or:\n\n  python3 server/levelpace_server.py --db levelpace.db --import inbox\n' > "$LB/inbox/PUT-FILES-HERE.txt"
chmod +x "$LB"/*.command 2>/dev/null || true
rm -rf "$LB"/server/__pycache__ "$LB"/uploader/__pycache__
find "$LB" -name '*.db' -delete
find "$LB" -name '*.db-wal' -delete
find "$LB" -name '*.db-shm' -delete
# CRLF for the files a Windows user will actually open in Notepad
for f in "$LB/START-HERE.txt" "$LB/FOR-YOUR-MATES.txt" "$LB/README.md" \
         "$LB/server.txt" "$LB"/*.bat "$OUT/LevelPace/READ-ME-FIRST.txt"; do
  [ -f "$f" ] && perl -pi -e 's/\r?\n/\r\n/' "$f"
done
# NOTE: no cleanup of an old lower-case "LevelPace-leaderboard.zip" here --
# macOS is case-insensitive, so removing it removes the one just built.
( cd "$OUT" && zip -qr LevelPace-Leaderboard.zip LevelPace-Leaderboard )
echo "built $OUT/LevelPace-Leaderboard.zip"
unzip -l "$OUT/LevelPace-Leaderboard.zip" | tail -16
