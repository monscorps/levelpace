#!/bin/bash
# Import SavedVariables files a friend sent you.
#
# Drop their LevelPace.lua into the "inbox" folder next to this script (any
# subfolders are fine — one per friend keeps it tidy) and double-click.
# They install nothing but the addon.
cd "$(dirname "$0")" || exit 1
mkdir -p inbox

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is not installed. Run:  xcode-select --install"
  read -r -p "Press return to close." _
  exit 1
fi

count=$(find inbox -name 'LevelPace.lua' 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" = "0" ]; then
  echo
  echo "  Nothing in the inbox folder."
  echo
  echo "  Ask your friend for this file:"
  echo "    <their WoW folder>\\WTF\\Account\\<ACCOUNT>\\SavedVariables\\LevelPace.lua"
  echo
  echo "  Drop it into:  $(pwd)/inbox"
  echo "  Then run this again."
  echo
  read -r -p "Press return to close." _
  exit 0
fi

echo
echo "  Importing $count file(s) from the inbox..."
echo
python3 "server/levelpace_server.py" --db "levelpace.db" --import inbox
echo
read -r -p "Press return to close." _
