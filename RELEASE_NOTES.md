# LevelPace — for WoW 3.3.5a (Wrath)

**An addon that tells you how fast you are actually levelling, who keeps
killing you in battlegrounds, and which rares are being killed on your server
— and puts all of it on a shared leaderboard with your mates.**

Works on any 3.3.5a private server. No account, no sign-up, no email.

---

## New in 0.9.18 — battleground stats without opening the scoreboard, and a match log

- **You no longer have to open the scoreboard once.** The addon only asked the
  server for scoreboard data once some already existed — which happened only
  after *you* opened Blizzard's scoreboard. It now asks every few seconds from
  the moment you are in a battleground. While it waits, the dashboard and the
  meter say so instead of sitting empty.
- **BG log** — a new meter view, one click from *BG damage* (click the meter's
  header to switch): who joined and left (both sides), who picked up, dropped,
  captured or returned a flag, who you killed and who killed you, and the
  result — newest first, stamped with the match clock. Names are in their
  class colour with a class icon and a role icon. The role is *inferred*
  (healing above damage on the scoreboard = healer): the 3.3.5a client tells
  addons a player's class, never their spec, and enemies cannot be inspected.
- **Empty nemesis list explained.** A nemesis is someone who has killed you
  more than you killed them — dealing no damage does not matter, dying does.
  If you died with no player landing the last hit (a pet, a totem, a fall),
  the dashboard now says so and counts it instead of showing a blank.

- **No more grey parse when nobody else is on the board.** The pace gauge
  used to fall back to comparing you against your *own* earlier levels — so a
  level 6 whose levels 1–4 took a minute each got a grey "Common". A parse
  needs other players: until 3 or more are on the board at your level it now
  says "no parse yet" and stays uncoloured. Rankings are per level, not per
  class — the board is far too small to split by class.
- **Your levels, ranked** — the LevelPace dashboard tab now lists every level
  you have finished with your time, your levels/hour, and your percentile and
  colour against everyone else's time *at that level* (from the board data the
  companion brings back). "Nobody else at this level yet" where that is so.
- The board no longer shows you one level lower than you are: the addon
  exported the game's level number at the instant of the level-up, when it
  still reads the old value.

Only the addon zip changed; the companion is the same.

## Fixed in 0.9.17 — battleground wins and losses were never counted

The dashboard's **Record: 0W 0L (since install)** stayed at zero no matter how
many matches you played: nothing in the game ever told it a match had ended.
It now reads the winner the way the game's own scoreboard does, records each
match once, and — because the live damage/healing meters disappear the moment
you leave a battleground — keeps your **final standing** (damage, healing,
your place among the team's healers) as a *Last battleground* section until
the next match. Only the addon zip changed; the companion is the same.

## Fixed in 0.9.16 — real data is on the board; two companion errors gone

The first uploads from a real client have landed: a character's levels are on
<https://monscorps.github.io/levelpace/> right now. Two things still showed up
in the companion's log after that, and both are fixed here:

- **"board fetch failed: cannot connect"** every five minutes. The companion
  was reading the rankings from the address of a machine that no longer
  exists. It now reads them from the same place it uploads to, so the in-game
  leaderboard (`/lp board`) and the percentile gauge fill in from live data.
- **"Found WoW at D."** — it printed the first *letter* of your WoW path and
  then claimed the addon was not installed there. Fixed.

Also in this release:

- After every upload the companion tells the server "uploaded N levels", so
  whoever runs the board can see your install is working without asking for
  your log.
- Any error the companion logs now names the exact line it came from.
- The companion zip is five files. It used to also carry an old server and
  three launchers you should never run.
- The in-game "version X is available" notice now points at a real version.

**If you are on 0.9.15: install both zips again and `/reload`. Nothing else
to do.** On anything older than 0.9.13, the addon zip is not optional: before
0.9.13 the export called `math.randomseed`, which does not exist inside WoW,
so no data was ever produced.

## Download these two

| File | What it is | Where it goes |
|---|---|---|
| **`1-ADDON-LevelPace.zip`** | The addon itself | `Interface\AddOns` |
| **`2-UPLOADER-LevelPace-Companion.zip`** | Sends your stats to the board | Anywhere. Desktop is fine. |

> **Ignore "Source code (zip)" and "Source code (tar.gz)".** GitHub attaches
> those to every release automatically and there is no way to hide them. They
> are the raw project files — you do not want them.

**You only need file 1 to use the addon.** File 2 is only for appearing on the
shared leaderboard.

---

## What it does

Three things, and each can be switched off on its own.

### LevelPace — how fast you are levelling

Your real pace, not a guess. It counts the deaths, the corpse runs and the
time stood in a bank, because that is how levelling actually goes.

- XP per hour, time to next level, mobs to go
- **Which quests in your log are worth doing** — it measures how long your
  objectives are actually taking *you*, and compares that against grinding
- Rested XP handled properly: it doubles a finite pool and does not apply to
  quest XP at all

### Nemesis — battlegrounds

- **A live meter of how you are doing against your own team** — damage,
  healing and killing blows, coloured by percentile
- **Who joined and who left** the battleground
- **"Your arch nemesis is here"** — anyone who has killed you more often than
  you have killed them
- Flag pickups, captures and returns
- Kills, deaths, current and longest killstreak
- 14 achievements

### Rare Finder — rare mob kills

- **420 rares** across vanilla, Burning Crusade and Wrath, recognised by
  creature id, so it works whatever language your client is in
- **Kills by other people near you count too** — stand near someone dropping
  the Time-Lost Proto Drake and it goes in the log
- Learns your server's custom rares by itself

---

## Installing

**1. The addon**

Unzip `1-ADDON-LevelPace.zip` into your WoW folder's `Interface\AddOns`, so
you end up with:

```
World of Warcraft\Interface\AddOns\LevelPace\LevelPace.toc
```

> **The one mistake that breaks everything:** Windows "Extract All" wraps the
> contents in an extra folder named after the zip. If you end up with
> `AddOns\LevelPace\LevelPace\...` or `AddOns\1-ADDON-LevelPace\...`, WoW
> silently loads nothing — no `/lp`, no minimap skull. Drag the **inner**
> `LevelPace` folder directly into `AddOns`. The companion's log now names
> this exact problem if it sees it.

Start WoW. A **red skull on a black button appears on your minimap** —
everything is behind it. `/lp modules` confirms all three parts loaded.

**2. The leaderboard (optional)**

Unzip `2-UPLOADER-LevelPace-Companion.zip` anywhere, double-click
**`LevelPace Companion.bat`**. An icon appears next to your clock. Leave it
running.

Then in game:

1. Minimap button → **Share to leaderboard**
2. Type **`/reload`** — this sends everything already recorded, not just from
   now on
3. Right-click the tray icon → **Upload now**

Nothing leaves your computer until you tick that box.

> **If no tray icon appears:** run `LevelPace Companion (SHOW ERRORS).bat`
> from the same folder. Same program, but the window stays open and prints
> what went wrong.
>
> **If it cannot find WoW:** right-click the icon → **Set WoW folder…** and
> point it at the folder containing `Wow.exe`.

---

## Using it

Everything is on the minimap button. Commands still work if you prefer them:

| | |
|---|---|
| `/lp` | Options |
| `/lp meter` | The always-on panel, like a damage meter |
| `/lp dash` | Dashboard, one tab per part |
| `/lp nemesis` | Your PvP record |
| `/lp rares` | Your rare kill log |
| `/lp share on` | Turn on the leaderboard |
| `/lp feedback` | Where to report things |

---

## Where your data goes

Only if you switch sharing on. Then: your character name and realm, your
levelling times, and — as a **separate** tick box — your PvP stats.

PvP is separate on purpose. It contains other players' character names (your
nemeses), and they never agreed to anything.

Board: **https://monscorps.github.io/levelpace**

---

## Telling us it is broken

**https://github.com/monscorps/levelpace/issues**

Or type `/lp feedback` in game and the link prints in chat.

There are two short forms: *Something is broken* and *An idea*.

If it is the uploader misbehaving, right-click its tray icon → **Copy log (for
Discord)** and paste that into the report. It is already formatted, and it is
the difference between a fix and a guessing game.

**Ideas are as welcome as bugs.** Say what you want to *know* or *do*, rather
than how you think it should work — the useful part is the problem.

---

## Honest limitations

Not bugs, so nobody wastes time reporting them:

- **Stats only upload after you log out or `/reload`.** WoW writes its saved
  data at those moments and no addon can make it happen sooner.
- **Enemy guild names are partial.** The game only reveals the guild of a
  player you have targeted or moused over. It shows "guilds known: 6 of 15"
  rather than pretending the rest have none.
- **Flag announcements are English only.** 3.3.5a has no translatable text for
  flag events, so on a non-English server they will not fire.
- **Battleground win/loss counts from when you installed**, not your whole
  career. Only honorable kills are genuinely lifetime, because only those come
  from the server.
- **A match you leave early is not recorded** — the winner is only known when
  it ends.
- **The leaderboard cannot stop a determined cheat.** The numbers come from a
  file on each player's own computer. Impossible values are rejected and
  nobody can submit under someone else's name, but "is this number true" is
  not answerable and never will be.
