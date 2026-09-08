#!/bin/bash
# LevelPace leaderboard server — double-click to host from this Mac.
cd "$(dirname "$0")" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is not installed. Run:  xcode-select --install"
  read -r -p "Press return to close." _
  exit 1
fi

# Show every address a friend could reach this Mac on.
echo
echo "  LevelPace leaderboard server"
echo "  ----------------------------"
echo "  On this Mac:   http://localhost:8080"
for ip in $(ipconfig getifaddr en0 2>/dev/null) $(ipconfig getifaddr en1 2>/dev/null); do
  echo "  On your LAN:   http://$ip:8080"
done
if command -v tailscale >/dev/null 2>&1; then
  ts=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$ts" ] && echo "  Via Tailscale: http://$ts:8080   <- give your friend this one"
fi
echo
echo "  This Mac must stay awake and this window must stay open."
echo "  Close the window to stop the server."
echo

python3 "server/levelpace_server.py" --port 8080 --db "levelpace.db"
read -r -p "Server stopped. Press return to close." _
