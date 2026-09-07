#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
if ! command -v luajit >/dev/null 2>&1; then
  echo "luajit is required: the target client is Lua 5.1 and system lua is 5.5," >&2
  echo "whose unpack/# /integer-division semantics differ and would mask bugs." >&2
  exit 2
fi
ver=$(luajit -e 'io.write(_VERSION)')
if [ "$ver" != "Lua 5.1" ]; then
  echo "expected Lua 5.1 semantics, got '$ver'" >&2
  exit 2
fi
status=0
for t in tests/test_*.lua; do
  [ -e "$t" ] || continue
  echo "== $t"
  luajit "$t" || status=1
done
[ $status -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $status
