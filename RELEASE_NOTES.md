# LevelPace 0.5.0 — the bundle

Three addons in one folder. One download, same as before.

| Module | What it does | Switch it off with |
|---|---|---|
| **LevelPace** | XP pace, time to level, quests vs grinding | `/lp toggle levelpace` |
| **Nemesis** | Battlegrounds: who joined, who keeps killing you, flags, streaks | `/lp toggle nemesis` |
| **Rare Finder** | Logs every rare kill — yours and any you witness | `/lp toggle rarefinder` |

Each one is independent. Turn any off and the rest carry on.

## New commands

```
/lp modules            what is installed and whether it is on
/lp toggle <id>        switch one on or off
/lp nemesis            your PvP record, nemeses, streaks
/lp rares              your rare kill log
```

Everything you already used still works: `/lp`, `/lp board`, `/lp quests`,
`/lp reset`, `/lp share`, `/lp lock`.

## Nemesis

- **Enemy joined / left** — read from the battleground scoreboard, which lists
  both teams. Someone must be missing from two consecutive scans before they
  count as having left, because scoreboards flicker.
- **Arch nemesis alerts** — a nemesis is anyone who has killed you more often
  than you have killed them. You are told when one is in your match, including
  at the start. That is when it is most useful.
- **Flag carrier announcements** — pickups, captures, returns and drops.
- **Enemy guild names** — see the honest limitation below.
- **Kills, deaths and killstreaks** — current and longest.
- **Lifetime statistics** — honorable kills come from the server and are
  genuinely lifetime. Win/loss is only what the addon has watched since you
  installed it, and it says so rather than pretending to be your career record.
- **Sound alerts** — per event, each independently switchable.

## Rare Finder

- **420 rares** across vanilla, Burning Crusade and Wrath, identified by
  creature id rather than by name, so it works regardless of client language.
- **Kills by other people count too.** Anything dying in your combat log range
  is logged, so standing near someone who drops the Time-Lost Proto Drake
  records it.
- **Custom server rares are learned automatically.** Target anything the server
  calls rare and it is remembered from then on, flagged separately from the
  shipped list.

## Things that are honestly limited

Worth knowing before you wonder whether something is broken.

- **Enemy guilds are partial.** The client can only tell you the guild of a
  player you have targeted or moused over — there is no way to look one up by
  name on 3.3.5a. The addon shows "guilds known: 6 of 15" rather than leaving
  blanks that look like nobody has a guild.
- **Flag messages are English-only.** 3.3.5a ships no translatable strings for
  flag events; the text comes from the server as ordinary chat. On a
  non-English server, or one that reworded its battleground messages, flag
  announcements will not fire.
- **A match you leave early is not recorded.** The winner is only known when
  the battleground ends.
- **Win/loss is since-install**, not lifetime. Only honorable kills are
  lifetime, because only those come from the server.

## Under the hood

Rewritten around a module framework: one shared event router instead of each
feature opening its own frame, which matters in a 40-player battleground where
the combat log is the hottest path in the addon.

The test suite went from 12 files to 17, and from about 600 assertions to 891.

## Fixed

- **Grinding mobs inflated your PvP killstreak.** `PARTY_KILL` fires for every
  kill including creatures, so an afternoon of levelling was writing mobs into
  your battleground record. Found by running the addon rather than by a test.
- "New best killstreak" fired on the first, second and third kill of a fresh
  install. Now only from three.
- An alert switched off still printed to chat; only the sound was muted.

## Installing

Unzip into `Interface\AddOns\`. You should end up with
`Interface\AddOns\LevelPace\LevelPace.toc`.

Type `/lp modules` once you are in game to check all three loaded.
