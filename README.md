# LevelPace

An XP tracker for **World of Warcraft 3.3.5a** (Wrath of the Lich King) that answers one question honestly: *given what I am actually doing right now, what is the fastest way to my next level?*

- A slim, movable, fully themeable XP bar and stats box.
- Time-to-level and mobs-to-level, projected from measurement rather than a formula guess.
- **A ranking of the quests in your log by XP per minute of real, measured effort, compared against your grind rate.**

That last one is the point. No addon on any WoW version estimates quest *effort* — the closest prior art (`XToLevel`) treats a quest as a scalar XP number and stops there. LevelPace times your objective counters ticking and turns that into "this quest is worth 3,150 XP/min, you're grinding at 520".

## Install

1. Copy the **`LevelPace`** folder into:
   ```
   C:\<your WoW folder>\Interface\AddOns\
   ```
   You should end up with `...\Interface\AddOns\LevelPace\LevelPace.toc`. If you see `AddOns\LevelPace\LevelPace\LevelPace.toc`, you nested it one level too deep.
2. Restart the client (or `/console reloadui` if it was already running).
3. At the character screen, click **AddOns** and make sure LevelPace is enabled. If it shows as out of date, tick **Load out of date AddOns**.

## Commands

| Command | What it does |
|---|---|
| `/lp` | Open the options panel |
| `/lp quests` | Print the quest ranking to chat |
| `/lp reset` | Reset tracking for the current level — the only filter in the addon |
| `/lp lock` / `/lp unlock` | Stop / allow dragging the frames |
| `/lp show` / `/lp hide` | Toggle the display |
| `/lp debug` | Dump the last 20 parsed XP events |

Hover the bar or the box for the full breakdown: where your XP came from, how much of it was rested, how long your recent levels actually took, and how much the addon trusts its own projection.

## How it works

**It measures, it doesn't guess.** Private servers run arbitrary XP rates, and `Rate.XP.Kill` and `Rate.XP.Quest` are *separate* config values — a server can run x5 kills with x1 quests, which completely inverts whether questing is worth it. There is no API that reports either. So LevelPace learns them:

- The quest log's `GetQuestLogRewardXP()` gives the value your **client** computes. Your server applies its multiplier at turn-in. Comparing the two across a few turn-ins reveals the real rate.
- Kill XP is compared against the WotLK `BaseGain` formula the same way.

Until it has enough samples it says **"learning"** rather than showing you a confident wrong number.

**Rested is modelled properly.** It is a 200% doubling, not the 150% the game's own tooltip claims, it draws from a finite pool, and it does **not** apply to quest XP. So being rested genuinely makes grinding better and does nothing for quests — and the projection accounts for the pool running dry mid-level.

**Nothing is filtered.** Deaths count. Corpse runs count. The walk between camps counts. All of it really happened and really slowed you down. If you go AFK for two hours the addon will *tell* you the estimate includes a two-hour gap — it will not quietly delete it. `/lp reset` is the only filter, and it's yours to pull.

## Known limitations

These are real and worth knowing before you trust a number:

- **Quests with no countable objective can't be timed.** Escorts, "speak to X", "explore Y" — there is no counter to watch, so LevelPace shows the XP and an explicit `?` rather than inventing a rate. They sort last.
- **Quest-rate learning needs 3 turn-ins** before it will commit to a number. It persists per realm, so it's a one-time cost.
- **Recruit-A-Friend is undetectable.** There is no 3.3.5a client API that reports whether RAF triple XP is active. If you have it, the learned rates absorb it after a short lag.
- **Kill-rate learning is opportunistic.** It needs the mob's level, which the chat message doesn't carry, so samples are only taken when the mob was your target at death. Elite kills, grouped kills, and servers using per-creature XP modifiers are discarded rather than corrected.
- **SavedVariables are written on logout, not continuously.** A client crash or Alt+F4 loses history since your last clean logout. There is no flush API on this client version.
- **English is not required, but only the format strings are translated.** Parsing is built from your client's own global strings, so other locales work. The one exception is heirloom detection for *server-custom* items, which falls back to reading tooltip text.

## Development

Pure Lua 5.1, zero dependencies. The logic modules (`Ledger`, `Rates`, `History`, `Estimator`, `Quests`) never touch a frame, so they run under a mock WoW environment outside the game:

```bash
./tests/run.sh
```

Requires `luajit` — the target client is Lua 5.1 and the runner refuses to run under 5.5, whose `unpack` and integer-division semantics would mask real bugs.

Design notes and the researched 3.3.5a API surface are in `docs/superpowers/specs/`.
