# LevelPace — for WoW 3.3.5a (Wrath)

**An addon that tells you how fast you are actually levelling, who keeps
killing you in battlegrounds, and which rares are being killed on your server
— and puts all of it on a shared leaderboard with your mates.**

Works on any 3.3.5a private server. No account, no sign-up, no email.

---

## Fixed in 0.9.13 — the upload has never worked until now

Every real client hit the same invisible failure: the export called
`math.randomseed`, which **does not exist inside WoW** (Blizzard removed it;
the game seeds the RNG itself). That call was the first step of every write,
so sharing switched on, the game saved it, and **no data was ever produced** —
silently, because the error was swallowed. It passed every test because
every test environment *does* have `randomseed`; WoW is the only Lua that
doesn't.

If you had sharing on before: install this addon zip and `/reload`. Your
recorded levels upload on the next companion sync. Nothing you did was wrong.

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
