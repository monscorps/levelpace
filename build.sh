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
# server.txt: the address lives in the committed template, the TOKEN does not.
# A file called .token at the repo root (gitignored) is injected right after
# the address line, so the distributed folder carries the secret while git
# never sees it -- and a rebuild cannot silently drop it either.
if [ -f .token ]; then
  awk -v tok="$(head -1 .token | tr -d '\r\n')" '
    !inserted && NF && $0 !~ /^#/ { print; print tok; inserted=1; next }
    { print }
  ' packaging/server.txt > "$LB/server.txt"
  echo "  server.txt: token injected"
else
  cp packaging/server.txt "$LB/server.txt"
  echo "  server.txt: NO token (create .token at the repo root if the server needs one)"
fi
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
# ---- the one file a player runs ---------------------------------------------
# A batch file that reads ITSELF, finds the marker, and executes the
# PowerShell that follows. `exit /b` means cmd never parses past the marker,
# so one file is both a launcher and its own payload -- no extraction, no
# temp file, nothing to install.
#
# The marker is searched for as '#PS'+'START' rather than the literal, and that
# is load-bearing, not style. Written literally, the launcher line CONTAINS the
# marker, so IndexOf finds its own occurrence: PowerShell then receives the
# rest of the launcher line (harmless, it starts with #) followed by `exit /b`
# -- and `exit` is a PowerShell keyword. The session quits on line two, the
# tray icon never appears, and the window just flashes and closes. Splitting
# the literal means the only real '#PSSTART' in the file is the marker.
COMPANION="$LB/LevelPace Companion.bat"
{
  printf '@echo off\r\n'
  printf 'REM ==========================================================================\r\n'
  printf 'REM  LevelPace Companion -- double-click this. That is the whole instruction.\r\n'
  printf 'REM\r\n'
  printf 'REM  It puts an icon in your notification area (bottom-right, maybe under the\r\n'
  printf 'REM  ^ arrow) and uploads your stats by itself whenever you log out of WoW.\r\n'
  printf 'REM  Right-click the icon to upload now, open the board, or quit.\r\n'
  printf 'REM\r\n'
  printf 'REM  Nothing is installed. It uses the PowerShell already in Windows.\r\n'
  printf 'REM ==========================================================================\r\n'
  printf 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -Command "try{$s=[IO.File]::ReadAllText(\x27%%~f0\x27);iex ($s.Substring($s.IndexOf(\x27#PS\x27+\x27START\x27)))}catch{[IO.File]::WriteAllText($env:TEMP+\x27\\LevelPace-startup-error.txt\x27,$_.Exception.ToString())}"\r\n'
  printf 'exit /b\r\n'
  printf '#PSSTART\r\n'
  perl -pe 's/\r?\n/\r\n/' uploader/Companion.ps1
} > "$COMPANION"
echo "  built companion: $(basename "$COMPANION")"

# Verify the weld. This shipped broken once and nothing about it was visible
# from a Mac, so it is a build gate rather than something to remember.
PWSH="$(command -v pwsh || echo "$HOME/.local/pwsh/pwsh")"
if [ -x "$PWSH" ]; then
  if ! "$PWSH" -NoProfile -File tools/verify-companion.ps1 "$COMPANION"; then
    echo "  ! the companion launcher is broken -- refusing to build a zip" >&2
    exit 1
  fi
else
  echo "  ! pwsh not found: the companion is NOT verified." >&2
  echo "    Install it (no sudo needed) with:" >&2
  echo "      curl -fsSL -o /tmp/p.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-osx-arm64.tar.gz" >&2
  echo "      mkdir -p ~/.local/pwsh && tar zxf /tmp/p.tar.gz -C ~/.local/pwsh && chmod +x ~/.local/pwsh/pwsh" >&2
fi

( cd "$OUT" && zip -qr LevelPace-Leaderboard.zip LevelPace-Leaderboard )
echo "built $OUT/LevelPace-Leaderboard.zip"
unzip -l "$OUT/LevelPace-Leaderboard.zip" | tail -16
