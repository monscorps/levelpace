#!/usr/bin/env python3
"""End-to-end: SavedVariables -> uploader -> server -> Baseline.lua -> addon."""
import json, os, subprocess, sys, tempfile, threading, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "uploader"))
sys.path.insert(0, str(ROOT / "server"))
import levelpace_upload as up          # noqa: E402
import levelpace_server as srv         # noqa: E402

PASS = FAIL = 0
def ok(cond, msg):
    global PASS, FAIL
    if cond: PASS += 1
    else:
        FAIL += 1
        print("    FAIL:", msg)
def eq(a, b, msg):
    ok(a == b, "%s -- expected %r, got %r" % (msg, b, a))

# ---------------------------------------------------------------- Lua parser
SAMPLE = r'''
LevelPaceDB = {
	["clientID"] = "a1b2c3d4e5f60718293a4b5c6d7e8f90",
	["export"] = {
		["Dan-Frostmourne"] = {
			["schema"] = 1,
			["addon"] = "0.2.0",
			["id"] = "a1b2c3d4e5f60718293a4b5c6d7e8f90",
			["display"] = "Dan",
			["realm"] = "Frostmourne",
			["class"] = "WARRIOR",
			["questRate"] = 5,
			["updated"] = 1757000000,
			["levels"] = {
				{
					["level"] = 71,
					["elapsed"] = 3600,
					["kill"] = 120000,
					["quest"] = 90000,
					["deaths"] = 2,
					["corpseRun"] = 95,
				}, -- [1]
				{
					["level"] = 72,
					["elapsed"] = 1800,
					["kill"] = 50000,
				}, -- [2]
			},
		},
		["Alt-Frostmourne"] = {
			["id"] = "ffffffffffffffffffffffffffffffff",
			["display"] = "Alt \"The Quick\"",
			["levels"] = {
				{ ["level"] = 71, ["elapsed"] = 900 },
			},
		},
	},
}
LevelPaceCharDB = { ["profile"] = { ["locked"] = false } }
'''

print("== lua parser")
g = up.parse_saved_variables(SAMPLE)
eq(sorted(g.keys()), ["LevelPaceCharDB", "LevelPaceDB"], "both globals parsed")
eq(g["LevelPaceDB"]["clientID"], "a1b2c3d4e5f60718293a4b5c6d7e8f90", "string value")
eq(g["LevelPaceCharDB"]["profile"]["locked"], False, "boolean value")
exp = g["LevelPaceDB"]["export"]
eq(len(exp), 2, "two characters")
lv = up.lua_array(exp["Dan-Frostmourne"]["levels"])
eq(len(lv), 2, "array converted from {1:..,2:..}")
eq(lv[0]["level"], 71, "array order preserved")
eq(lv[1]["elapsed"], 1800, "second entry")
eq(exp["Alt-Frostmourne"]["display"], 'Alt "The Quick"', "escaped quotes unescaped")
eq(g["LevelPaceDB"]["export"]["Dan-Frostmourne"]["questRate"], 5, "number")

# trailing comments after entries must not break parsing
ok("-- [1]" in SAMPLE, "sample really does contain line comments")

print("== extract")
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "LevelPace.lua"
    p.write_text(SAMPLE)
    blobs = up.extract_blobs(p)
    eq(len(blobs), 2, "two blobs")
    dan = [b for b in blobs if b["display"] == "Dan"][0]
    eq(len(dan["levels"]), 2, "levels carried through")
    eq(dan["questRate"], 5, "quest rate carried")

    empty = Path(td) / "empty.lua"
    empty.write_text("LevelPaceDB = {\n}\n")
    eq(up.extract_blobs(empty), [], "sharing off -> nothing to send")

print("== server round trip")
with tempfile.TemporaryDirectory() as td:
    dbfile = str(Path(td) / "t.db")
    srv.Handler.store = srv.Store(dbfile)
    srv.Handler.limiter = srv.RateLimiter(10000)
    srv.Handler.webroot = ROOT / "server" / "web"
    httpd = srv.ThreadingHTTPServer(("127.0.0.1", 0), srv.Handler)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % port

    sv = Path(td) / "LevelPace.lua"
    sv.write_text(SAMPLE)
    blobs = up.extract_blobs(sv)
    res = up.post_json(base + "/api/submit", blobs)
    eq(res["ok"], True, "submit accepted")
    eq(res["levels"], 3, "three level rows stored")

    st = up.get_json(base + "/api/stats")
    eq(st["players"], 2, "two players")
    eq(st["levels"], 3, "three levels")

    # idempotency: the same file uploaded twice must not duplicate rows
    up.post_json(base + "/api/submit", blobs)
    eq(up.get_json(base + "/api/stats")["levels"], 3, "re-upload updates, not duplicates")

    bl = up.get_json(base + "/api/baseline")
    eq(bl["players"], 2, "baseline player count")
    eq(len(bl["overall"]), 3, "three levels-per-hour values")
    ok("71" in bl["byLevel"], "per-level bucket present")
    eq(len(bl["byLevel"]["71"]), 2, "two players at level 71")

    lb = up.get_json(base + "/api/leaderboard")["entries"]
    eq(len(lb), 2, "two ranked players")
    eq(lb[0]["rank"], 1, "ranked")
    # Alt did level 71 in 900s vs Dan's 3600s, so Alt must lead level 71.
    l71 = up.get_json(base + "/api/leaderboard?level=71")["entries"]
    eq(l71[0]["display"], 'Alt "The Quick"', "faster player leads the level board")
    ok(l71[0]["levelsPerHour"] > l71[1]["levelsPerHour"], "sorted by pace")
    # The player is inside the population, so the divisor is n-1: with two
    # entries the leader must reach 100 and the trailer 0.
    eq(l71[0]["parse"], 100.0, "fastest is a 100 parse")
    eq(l71[1]["parse"], 0.0, "slowest is a 0 parse")

    # A level only one player has recorded has no percentile at all.
    l72 = up.get_json(base + "/api/leaderboard?level=72")["entries"]
    eq(len(l72), 1, "one entry at level 72")
    eq(l72[0]["parse"], None, "a population of one has no percentile")
    ok(l72[0]["levelsPerHour"] > 0, "but the pace is still reported")

    # rejection of impossible values
    bad = dict(blobs[0]); bad["id"] = "b" * 32
    bad["levels"] = [{"level": 71, "elapsed": 1}, {"level": 999, "elapsed": 3600}]
    r = up.post_json(base + "/api/submit", [bad])
    eq(r["levels"], 0, "impossible rows accepted: none")
    eq(r["rejected"], 2, "both rejected")

    # forget
    r = up.post_json(base + "/api/forget", {"id": "ffffffffffffffffffffffffffffffff"})
    eq(r["deleted"], 1, "player deleted")
    eq(up.get_json(base + "/api/stats")["players"], 2, "the bad-id player remains")

    print("== baseline writeback")
    addon = Path(td) / "AddOns" / "LevelPace"
    addon.mkdir(parents=True)
    bl = up.get_json(base + "/api/baseline")
    out = up.write_baseline(addon, bl, base)
    ok(out.is_file(), "Baseline.lua written")
    text = out.read_text()
    ok(text.startswith("-- LevelPace :: Baseline (generated)"), "header present")
    ok("LevelPaceBaseline = {" in text, "assigns the global")
    ok("byLevel" in text and "overall" in text, "both distributions present")
    ok(not list(addon.glob("*.tmp")), "no temp file left behind")

    # the generated file must be loadable by the addon's own parser
    parsed = up.parse_saved_variables(text)
    ok("LevelPaceBaseline" in parsed, "generated Lua re-parses")
    b = parsed["LevelPaceBaseline"]
    ok(len(up.lua_array(b["overall"])) >= 1, "overall values survive the round trip")

    httpd.shutdown()
    httpd.server_close()   # shutdown() stops the loop; the socket stays bound without this

print("\n  %d passed, %d failed" % (PASS, FAIL))
sys.exit(0 if FAIL == 0 else 1)
