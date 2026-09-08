#!/usr/bin/env python3
"""
LevelPace leaderboard server.

Standard library only -- no pip installs -- so it runs anywhere Python 3.8+
exists. Storage is SQLite. Put it behind Caddy or nginx for TLS in production;
this speaks plain HTTP.

  python3 levelpace_server.py --port 8080 --db levelpace.db

Endpoints
  POST /api/submit       ingest one or more character blobs
  POST /api/forget       delete everything for a client id
  GET  /api/baseline     levels-per-hour distribution, for the addon gauge
  GET  /api/leaderboard  ranked entries (overall, or ?level=N)
  GET  /api/stats        row counts, for a health check
  GET  /                 the dashboard

HONESTY NOTE, stated here because it must not be buried: every number here is
client-supplied. A determined person can edit their SavedVariables file and
claim anything. The sanity limits below reject the physically impossible, not
the merely dishonest. This is a friendly scoreboard, not an audited ranking.
"""

import argparse
import json
import sys
import math
import re
import sqlite3
import threading
import time
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

SCHEMA_VERSION = 1
MAX_BODY = 2 * 1024 * 1024  # 2 MB is far more than any real submission

# --- sanity limits -----------------------------------------------------------
# A level cannot credibly be cleared faster than this, even at high server
# rates with a full heirloom set and a boost. Values outside these bounds are
# dropped rather than clamped: a clamped lie still ranks.
MIN_LEVEL_SECONDS = 30
MAX_LEVEL_SECONDS = 60 * 60 * 24 * 14  # two weeks on one level: keep, but it ranks last
MIN_LEVEL = 1
MAX_LEVEL = 79  # completing level 80 is not a thing; 79 is the last transition

# --- what can and cannot be defended -----------------------------------------
#
# Read this before adding "anti-cheat". Everything below is client-supplied:
# the addon runs on the player's machine, the uploader runs on the player's
# machine, and nothing on the game server corroborates any of it. A signature
# would be signed with a key shipped inside the addon, which is extractable in
# about thirty seconds. There is NO technical fix.
#
# So the goal is not prevention. It is:
#   1. reject the physically impossible outright,
#   2. FLAG the implausible for a human to look at, and
#   3. make the leaderboard's ranking resistant to a single fabricated entry.
#
# (3) is already handled: the overall score is the MEDIAN of a player's
# per-level percentiles, so one spectacular lie does not carry a record.
#
# Flags are recorded, never silently acted on. A flagged entry still stores;
# the dashboard and /api/leaderboard can show or hide it, and a human decides.

# Sustained levels-per-hour above this is not credible on any rate: it implies
# clearing a level every ~18 seconds for the whole level. Flag, do not reject,
# because a boosted low level genuinely can be very fast.
IMPLAUSIBLE_LEVELS_PER_HOUR = 200.0

# A completed level's elapsed time is a fact about the past. It should never
# change on resubmission. Repeated edits are the clearest cheap signal there is.
MAX_ELAPSED_DRIFT = 2  # seconds; anything beyond is a rewrite of history

DDL = """
CREATE TABLE IF NOT EXISTS players (
    id           TEXT PRIMARY KEY,
    display      TEXT NOT NULL,
    realm        TEXT,
    class        TEXT,
    faction      TEXT,
    level        INTEGER,
    quest_rate   REAL,
    addon        TEXT,
    updated      INTEGER,
    first_seen   INTEGER,
    last_seen    INTEGER,
    source_hash  TEXT
);

CREATE TABLE IF NOT EXISTS levels (
    id           TEXT NOT NULL,
    level        INTEGER NOT NULL,
    elapsed      INTEGER NOT NULL,
    kill_xp      INTEGER DEFAULT 0,
    quest_xp     INTEGER DEFAULT 0,
    explore_xp   INTEGER DEFAULT 0,
    unknown_xp   INTEGER DEFAULT 0,
    kills        INTEGER DEFAULT 0,
    quests       INTEGER DEFAULT 0,
    deaths       INTEGER DEFAULT 0,
    corpse_run   INTEGER DEFAULT 0,
    rested_used  INTEGER DEFAULT 0,
    flags        TEXT,          -- comma-separated suspicion flags, NULL = clean
    PRIMARY KEY (id, level),
    FOREIGN KEY (id) REFERENCES players(id) ON DELETE CASCADE
);

-- PvP / twink view. Populated by a later addon version; nullable so the
-- schema does not need migrating when it arrives.
CREATE TABLE IF NOT EXISTS pvp (
    id             TEXT PRIMARY KEY,
    bracket        INTEGER,
    item_level     REAL,
    weekly_kills   INTEGER,
    week_start     INTEGER,
    lifetime_kills INTEGER,
    deaths         INTEGER,
    nemesis        TEXT,       -- JSON array of {name, count}
    updated        INTEGER,
    FOREIGN KEY (id) REFERENCES players(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_levels_level ON levels(level);
CREATE INDEX IF NOT EXISTS idx_players_seen ON players(last_seen);
"""


def levels_per_hour(elapsed):
    if not elapsed or elapsed <= 0:
        return None
    return 3600.0 / elapsed


def inspect_level(row, previous):
    """Return (reject_reason, [flags]) for one submitted level record.

    Rejection is reserved for the impossible. Everything merely suspicious is
    flagged and stored, because a hard reject on a heuristic silently punishes
    honest outliers -- and a fast boosted level looks exactly like a lie.
    """
    level = _int(row.get("level"))
    elapsed = _int(row.get("elapsed"))

    if level is None or not (MIN_LEVEL <= level <= MAX_LEVEL):
        return "level out of range", []
    if elapsed is None or elapsed < MIN_LEVEL_SECONDS:
        return "elapsed below the physical minimum", []

    flags = []

    lph = levels_per_hour(elapsed)
    if lph and lph > IMPLAUSIBLE_LEVELS_PER_HOUR:
        flags.append("pace")

    kills = _int(row.get("kills")) or 0
    kill_xp = _int(row.get("kill")) or 0
    quests = _int(row.get("quests")) or 0
    quest_xp = _int(row.get("quest")) or 0
    total_xp = (kill_xp + quest_xp
                + (_int(row.get("explore")) or 0)
                + (_int(row.get("unknown")) or 0))

    # Internal coherence. These are cheap and catch hand-edited files, because
    # someone lowering `elapsed` rarely thinks to keep the counters consistent.
    if kills > 0 and kill_xp <= 0:
        flags.append("kills-without-xp")
    if kill_xp > 0 and kills <= 0:
        flags.append("xp-without-kills")
    if quests > 0 and quest_xp <= 0:
        flags.append("quests-without-xp")
    if total_xp <= 0:
        flags.append("no-xp")

    # More kills than seconds means better than one kill per second, sustained
    # for the entire level.
    if kills > elapsed:
        flags.append("kill-rate")

    # Deaths and corpse-run time have to be consistent with each other and
    # cannot exceed the level itself.
    deaths = _int(row.get("deaths")) or 0
    corpse = _int(row.get("corpseRun")) or 0
    if corpse > elapsed:
        flags.append("corpse-exceeds-level")
    if deaths == 0 and corpse > 0:
        flags.append("corpse-without-death")

    # The past does not change. A completed level's elapsed time being edited
    # is the single clearest signal available.
    if previous is not None:
        prev_elapsed = previous["elapsed"]
        if abs(prev_elapsed - elapsed) > MAX_ELAPSED_DRIFT:
            flags.append("rewritten")

    return None, flags


class Store:
    def __init__(self, path):
        self.path = path
        self._local = threading.local()
        with self._conn() as c:
            c.executescript(DDL)
            self._migrate(c)

    @staticmethod
    def _migrate(c):
        """CREATE TABLE IF NOT EXISTS does nothing to a table that already
        exists, so new columns have to be added explicitly for databases
        created by an earlier version."""
        cols = {r["name"] for r in c.execute("PRAGMA table_info(levels)")}
        if "flags" not in cols:
            c.execute("ALTER TABLE levels ADD COLUMN flags TEXT")

    def _conn(self):
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(self.path, timeout=10)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA foreign_keys = ON")
            conn.execute("PRAGMA journal_mode = WAL")
            self._local.conn = conn
        return conn

    # -- ingest ---------------------------------------------------------------

    def submit(self, blob, source_hash):
        """Insert or update one character. Returns (accepted_levels, rejected)."""
        pid = str(blob.get("id") or "").strip()
        if not re.fullmatch(r"[0-9a-f]{8,64}", pid):
            raise ValueError("bad or missing client id")

        display = str(blob.get("display") or "Unknown")[:32]
        display = re.sub(r"[\x00-\x1f\x7f]", "", display).strip() or "Unknown"

        now = int(time.time())
        c = self._conn()
        with c:
            row = c.execute("SELECT first_seen FROM players WHERE id = ?", (pid,)).fetchone()
            first_seen = row["first_seen"] if row else now
            c.execute(
                """INSERT INTO players
                     (id, display, realm, class, faction, level, quest_rate, addon,
                      updated, first_seen, last_seen, source_hash)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(id) DO UPDATE SET
                     display=excluded.display, realm=excluded.realm,
                     class=excluded.class, faction=excluded.faction,
                     level=excluded.level, quest_rate=excluded.quest_rate,
                     addon=excluded.addon, updated=excluded.updated,
                     last_seen=excluded.last_seen, source_hash=excluded.source_hash""",
                (pid, display,
                 _clean(blob.get("realm"), 32), _clean(blob.get("class"), 16),
                 _clean(blob.get("faction"), 16), _int(blob.get("level")),
                 _float(blob.get("questRate")), _clean(blob.get("addon"), 16),
                 _int(blob.get("updated")) or now, first_seen, now, source_hash),
            )

            accepted, rejected, flagged = 0, 0, 0
            for lv in (blob.get("levels") or []):
                level = _int(lv.get("level"))
                prev = None
                if level is not None:
                    prev = c.execute(
                        "SELECT elapsed, flags FROM levels WHERE id = ? AND level = ?",
                        (pid, level)).fetchone()

                reason, flags = inspect_level(lv, prev)
                if reason:
                    rejected += 1
                    continue

                # A "rewritten" flag is sticky: clearing it by submitting the
                # original value again would make the check pointless.
                if prev is not None and prev["flags"]:
                    for old in prev["flags"].split(","):
                        if old and old not in flags:
                            flags.append(old)
                if flags:
                    flagged += 1

                elapsed = _int(lv.get("elapsed"))
                c.execute(
                    """INSERT INTO levels
                         (id, level, elapsed, kill_xp, quest_xp, explore_xp, unknown_xp,
                          kills, quests, deaths, corpse_run, rested_used, flags)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                       ON CONFLICT(id, level) DO UPDATE SET
                         elapsed=excluded.elapsed, kill_xp=excluded.kill_xp,
                         quest_xp=excluded.quest_xp, explore_xp=excluded.explore_xp,
                         unknown_xp=excluded.unknown_xp, kills=excluded.kills,
                         quests=excluded.quests, deaths=excluded.deaths,
                         corpse_run=excluded.corpse_run, rested_used=excluded.rested_used,
                         flags=excluded.flags""",
                    (pid, level, elapsed,
                     _int(lv.get("kill")) or 0, _int(lv.get("quest")) or 0,
                     _int(lv.get("explore")) or 0, _int(lv.get("unknown")) or 0,
                     _int(lv.get("kills")) or 0, _int(lv.get("quests")) or 0,
                     _int(lv.get("deaths")) or 0, _int(lv.get("corpseRun")) or 0,
                     _int(lv.get("restedUsed")) or 0,
                     ",".join(sorted(flags)) if flags else None),
                )
                accepted += 1

            pvp = blob.get("pvp")
            if isinstance(pvp, dict):
                c.execute(
                    """INSERT INTO pvp (id, bracket, item_level, weekly_kills, week_start,
                                        lifetime_kills, deaths, nemesis, updated)
                       VALUES (?,?,?,?,?,?,?,?,?)
                       ON CONFLICT(id) DO UPDATE SET
                         bracket=excluded.bracket, item_level=excluded.item_level,
                         weekly_kills=excluded.weekly_kills, week_start=excluded.week_start,
                         lifetime_kills=excluded.lifetime_kills, deaths=excluded.deaths,
                         nemesis=excluded.nemesis, updated=excluded.updated""",
                    (pid, _int(pvp.get("bracket")), _float(pvp.get("itemLevel")),
                     _int(pvp.get("weeklyKills")), _int(pvp.get("weekStart")),
                     _int(pvp.get("lifetimeKills")), _int(pvp.get("deaths")),
                     json.dumps(pvp.get("nemesis") or [])[:2000], now),
                )
        return accepted, rejected, flagged

    def forget(self, pid):
        c = self._conn()
        with c:
            cur = c.execute("DELETE FROM players WHERE id = ?", (pid,))
            c.execute("DELETE FROM levels WHERE id = ?", (pid,))
            c.execute("DELETE FROM pvp WHERE id = ?", (pid,))
        return cur.rowcount

    # -- queries --------------------------------------------------------------

    def baseline(self):
        c = self._conn()
        rows = c.execute("SELECT level, elapsed FROM levels").fetchall()
        overall, by_level = [], {}
        for r in rows:
            lph = levels_per_hour(r["elapsed"])
            if lph is None:
                continue
            overall.append(round(lph, 4))
            by_level.setdefault(r["level"], []).append(round(lph, 4))
        players = c.execute("SELECT COUNT(*) n FROM players").fetchone()["n"]
        return {
            "schema": SCHEMA_VERSION,
            "fetched": int(time.time()),
            "players": players,
            "overall": sorted(overall),
            "byLevel": {str(k): sorted(v) for k, v in sorted(by_level.items())},
        }

    def _level_percentiles(self):
        """percentile of every (player, level) entry within its own level."""
        c = self._conn()
        rows = c.execute("SELECT id, level, elapsed, flags FROM levels").fetchall()
        buckets = {}
        for r in rows:
            lph = levels_per_hour(r["elapsed"])
            if lph is not None:
                buckets.setdefault(r["level"], []).append((r["id"], lph, r["flags"]))
        out = {}
        for level, entries in buckets.items():
            values = sorted(v for _, v, _ in entries)
            n = len(values)
            for pid, v, fl in entries:
                beaten = sum(1 for x in values if v > x)
                # The player is IN this population, so the divisor is n - 1,
                # not n. Dividing by n caps the fastest player at (n-1)/n --
                # with two players the leader scores 50 and nobody can ever
                # reach a 100 parse.
                if n > 1:
                    pct = beaten / (n - 1) * 100.0
                else:
                    # A population of one: you are simultaneously best and
                    # worst. There is no percentile to report.
                    pct = None
                out.setdefault(pid, []).append({
                    "level": level, "lph": v, "pct": pct, "sample": n,
                    "flags": fl.split(",") if fl else [],
                })
        return out

    def flagged(self, limit=200):
        """Everything a human should look at. Nothing is hidden automatically;
        a flag is a prompt to review, not a verdict."""
        c = self._conn()
        rows = c.execute(
            """SELECT l.id, l.level, l.elapsed, l.flags, l.kills, l.kill_xp,
                      l.quests, l.quest_xp, l.deaths, l.corpse_run,
                      p.display, p.realm, p.source_hash, p.last_seen
               FROM levels l JOIN players p ON p.id = l.id
               WHERE l.flags IS NOT NULL AND l.flags != ''
               ORDER BY l.elapsed ASC LIMIT ?""", (limit,)).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["flags"] = (d.get("flags") or "").split(",")
            d["levelsPerHour"] = round(levels_per_hour(d["elapsed"]) or 0, 3)
            out.append(d)
        return out

    def leaderboard(self, level=None, limit=100):
        c = self._conn()
        players = {r["id"]: dict(r) for r in c.execute("SELECT * FROM players").fetchall()}
        pcts = self._level_percentiles()

        entries = []
        if level is not None:
            for pid, items in pcts.items():
                for it in items:
                    if it["level"] == level and pid in players:
                        p = players[pid]
                        entries.append({
                            "id": pid, "display": p["display"], "realm": p["realm"],
                            "class": p["class"], "faction": p["faction"],
                            "level": level,
                            "parse": round(it["pct"], 1) if it["pct"] is not None else None,
                            "levelsPerHour": round(it["lph"], 3),
                            "minutes": round(3600.0 / it["lph"] / 60.0, 1),
                            "sample": it["sample"],
                            "flags": it["flags"],
                        })
            entries.sort(key=lambda e: -e["levelsPerHour"])
        else:
            # Overall = MEDIAN of a player's per-level percentiles. Median, not
            # mean, so one lucky level cannot carry an otherwise poor record,
            # and one bad level cannot sink a strong one.
            for pid, items in pcts.items():
                if pid not in players:
                    continue
                # Levels whose population is 1 have no percentile and are
                # excluded from the overall score rather than counted as zero.
                scored = [i["pct"] for i in items if i["pct"] is not None]
                p = players[pid]
                if scored:
                    vals = sorted(scored)
                    n = len(vals)
                    med = vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2
                    best = max(scored)
                else:
                    med, best, n = None, None, 0
                entries.append({
                    "id": pid, "display": p["display"], "realm": p["realm"],
                    "class": p["class"], "faction": p["faction"],
                    "level": p["level"],
                    "parse": round(med, 1) if med is not None else None,
                    "levels": n,
                    "recorded": len(items),
                    "best": round(best, 1) if best is not None else None,
                    "questRate": p["quest_rate"],
                    "flags": sorted({f for i in items for f in i["flags"]}),
                })
            # Unscored players sort last rather than being treated as zero.
            entries.sort(key=lambda e: (e["parse"] is None, -(e["parse"] or 0), -e["levels"]))

        for i, e in enumerate(entries[:limit], 1):
            e["rank"] = i
        return entries[:limit]

    def twinks(self, bracket=None, limit=100):
        c = self._conn()
        q = """SELECT p.id, p.display, p.realm, p.class, p.faction, p.level,
                      v.bracket, v.item_level, v.weekly_kills, v.lifetime_kills,
                      v.deaths, v.nemesis, v.updated
               FROM pvp v JOIN players p ON p.id = v.id"""
        args = []
        if bracket is not None:
            q += " WHERE v.bracket = ?"
            args.append(bracket)
        rows = c.execute(q, args).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            try:
                d["nemesis"] = json.loads(d.get("nemesis") or "[]")[:3]
            except Exception:
                d["nemesis"] = []
            kills = d.get("lifetime_kills") or 0
            deaths = d.get("deaths") or 0
            d["kd"] = round(kills / deaths, 2) if deaths else (float(kills) if kills else 0.0)
            out.append(d)
        out.sort(key=lambda e: (-(e.get("weekly_kills") or 0), -(e.get("kd") or 0)))
        for i, e in enumerate(out[:limit], 1):
            e["rank"] = i
        return out[:limit]

    def stats(self):
        c = self._conn()
        return {
            "players": c.execute("SELECT COUNT(*) n FROM players").fetchone()["n"],
            "levels": c.execute("SELECT COUNT(*) n FROM levels").fetchone()["n"],
            "pvp": c.execute("SELECT COUNT(*) n FROM pvp").fetchone()["n"],
            "schema": SCHEMA_VERSION,
        }


def _clean(v, n):
    if v is None:
        return None
    return re.sub(r"[\x00-\x1f\x7f]", "", str(v))[:n] or None


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _float(v):
    try:
        f = float(v)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


# --- rate limiting -----------------------------------------------------------

class RateLimiter:
    """Crude per-source limiter. Enough to stop an accidental loop, not an
    attacker -- that is what a real reverse proxy is for."""

    def __init__(self, per_minute=20):
        self.per_minute = per_minute
        self.hits = {}
        self.lock = threading.Lock()

    def allow(self, key):
        now = time.time()
        with self.lock:
            bucket = [t for t in self.hits.get(key, []) if now - t < 60]
            if len(bucket) >= self.per_minute:
                self.hits[key] = bucket
                return False
            bucket.append(now)
            self.hits[key] = bucket
            if len(self.hits) > 10000:
                self.hits = {k: v for k, v in self.hits.items() if v and now - v[-1] < 300}
            return True


class Handler(BaseHTTPRequestHandler):
    server_version = "LevelPace/1.0"
    store = None
    limiter = None
    webroot = None

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args))

    # -- helpers --------------------------------------------------------------

    def _json(self, obj, code=200):
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _err(self, code, msg):
        self._json({"error": msg}, code)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            raise ValueError("bad content length")
        return json.loads(self.rfile.read(n).decode("utf-8"))

    def _source(self):
        raw = self.address_string() or "?"
        return hashlib.sha256(raw.encode()).hexdigest()[:16]

    # -- routes ---------------------------------------------------------------

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        if not self.limiter.allow(self._source()):
            return self._err(429, "slow down")
        try:
            payload = self._body()
        except Exception as e:
            return self._err(400, "bad body: %s" % e)

        if path == "/api/submit":
            blobs = payload if isinstance(payload, list) else [payload]
            if len(blobs) > 50:
                return self._err(400, "too many characters in one submission")
            src = self._source()
            total, rejected, flagged, errors = 0, 0, 0, []
            for b in blobs:
                try:
                    a, r, fl = self.store.submit(b, src)
                    total += a
                    rejected += r
                    flagged += fl
                except Exception as e:
                    errors.append(str(e))
            return self._json({"ok": not errors, "levels": total,
                               "rejected": rejected, "flagged": flagged,
                               "errors": errors})

        if path == "/api/forget":
            pid = str(payload.get("id") or "")
            if not re.fullmatch(r"[0-9a-f]{8,64}", pid):
                return self._err(400, "bad id")
            return self._json({"ok": True, "deleted": self.store.forget(pid)})

        return self._err(404, "no such endpoint")

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)

        if u.path == "/api/baseline":
            return self._json(self.store.baseline())
        if u.path == "/api/leaderboard":
            level = _int(q.get("level", [None])[0])
            limit = min(_int(q.get("limit", [100])[0]) or 100, 500)
            return self._json({"entries": self.store.leaderboard(level, limit)})
        if u.path == "/api/twinks":
            bracket = _int(q.get("bracket", [None])[0])
            limit = min(_int(q.get("limit", [100])[0]) or 100, 500)
            return self._json({"entries": self.store.twinks(bracket, limit)})
        if u.path == "/api/flagged":
            limit = min(_int(q.get("limit", [200])[0]) or 200, 1000)
            return self._json({"entries": self.store.flagged(limit)})
        if u.path == "/api/stats":
            return self._json(self.store.stats())

        # static
        rel = "index.html" if u.path in ("/", "") else u.path.lstrip("/")
        target = (self.webroot / rel).resolve()
        if not str(target).startswith(str(self.webroot.resolve())) or not target.is_file():
            return self._err(404, "not found")
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".json": "application/json",
            ".svg": "image/svg+xml",
        }.get(target.suffix, "application/octet-stream")
        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def publish_static(store, out_dir, web_dir, base_url=None):
    """Write the whole board out as flat files for GitHub Pages.

    Pages cannot run the API, and it cannot vary a response on a query
    string -- so every endpoint becomes a file, and ?level=N becomes
    level-N.json. app.js resolves paths the same way when it sees the
    LEVELPACE_STATIC flag injected below.

    The point of doing this at all: the READ path stops depending on the
    machine that takes the writes. The board stays up on a real HTTPS URL
    whether or not that machine is on, and uploaders can fetch the baseline
    from Pages without anything being reachable.
    """
    out = Path(out_dir)
    api = out / "api"
    api.mkdir(parents=True, exist_ok=True)

    def dump(name, obj):
        (api / (name + ".json")).write_text(
            json.dumps(obj, separators=(",", ":")), encoding="utf-8")

    now = int(time.time())
    stats = store.stats()
    stats["published"] = now
    dump("stats", stats)

    baseline = store.baseline()
    dump("baseline", baseline)
    dump("leaderboard", {"entries": store.leaderboard(None, 500)})
    dump("twinks", {"entries": store.twinks(None, 500)})
    dump("flagged", {"entries": store.flagged(500)})

    levels = sorted(int(k) for k in (baseline.get("byLevel") or {}).keys())
    for lvl in levels:
        dump("level-%d" % lvl, {"entries": store.leaderboard(lvl, 500)})
    dump("levels", {"levels": levels})

    # Copy the page assets, injecting the static flag into index.html so the
    # same app.js works in both modes without a build step.
    web = Path(web_dir)
    for name in ("app.css", "app.js"):
        src = web / name
        if src.is_file():
            (out / name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

    index = web / "index.html"
    if index.is_file():
        html = index.read_text(encoding="utf-8")
        flag = ("<script>window.LEVELPACE_STATIC=true;"
                "window.LEVELPACE_PUBLISHED=%d;</script>\n" % now)
        html = html.replace('<script src="app.js"></script>',
                            flag + '<script src="app.js"></script>')
        (out / "index.html").write_text(html, encoding="utf-8")

    # Stops GitHub Pages running the output through Jekyll, which would
    # otherwise ignore any file or folder beginning with an underscore.
    (out / ".nojekyll").write_text("", encoding="utf-8")

    print("published to %s" % out)
    print("  %d player(s), %d level(s), %d level board(s)"
          % (stats["players"], stats["levels"], len(levels)))
    if base_url:
        print("  baseline URL for uploaders: %s/api/baseline.json" % base_url.rstrip("/"))
    return 0


def import_files(store, paths):
    """Ingest SavedVariables files directly, no uploader involved.

    This is the zero-friction path for a small group: a friend sends you their
    LevelPace.lua however you normally talk, you drop it in and run this. They
    install nothing but the addon.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "uploader"))
    try:
        import levelpace_upload as up
    except ImportError:
        print("could not find uploader/levelpace_upload.py (it holds the Lua parser)")
        return 1

    total_files = total_levels = total_chars = 0
    for pattern in paths:
        matches = sorted(Path().glob(pattern)) if any(c in pattern for c in "*?[") \
            else [Path(pattern)]
        if not matches:
            print("  ! no file matched %s" % pattern)
        for f in matches:
            if f.is_dir():
                matches_in = sorted(f.rglob("LevelPace.lua"))
                if not matches_in:
                    print("  ! no LevelPace.lua under %s" % f)
                for g in matches_in:
                    total_files += 1
                    c, l = _import_one(store, up, g)
                    total_chars += c
                    total_levels += l
                continue
            total_files += 1
            c, l = _import_one(store, up, f)
            total_chars += c
            total_levels += l

    print("\nimported %d file(s): %d character(s), %d level(s)"
          % (total_files, total_chars, total_levels))
    if total_chars == 0:
        print("Nothing was found. The most likely reason is that sharing was "
              "never switched on in the addon, so it wrote no export table.")
    return 0


def _import_one(store, up, path):
    try:
        blobs = up.extract_blobs(path)
    except Exception as e:
        print("  ! %s: %s" % (path, e))
        return 0, 0
    if not blobs:
        print("  - %s: no shared data (sharing off?)" % path.name)
        return 0, 0
    levels = 0
    for b in blobs:
        try:
            a, r = store.submit(b, "import")
            levels += a
            print("  + %s: %s (%d level%s%s)" % (
                path.name, b.get("display"), a, "" if a == 1 else "s",
                ", %d rejected" % r if r else ""))
        except Exception as e:
            print("  ! %s: %s" % (path.name, e))
    return len(blobs), levels


def main():
    ap = argparse.ArgumentParser(description="LevelPace leaderboard server")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--db", default="levelpace.db")
    ap.add_argument("--web", default=str(Path(__file__).parent / "web"))
    ap.add_argument("--rate", type=int, default=20, help="requests per minute per source")
    ap.add_argument("--import", dest="import_paths", nargs="+", metavar="PATH",
                    help="ingest SavedVariables file(s) or folder(s) directly, "
                         "then exit -- for data a friend sent you")
    ap.add_argument("--publish", metavar="DIR",
                    help="write the whole board out as flat files for GitHub "
                         "Pages, then exit (e.g. --publish docs)")
    ap.add_argument("--base-url", help="public URL of the published site, "
                                       "printed for convenience")
    args = ap.parse_args()

    if args.import_paths:
        return import_files(Store(args.db), args.import_paths)

    if args.publish:
        return publish_static(Store(args.db), args.publish, args.web, args.base_url)

    Handler.store = Store(args.db)
    Handler.limiter = RateLimiter(args.rate)
    Handler.webroot = Path(args.web)

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print("LevelPace server on http://%s:%d  (db=%s)" % (args.host, args.port, args.db))
    print("Every number served here is client-supplied and forgeable. Say so on the page.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    sys.exit(main() or 0)
