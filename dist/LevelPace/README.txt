# LevelPace

An XP tracker for **World of Warcraft 3.3.5a** (Wrath of the Lich King) that answers one question honestly: *given what I am actually doing right now, what is the fastest way to my next level?*

Plus an optional leaderboard that ranks players by pace, WarcraftLogs-style.

```
LevelPace/     the addon          -> Interface\AddOns\LevelPace\
uploader/      carries data out   -> runs on a player's PC
server/        leaderboard + web  -> runs on a host
tests/         600+ assertions    -> ./tests/run.sh
```

## The addon

- A slim, movable, fully themeable XP bar and stats box.
- Time-to-level and mobs-to-level, measured rather than guessed — and the estimate *decays while you stand still*, because that is what actually happens to your pace.
- **Quests in your log ranked by XP per minute of measured effort**, against your grind rate.
- A pace "parse" gauge, scored 0–100 in the WarcraftLogs colour bands.

The quest ranking is the reason it exists. No addon on any WoW version estimates quest *effort* — the closest prior art (`XToLevel`) treats a quest as a scalar XP number and stops there. LevelPace times your objective counters ticking and turns that into `3,150 XP/min` against a grind rate of `520`.

**Install:** copy the `LevelPace` folder into `Interface\AddOns\`. Type `/lp`.

## Design stance: nothing is sanitised

Deaths count. Corpse runs count. The walk between camps counts. All of it really happened and really slowed you down, so a number that quietly deletes your downtime is not measuring your levelling — it is measuring a fantasy. If you go AFK for two hours the addon *tells* you the estimate includes a two-hour gap. It does not remove it. `/lp reset` is the only filter, and it is yours to pull.

## Things that took research to get right

This client is old and widely mis-documented. A few that would otherwise have been silent bugs:

- **`GetRewardXP()` is the server's value**, already multiplied by `Rate.XP.Quest`. Comparing it against the XP you receive always yields x1 — a x5 server would report as blizzlike. `GetQuestLogRewardXP()` is the *client's* blizzlike number, and **the ratio of the two is your server's quest rate**, exactly, from one reward panel.
- **Rested is a 200% doubling, not the 150%** the game's own tooltip claims — and it does not apply to quest XP at all. A pool of `P` supplies `2P` XP in exchange for `P` XP of base killing; formulating that wrongly understates time-to-level by up to 5×.
- **In a raid group every XP message carries `(-N raid penalty)`** and matches none of the ordinary patterns, so naive parsing silently stops tracking entirely.
- **Heirloom XP auras are invisible to `UnitBuff`** — passive item auras get no client aura slot — so they must be found by scanning equipped items.
- The widely-quoted `5 × mobLevel + 45` kill-XP formula **uses player level**, and the constant comes from the map's expansion tier (45 / 235 / 580).

`docs/superpowers/specs/` records the verified API surface with sources.

## The leaderboard (optional)

A WoW addon **cannot use the network** — no sockets, no HTTP in the Lua sandbox. So the loop is closed in three pieces:

```
addon  --writes SavedVariables-->  uploader  --POST-->  server
addon  <--reads Baseline.lua-----  uploader  <--GET---  server
```

The uploader is PowerShell and needs **nothing installed** on Windows. The server is Python standard library only, over SQLite — no pip, no framework.

Ranking is by **levels per hour**, not XP per hour: XP/hr is not comparable across levels (a level 78 in Icecrown out-earns a level 20 regardless of skill) nor across servers with different rates.

See [`server/README.md`](server/README.md) to run it.

### About cheating

**It cannot be prevented, and this is not the kind of software that should pretend otherwise.**

Every number is produced on the player's machine. They can edit their SavedVariables, edit the addon's Lua, or skip both and POST fabricated JSON at the API. Signing the payload would use a key shipped inside the addon, extractable in about thirty seconds. WarcraftLogs has the same hole.

What is actually done:

1. **Reject the impossible** — a level cleared in under 30 seconds, a level outside 1–79.
2. **Flag the implausible for a human** — an implausible pace, kills with no kill XP, more kills than seconds, corpse-run time longer than the level, and (the clearest signal) a completed level whose elapsed time *changed on resubmission*, since the past does not change. Flags are shown, never silently acted on.
3. **Make the ranking resistant** — the overall score is the **median** of a player's per-level percentiles, so one spectacular lie cannot carry a record.

The dashboard says all of this on the page rather than burying it.

### About privacy

Sharing is **off by default** and lists exactly what it sends: per completed level, the time taken, XP by source, kills, quests, deaths and corpse-run seconds — plus a display name and a random id. Never zones, coordinates, quest names, group members, or chat.

PvP stats are a **separate** opt-in, because the nemesis list contains other players' character names and those people did not agree to anything.

If you host this publicly, you are the data controller for everyone who opts in. `/api/forget` exists; make it easy to find.

## Development

Pure Lua 5.1, zero addon dependencies. The logic modules never touch a frame, so they run under a mock WoW environment outside the game:

```bash
./tests/run.sh
```

Requires `luajit` — the target is Lua 5.1, and the runner refuses to run under 5.5 whose `unpack` and integer-division semantics would mask real bugs.

```bash
./build.sh
```

Produces `dist/LevelPace.zip` (the addon) and `dist/LevelPace-Leaderboard.zip` (server + uploader + launchers).

## Known limitations

- **Quests with no countable objective can't be timed** — escorts, "speak to X". Shown with an explicit `?` rather than an invented number.
- **Recruit-A-Friend is undetectable** — no client API reports it.
- **Weekly PvP kills and nemeses are reconstructions**, not readings. `GetPVPThisWeekStats()` was removed in patch 2.0.1, and `PARTY_KILL` is unicast to the *killer's* group so the victim never sees who killed them. Both are labelled approximate wherever they appear.
- **Heirlooms report item level 1**, so they are excluded from the item-level average and counted separately.
- **SavedVariables are written on logout, not continuously.** A crash loses history since the last clean exit; there is no flush API on this client.
