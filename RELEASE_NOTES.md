# LevelPace 0.9.0 — the minimap button

## Everything is behind one button now

A black-and-purple icon on your minimap. Click it.

```
+----------------------------------+
| LevelPace                        |
|   [ ] Meter                      |
|   [ ] Dashboard                  |
|       Leaderboard                |
|----------------------------------|
| Modules                          |
|   [x] LevelPace                  |
|   [x] Rare Finder                |
|   [x] Nemesis                    |
|----------------------------------|
|   [ ] Lock frames                |
|       Options                    |
|       Hide this button           |
+----------------------------------+
```

**Drag it** anywhere around the minimap ring; it stays where you put it.

The module toggles are checkboxes, so which ones are running is something you
can see rather than something you have to remember. Ticking one keeps the menu
open, so you can switch several without reopening it each time.

Every slash command still works. `/lp minimap` brings the button back if you
hide it.

## Also new since 0.7

- **`/lp meter`** — an always-on panel that behaves like a damage meter.
  Movable, resizable from the corner, click the header to change view.
  BG damage, BG healing, killing blows, rare kills, leaderboard.
- **Live battleground ranking** against your own team, in the WarcraftLogs
  colour bands. Bar length is your share of the leader; bar colour is your
  percentile. Those are different questions.
- **Achievement icons** for all 14 PvP achievements.

## Fixed

**The companion never started.** Two problems in the launcher, one of them
fatal: it searched its own file for a marker that its own command line
contained, so PowerShell was handed a batch directive and quit before doing
anything. The build now refuses to package a launcher it cannot prove starts.

If it still does nothing, run **`LevelPace Companion (SHOW ERRORS).bat`** from
the same folder. Same program, but the window stays open and prints exactly
what went wrong.

**Turning a module off didn't stick** — the XP bar and gauge were never hidden
at all, and whatever was hidden came back a second later.

## Installing

Unzip `LevelPace.zip` into `Interface\AddOns\`. You should end up with
`Interface\AddOns\LevelPace\LevelPace.toc`.

The minimap button appears at the bottom-left of your minimap. Everything is
behind it.
