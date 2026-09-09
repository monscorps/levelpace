#!/usr/bin/env bash
# Package LevelPace for a Windows WoW 3.3.5a client.
# Lua is platform-independent; this just converts line endings to CRLF so the
# files open cleanly in Notepad, and zips with the folder at the root.
set -euo pipefail
cd "$(dirname "$0")"
OUT=dist

# The TOC is the single source of truth for the version; release.sh bumps it
# before calling this. The companion used to carry its own hardcoded copy that
# nobody ever bumped, so every log line it wrote claimed 0.4.0 regardless of
# the build -- which made a real user's log impossible to place.
VERSION=$(sed -n 's/^## Version:[[:space:]]*//p' LevelPace/LevelPace.toc | tr -d '\r')
: "${VERSION:=dev}"
echo "  version: $VERSION"

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
# The bundle is two launchers, their config, and two text files. It used to
# ship the retired local server, the old uploader scripts and a START-HERE
# that told players to run them -- three programs nobody should run any more,
# inside the zip described as "the one file you double-click".
cp packaging/START-HERE.txt "$LB/START-HERE.txt"
cp packaging/FOR-YOUR-MATES.txt "$LB/FOR-YOUR-MATES.txt"
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
# CRLF for the files a Windows user will actually open in Notepad
for f in "$LB/START-HERE.txt" "$LB/FOR-YOUR-MATES.txt" \
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
  printf 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -Command "$env:LEVELPACE_BAT=\x27%%~f0\x27;try{$s=[IO.File]::ReadAllText($env:LEVELPACE_BAT);iex ($s.Substring($s.IndexOf(\x27#PS\x27+\x27START\x27)))}catch{[IO.File]::WriteAllText($env:TEMP+\x27\\LevelPace-startup-error.txt\x27,$_.Exception.ToString())}"\r\n'
  printf 'exit /b\r\n'
  printf '#PSSTART\r\n'
  # Stamp the real version in. It used to be hardcoded in the script and
  # never bumped, so every log line claimed 0.4.0 whatever build wrote it.
  sed "s/@@VERSION@@/$VERSION/" uploader/Companion.ps1 | perl -pe 's/\r?\n/\r\n/'
} > "$COMPANION"
echo "  built companion: $(basename "$COMPANION")"

# A second launcher that shows everything. When the normal one "flashes and
# closes" there is nothing to look at: -WindowStyle Hidden hides the window and
# a crash takes the console with it. This one keeps the window open and prints
# the error, which turns "it did not work" into something actionable.
DEBUG_BAT="$LB/LevelPace Companion (SHOW ERRORS).bat"
{
  printf '@echo off\r\n'
  printf 'REM ==========================================================================\r\n'
  printf 'REM  Only run this if the normal launcher did nothing.\r\n'
  printf 'REM\r\n'
  printf 'REM  Same program, but the window STAYS OPEN and prints what went wrong.\r\n'
  printf 'REM  Copy everything you see and send it back.\r\n'
  printf 'REM ==========================================================================\r\n'
  printf 'echo Starting LevelPace Companion with errors visible...\r\n'
  printf 'echo.\r\n'
  printf 'powershell -NoProfile -ExecutionPolicy Bypass -STA -NoExit -Command "$env:LEVELPACE_BAT=\x27%%~f0\x27;$ErrorActionPreference=\x27Continue\x27;Write-Host (\x27PowerShell \x27 + $PSVersionTable.PSVersion.ToString()) -Foreground Cyan;try{$s=[IO.File]::ReadAllText($env:LEVELPACE_BAT);$i=$s.IndexOf(\x27#PS\x27+\x27START\x27);Write-Host (\x27marker at \x27 + $i) -Foreground Cyan;iex ($s.Substring($i))}catch{Write-Host \x27=== FAILED ===\x27 -Foreground Red;$e=$_.Exception;while($e){Write-Host ($e.GetType().Name + \x27: \x27 + $e.Message) -Foreground Red;$e=$e.InnerException};Write-Host (\x27at line \x27 + $_.InvocationInfo.ScriptLineNumber) -Foreground Yellow;Write-Host $_.InvocationInfo.Line -Foreground Yellow}"\r\n'
  printf 'exit /b\r\n'
  printf '#PSSTART\r\n'
  sed "s/@@VERSION@@/$VERSION/" uploader/Companion.ps1 | perl -pe 's/\r?\n/\r\n/'
} > "$DEBUG_BAT"
echo "  built debug launcher: $(basename "$DEBUG_BAT")"

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
