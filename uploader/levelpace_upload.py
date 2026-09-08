#!/usr/bin/env python3
"""
LevelPace uploader.

The WoW addon cannot use the network -- the Lua sandbox has no sockets and no
HTTP. This program is the bridge. It:

  1. reads LevelPace's SavedVariables file (which the game writes on logout,
     /reload or disconnect -- never on a timer, so this can only ever be as
     current as your last clean exit),
  2. sends the shared blob to a leaderboard server, and
  3. downloads the global distribution and writes it back into the addon
     folder as Baseline.lua, so the in-game parse gauge can score you against
     everyone else on your next /reload.

Standard library only. Python 3.8+.

  python3 levelpace_upload.py --server https://example.com --watch

Nothing is uploaded unless YOU enabled sharing inside the addon: the addon
only writes its export table when the setting is on, and this program uploads
only what it finds there. With sharing off there is nothing to send.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

VERSION = "0.2.0"
UA = "LevelPaceUploader/" + VERSION


def configured_server():
    """Read the server address from server.txt beside this script.

    This exists so the person you hand the uploader to never has to edit a
    file or type a URL: you set it once, they double-click.
    """
    for name in ("server.txt", "SERVER.txt"):
        f = Path(__file__).resolve().parent / name
        if not f.is_file():
            f = Path(__file__).resolve().parent.parent / name
        if f.is_file():
            for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    return None


# =============================================================================
# Lua SavedVariables parser
#
# SavedVariables is Lua source, but a deliberately restricted subset: nested
# table constructors of strings, numbers, booleans and nil, with keys written
# as ["name"], [1] or bare identifiers. That is small enough to parse directly
# and avoids asking anyone to install a Lua runtime just to read a scoreboard.
# =============================================================================

class LuaSyntaxError(ValueError):
    pass


_TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<comment>--\[\[.*?\]\]|--[^\n]*)
  | (?P<string>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')
  | (?P<number>-?(?:0[xX][0-9a-fA-F]+|\d+\.\d+[eE][+-]?\d+|\d+\.\d+|\.\d+|\d+[eE][+-]?\d+|\d+))
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<punct>[\{\}\[\]=,;])
""", re.VERBOSE | re.DOTALL)

_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b",
            "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


def _unescape(raw):
    body = raw[1:-1]
    out, i = [], 0
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= len(body):
            break
        e = body[i]
        if e in _ESCAPES:
            out.append(_ESCAPES[e])
            i += 1
        elif e.isdigit():
            num = ""
            while i < len(body) and body[i].isdigit() and len(num) < 3:
                num += body[i]
                i += 1
            out.append(chr(int(num)))
        elif e == "x":
            i += 1
            hexs = ""
            while i < len(body) and len(hexs) < 2 and body[i] in "0123456789abcdefABCDEF":
                hexs += body[i]
                i += 1
            out.append(chr(int(hexs, 16)) if hexs else "")
        else:
            out.append(e)
            i += 1
    return "".join(out)


def _tokenize(src):
    pos, n, toks = 0, len(src), []
    while pos < n:
        m = _TOKEN.match(src, pos)
        if not m:
            raise LuaSyntaxError("unexpected character %r at offset %d" % (src[pos], pos))
        pos = m.end()
        kind = m.lastgroup
        if kind in ("ws", "comment"):
            continue
        toks.append((kind, m.group()))
    return toks


class _Parser:
    def __init__(self, toks):
        self.toks, self.i = toks, 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def next(self):
        t = self.peek()
        self.i += 1
        return t

    def expect(self, value):
        kind, tok = self.next()
        if tok != value:
            raise LuaSyntaxError("expected %r, got %r" % (value, tok))

    def value(self):
        kind, tok = self.peek()
        if tok == "{":
            return self.table()
        self.next()
        if kind == "string":
            return _unescape(tok)
        if kind == "number":
            if tok.lower().startswith(("0x", "-0x")):
                return int(tok, 16)
            return float(tok) if any(c in tok for c in ".eE") else int(tok)
        if kind == "name":
            if tok == "true":
                return True
            if tok == "false":
                return False
            if tok == "nil":
                return None
            return tok  # bare identifier used as a value: treat as a string
        raise LuaSyntaxError("unexpected token %r" % (tok,))

    def table(self):
        self.expect("{")
        result, array_index = {}, 1
        while True:
            kind, tok = self.peek()
            if tok == "}":
                self.next()
                break
            if tok is None:
                raise LuaSyntaxError("unterminated table")
            if tok in (",", ";"):
                self.next()
                continue

            if tok == "[":
                self.next()
                key = self.value()
                self.expect("]")
                self.expect("=")
                result[key] = self.value()
            elif kind == "name" and self.i + 1 < len(self.toks) and self.toks[self.i + 1][1] == "=":
                self.next()
                self.expect("=")
                result[tok] = self.value()
            else:
                result[array_index] = self.value()
                array_index += 1
        return result


def parse_saved_variables(text):
    """Return {globalName: value} for every top-level assignment."""
    toks = _tokenize(text)
    p = _Parser(toks)
    out = {}
    while p.i < len(toks):
        kind, tok = p.peek()
        if tok in (",", ";"):
            p.next()
            continue
        if kind != "name":
            raise LuaSyntaxError("expected a global name, got %r" % (tok,))
        p.next()
        p.expect("=")
        out[tok] = p.value()
    return out


def lua_array(d):
    """SavedVariables arrays come back as {1: x, 2: y}. Convert to a list."""
    if not isinstance(d, dict):
        return []
    keys = [k for k in d.keys() if isinstance(k, int)]
    if not keys:
        return []
    return [d[k] for k in sorted(keys)]


# =============================================================================
# Finding the file
# =============================================================================

DEFAULT_WOW_HINTS = [
    r"C:\World of Warcraft",
    r"C:\Games\World of Warcraft",
    r"C:\Program Files (x86)\World of Warcraft",
    r"C:\Program Files\World of Warcraft",
    os.path.expanduser("~/World of Warcraft"),
    os.path.expanduser("~/Games/World of Warcraft"),
    os.path.expanduser("~/Applications/World of Warcraft"),
]


def find_saved_variables(wow_dir=None):
    """Every WTF/Account/*/SavedVariables/LevelPace.lua under a WoW folder."""
    roots = [Path(wow_dir)] if wow_dir else [Path(p) for p in DEFAULT_WOW_HINTS]
    found = []
    for root in roots:
        wtf = root / "WTF" / "Account"
        if not wtf.is_dir():
            continue
        for account in wtf.iterdir():
            f = account / "SavedVariables" / "LevelPace.lua"
            if f.is_file():
                found.append(f)
    return found


def find_addon_dir(wow_dir=None):
    roots = [Path(wow_dir)] if wow_dir else [Path(p) for p in DEFAULT_WOW_HINTS]
    for root in roots:
        d = root / "Interface" / "AddOns" / "LevelPace"
        if d.is_dir():
            return d
    return None


# =============================================================================
# Extraction
# =============================================================================

def extract_blobs(sv_path):
    """Pull the addon's export table out of a SavedVariables file."""
    text = Path(sv_path).read_text(encoding="utf-8", errors="replace")
    try:
        globals_ = parse_saved_variables(text)
    except LuaSyntaxError as e:
        raise LuaSyntaxError("%s: %s" % (sv_path, e))

    db = globals_.get("LevelPaceDB")
    if not isinstance(db, dict):
        return []
    export = db.get("export")
    if not isinstance(export, dict):
        return []

    blobs = []
    for char_key, blob in export.items():
        if not isinstance(blob, dict):
            continue
        levels = [lv for lv in lua_array(blob.get("levels")) if isinstance(lv, dict)]
        blobs.append({
            "schema": blob.get("schema", 1),
            "addon": blob.get("addon"),
            "id": blob.get("id"),
            "display": blob.get("display") or str(char_key).split("-")[0],
            "realm": blob.get("realm"),
            "class": blob.get("class"),
            "faction": blob.get("faction"),
            "level": blob.get("level"),
            "questRate": blob.get("questRate"),
            "updated": blob.get("updated"),
            "levels": levels,
            "pvp": blob.get("pvp") if isinstance(blob.get("pvp"), dict) else None,
        })
    return blobs


# =============================================================================
# Network
# =============================================================================

def post_json(url, payload, timeout=20):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def get_json(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


# =============================================================================
# Baseline writeback
#
# This is how the distribution reaches the addon: the addon cannot fetch, so we
# write a Lua file it loads from its TOC on the next /reload.
# =============================================================================

def write_baseline(addon_dir, baseline, source_url):
    def nums(seq, cap=2000):
        seq = list(seq)
        if len(seq) > cap:  # keep the file small; a uniform sample is plenty
            step = len(seq) / cap
            seq = [seq[int(i * step)] for i in range(cap)]
        return "{" + ",".join("%.4f" % v for v in seq) + "}"

    lines = [
        "-- LevelPace :: Baseline (generated)",
        "--",
        "-- WRITTEN BY THE LEVELPACE UPLOADER. Do not hand-edit; it is overwritten.",
        "-- Fetched %s from %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), source_url),
        "",
        "LevelPaceBaseline = {",
        "  fetched = %d," % int(time.time()),
        "  source = %s," % json.dumps(source_url),
        "  players = %d," % int(baseline.get("players") or 0),
        "  overall = %s," % nums(baseline.get("overall") or []),
        "  byLevel = {",
    ]
    for level, vals in sorted((baseline.get("byLevel") or {}).items(), key=lambda kv: int(kv[0])):
        lines.append("    [%d] = %s," % (int(level), nums(vals, 500)))
    lines += ["  },", "}", ""]

    target = Path(addon_dir) / "Baseline.lua"
    tmp = target.with_suffix(".lua.tmp")
    tmp.write_text("\n".join(lines), encoding="utf-8")
    tmp.replace(target)  # atomic: never leave a half-written Lua file behind
    return target


# =============================================================================
# Main
# =============================================================================

def run_once(args):
    files = ([Path(args.file)] if args.file else find_saved_variables(args.wow))
    if not files:
        print("No LevelPace SavedVariables found.")
        print("Point at it with --file, or give your WoW folder with --wow.")
        return 1

    all_blobs = []
    for f in files:
        try:
            blobs = extract_blobs(f)
        except Exception as e:
            print("  ! could not read %s: %s" % (f, e))
            continue
        if blobs:
            print("  %s -> %d character(s)" % (f, len(blobs)))
        all_blobs.extend(blobs)

    if not all_blobs:
        print("Nothing to upload. Sharing is off in the addon, or you have not "
              "logged out since enabling it (the game only writes the file on "
              "logout or /reload).")
    elif args.dry_run:
        print(json.dumps(all_blobs, indent=2)[:4000])
        print("\n--dry-run: nothing sent.")
    else:
        try:
            res = post_json(args.server.rstrip("/") + "/api/submit", all_blobs)
            print("  uploaded: %s levels accepted, %s rejected"
                  % (res.get("levels"), res.get("rejected")))
            for e in res.get("errors") or []:
                print("  ! server: %s" % e)
        except urllib.error.URLError as e:
            print("  ! upload failed: %s" % e)
            return 2

    if args.no_baseline:
        return 0
    addon_dir = Path(args.addon) if args.addon else find_addon_dir(args.wow)
    if not addon_dir:
        print("  ! addon folder not found; skipping baseline writeback (--addon)")
        return 0
    try:
        base = get_json(args.server.rstrip("/") + "/api/baseline")
        path = write_baseline(addon_dir, base, args.server)
        print("  baseline written: %s (%d players)" % (path, base.get("players") or 0))
        print("  /reload in game to pick it up.")
    except urllib.error.URLError as e:
        print("  ! baseline fetch failed: %s" % e)
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="Upload LevelPace stats and fetch the global baseline.")
    ap.add_argument("--server", default=None,
                    help="leaderboard server base URL "
                         "(defaults to server.txt, else http://localhost:8080)")
    ap.add_argument("--wow", help="WoW install folder (auto-detected if omitted)")
    ap.add_argument("--file", help="path to LevelPace.lua SavedVariables")
    ap.add_argument("--addon", help="path to Interface/AddOns/LevelPace")
    ap.add_argument("--watch", action="store_true",
                    help="keep running and re-upload when the file changes")
    ap.add_argument("--interval", type=int, default=60, help="watch poll seconds")
    ap.add_argument("--dry-run", action="store_true",
                    help="print exactly what would be sent, send nothing")
    ap.add_argument("--no-baseline", action="store_true",
                    help="do not write Baseline.lua back into the addon")
    ap.add_argument("--forget", metavar="ID",
                    help="ask the server to delete everything for this client id")
    args = ap.parse_args()
    if not args.server:
        args.server = configured_server() or "http://localhost:8080"

    if args.forget:
        try:
            res = post_json(args.server.rstrip("/") + "/api/forget", {"id": args.forget})
            print("deleted:", res.get("deleted"))
            return 0
        except urllib.error.URLError as e:
            print("failed:", e)
            return 2

    if not args.watch:
        return run_once(args)

    print("Watching for changes. Ctrl-C to stop.")
    print("Note: WoW only writes SavedVariables on logout or /reload, so "
          "nothing changes mid-session.")
    seen = {}
    try:
        while True:
            files = ([Path(args.file)] if args.file else find_saved_variables(args.wow))
            changed = False
            for f in files:
                try:
                    mtime = f.stat().st_mtime
                except OSError:
                    continue
                if seen.get(str(f)) != mtime:
                    seen[str(f)] = mtime
                    changed = True
            if changed:
                print("\n[%s] change detected" % time.strftime("%H:%M:%S"))
                run_once(args)
            time.sleep(max(5, args.interval))
    except KeyboardInterrupt:
        print("\nbye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
