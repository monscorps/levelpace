# LevelPace 0.8.0 — the always-on meter

## `/lp meter`

A panel that just sits there, like a damage meter.

```
+----------------------------------------------------+
| BG damage                                          |
+----------------------------------------------------+
|  Ragebeard   ############################  412,000  |
|> Grommash    #######################       356,000  |
|  Ironhoof    ###################           298,000  |
|  Blackfang   #################             271,000  |
+----------------------------------------------------+
```

- **Click the header** to change view, right-click to go back
- **Drag it** anywhere, **drag the bottom-right corner** to resize
- Position, size and view are remembered
- `/lp lock` stops it moving, same as the other frames

Views: **BG damage**, **BG healing**, **BG killing blows**, **Rare kills**,
**Leaderboard**. It switches to BG damage by itself when you enter a
battleground, the way a damage meter starts a new segment.

**Bar length and colour mean different things.** Length is your share of the
leader's number — how far behind you are. Colour is your percentile band —
how good that actually is. Being 60% of the top damage in a strong team is
not the same as 60% in a weak one, and one bar should not have to answer both.

Healing lists only players who actually healed. Ranking a rogue's zero against
nine other zeroes is a number that looks like information and is not.

## Fixed

**The companion did nothing.** Double-clicking `LevelPace Companion.bat`
flashed a window and closed with no tray icon. The launcher searched its own
file for a `#PSSTART` marker, but the launcher line itself contained that
text — so it found itself, and PowerShell was handed `exit /b` as its second
statement. `exit` is a PowerShell keyword, so it quit before starting.

The build now refuses to produce a zip unless the launcher provably extracts,
parses, and creates a tray icon.

**Turning a module off didn't stick.** Two separate bugs: the disable only
looked for frames stored in one field name and so never hid the XP bar or the
gauge at all, and whatever it *did* hide came straight back on the next tick.

## Installing

Unzip into `Interface\AddOns\`. You should end up with
`Interface\AddOns\LevelPace\LevelPace.toc`.

`/lp modules` to check all three loaded, `/lp meter` to put the panel up.
