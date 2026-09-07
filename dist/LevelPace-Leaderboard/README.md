# LevelPace leaderboard — server, uploader, dashboard

Three pieces, because a WoW addon cannot use the network:

```
  WoW client                 your PC                      your host
  ──────────                 ───────                      ─────────
  LevelPace addon            levelpace_upload.py          levelpace_server.py
    writes SavedVariables ──▶  reads + POSTs           ──▶  SQLite + dashboard
    reads Baseline.lua    ◀──  writes Baseline.lua     ◀──  GET /api/baseline
```

The addon has no sockets and no HTTP — that isn't a limitation of this design,
it's the Lua sandbox. Everything below exists to work around it.

## Server

Standard library only. Python 3.8+. No pip install.

```bash
python3 levelpace_server.py --port 8080 --db levelpace.db
```

It speaks plain HTTP. **Put it behind a TLS terminator in production** — Caddy
is two lines:

```
leaderboard.example.com {
    reverse_proxy localhost:8080
}
```

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/submit` | POST | ingest one or more character blobs |
| `/api/forget` | POST | `{"id": "..."}` — delete everything for a client id |
| `/api/baseline` | GET | levels-per-hour distribution, for the in-game gauge |
| `/api/leaderboard` | GET | ranked entries; `?level=N` for a single level |
| `/api/twinks` | GET | PvP board; `?bracket=N` |
| `/api/stats` | GET | row counts, for a health check |
| `/` | GET | the dashboard |

## Uploader

```bash
python3 levelpace_upload.py --server https://leaderboard.example.com --watch
```

It auto-detects common WoW install paths; use `--wow` if yours is elsewhere.
`--dry-run` prints exactly what would be sent and sends nothing — worth doing
once before you trust it.

`--forget <id>` deletes your server-side entry. The id is in your
SavedVariables as `clientID`.

**It can only ever be as current as your last clean exit.** WoW writes
SavedVariables on logout, `/reload` or disconnect — never on a timer, and
there is no flush API on 3.3.5a. `--watch` polls the file's mtime, so nothing
moves mid-session.

## How ranking works

The metric is **levels per hour**, not XP per hour. XP/hr is not comparable:
a level 78 in Icecrown out-earns a level 20 regardless of skill, and server
rates differ wildly. Fraction-of-a-level per hour normalises both away.

- **Per level** — everyone who completed that level, ranked by pace. Your
  percentile is `beaten / (n - 1)`, *not* `beaten / n`, because you are inside
  the population being measured. With the wrong divisor the fastest player in
  a field of two scores 50 and nobody can ever reach a 100 parse.
- **Overall** — the **median** of your per-level percentiles. Median, not
  mean, so one lucky level can't carry a weak record and one bad level can't
  sink a strong one.
- **A level only one player has recorded has no percentile at all.** It shows
  as unranked rather than being called a 100, and is excluded from that
  player's overall score.

## Data, honestly

**Every number is client-supplied and forgeable.** Someone can edit their
SavedVariables and claim a 30-second level. The server rejects the physically
impossible (`MIN_LEVEL_SECONDS`, level range) but cannot detect a plausible
lie, because it has no independent source of truth — the game server tells it
nothing. Say so on the page. The bundled dashboard already does, prominently.

If you run this publicly, **you are the data controller** for everyone who
opts in. That means, at minimum:

- Sharing is off by default in the addon, and turning it on is a deliberate act.
- Say what you collect and keep the list short. The current blob is: per
  completed level — the level, seconds taken, XP by source, kills, quests,
  deaths, corpse-run seconds, rested XP used; plus a display name, an optional
  realm/class/faction, and a random id. **Never** zones, coordinates, quest
  names, group members, chat, IPs in the clear, or account identifiers.
- Honour deletion. `/api/forget` exists for this; make it easy to find.
- The uploader is a background program that sends people's data somewhere.
  That is exactly the shape of software people are right to be wary of. Ship
  it as readable source, not a binary, and don't auto-start it for them.

## Rate limiting

`RateLimiter` is a crude per-source cap (default 20/min). It stops an
accidental loop, not an attacker — that's what a real reverse proxy is for.
