#!/usr/bin/env bash
# ============================================================================
#  Import a player's LevelPace.lua directly to the board.
#
#  This is the FALLBACK. The normal path is their own companion, and it is
#  better for a reason that matters:
#
#      The first installation to submit a character OWNS it.
#
#  So if you import someone's data with your key, YOUR installation owns their
#  character, and their own companion will be refused from then on with
#  "already claimed by another installation". You would then have to reassign
#  it by hand (the command is printed at the end).
#
#  Use this when their companion cannot be made to work and you want their
#  history on the board anyway.
#
#  Usage:  tools/import-savedvariables.sh <path-to-LevelPace.lua>
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

SV="${1:-}"
if [ -z "$SV" ] || [ ! -f "$SV" ]; then
  echo "usage: tools/import-savedvariables.sh <path-to-LevelPace.lua>" >&2
  echo >&2
  echo "That file lives in their WoW install at:" >&2
  echo "  WTF\\Account\\<ACCOUNT>\\SavedVariables\\LevelPace.lua" >&2
  exit 1
fi

API="$(curl -s -m 20 https://monscorps.github.io/levelpace/api/config.json \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["uploadUrl"])')"
if [ -z "$API" ]; then
  echo "could not read the upload address from the published config" >&2
  exit 1
fi
echo "board API: $API"

# The addon writes the whole export as one JSON string precisely so a reader
# needs a regex rather than a Lua parser.
BLOB=$(python3 - "$SV" <<'PY'
import re, sys, json
src = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'\["?exportJSON"?\]\s*=\s*"(.*?)"\s*,?\s*\n', src, re.S)
if not m:
    m = re.search(r'exportJSON\s*=\s*"(.*?)"\s*,?\s*\n', src, re.S)
if not m:
    sys.stderr.write("no exportJSON found in that file.\n"
                     "Sharing was probably never switched on. Have them run:\n"
                     "    /lp share on\n"
                     "then /reload, then send the file again.\n")
    sys.exit(2)
raw = m.group(1)
# Lua escapes it the same way JSON does, so one unescape pass is enough.
raw = raw.encode('utf-8').decode('unicode_escape')
try:
    json.loads(raw)
except Exception as e:
    sys.stderr.write("found exportJSON but it is not valid JSON: %s\n" % e)
    sys.exit(3)
print(raw)
PY
) || exit $?

echo "$BLOB" | python3 -c "
import json,sys
d = json.load(sys.stdin)
blobs = d if isinstance(d, list) else [d]
for b in blobs:
    print('  %s-%s: %d level(s), %d rare kill(s)' % (
        b.get('name','?'), b.get('realm','?'),
        len(b.get('levels') or []), len(b.get('rares') or [])))
"

read -r -p "Import this to the board? [y/N] " yn
case "$yn" in [Yy]*) ;; *) echo "cancelled"; exit 0 ;; esac

KEY_FILE=".import.key"
if [ -f "$KEY_FILE" ]; then
  KEY=$(cat "$KEY_FILE")
else
  KEY=$(curl -s -m 20 -X POST "$API/api/enrol" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["key"])')
  [ -n "$KEY" ] && printf '%s' "$KEY" > "$KEY_FILE" && chmod 600 "$KEY_FILE"
  echo "enrolled an import key (kept in $KEY_FILE, gitignored)"
fi

echo "$BLOB" | curl -s -m 60 -X POST \
  -H "authorization: Bearer $KEY" \
  -H 'content-type: application/json' \
  --data-binary @- "$API/api/submit" | python3 -m json.tool

cat <<'NOTE'

Done. Remember what this cost:

  That character is now owned by THIS machine's import key, so their own
  companion will be refused. To hand it back once their companion works,
  find their install id and reassign:

    npx wrangler d1 execute levelpace --remote \
      --command "SELECT char_id, name, owner_install FROM characters"
    npx wrangler d1 execute levelpace --remote \
      --command "UPDATE characters SET owner_install='<their-install-id>' WHERE char_id='<char-id>'"
NOTE
