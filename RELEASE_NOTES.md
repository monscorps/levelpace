**LevelPace** — XP tracking, quest-vs-grind ranking, and PvP stats for WoW 3.3.5a.

---

## Two things to do

### 1. The addon

Download **`LevelPace.zip`** and unzip it into your WoW folder so you end up with:

```
...\Interface\AddOns\LevelPace\LevelPace.toc
```

If you see `AddOns\LevelPace\LevelPace\LevelPace.toc`, you went one folder too deep — move it up one.

Start WoW, tick **LevelPace** in the AddOns list at the character screen (and **Load out of date AddOns** if it's greyed out), then type `/lp` in game.

**That's the addon done.** Everything below works on its own from here — XP tracking, quest rankings, kill streaks, achievements. You never need anything else.

### 2. The companion — only if you want to be on the leaderboard

Download **`LevelPace-Leaderboard.zip`**, unzip it anywhere, and double-click:

```
LevelPace Companion.bat
```

That's the whole instruction. Nothing installs. No account, no sign-up.

An icon appears by your clock (possibly hidden under the `^` arrow). Leave it running — it uploads your stats by itself whenever you log out of WoW, and brings everyone else's rankings back into your addon.

Right-click the icon for **Upload now**, **Open the web board**, **View log**, or **Quit**.

To start it with Windows: `Win+R` → `shell:startup` → drop a shortcut to the .bat in there.

One thing to turn on first, once: `/lp` → **Leaderboard** → tick **Share my levelling stats**. Nothing leaves your machine until you do.

---

## What's new in this release

**The companion is now a proper tray app, not a script you re-run.** One file, an icon by the clock, and it uploads by itself. Previously you had to remember to run it after every session.

**Kill streaks — and these are exact.** The game tells your client when you kill someone, with their name, so kills and streaks are measured rather than guessed. Current streak resets on death; best streak persists.

**Fourteen achievements**, announced once in chat when earned. The good ones lean on the nemesis data:

- **Revenge** — kill whoever killed you last
- **Nemesis Down** — kill someone who's got you 3+ times
- **Even Score** — draw level with a nemesis who had you 5+ times
- **Arch-Rival** — 10 kills each way with the same player
- **Humbled** — die to the same player 10 times, because that deserves recognition too

**A "My PvP" tab** on `/lp board` — your kills, streaks, item level, top 3 nemeses and recent achievements. Reads your saved data directly, so it works for someone who shares nothing.

---

## Commands

| | |
|---|---|
| `/lp` | Settings — colours, fonts, layout, what to show |
| `/lp board` | Rankings and your PvP record |
| `/lp quests` | Which of your quests are worth doing right now |
| `/lp reset` | Start this level's tracking over |
| `/lp debug` | Last 20 XP events, if something looks wrong |

---

## Why it only updates when you log out

WoW writes its saved data to disk on logout or `/reload` — **never while you're playing**. No addon can change that; there's no API for it.

So the companion watches that file and uploads within a second or two of the game writing it. In practice: play, log out, and it's sent before you've finished looking at the character screen. The addon itself tracks everything live in game — this is only about getting it out.

To see new rankings in game, `/reload` after the companion has run. The board tells you how old it is, so you always know what you're looking at.

---

## Which numbers are exact, and which aren't

Not everything WoW 3.3.5a shows you is available to an addon. Where something had to be reconstructed, it's labelled rather than dressed up:

| | |
|---|---|
| **Kills and streaks** | **Exact.** The game tells your client when you kill someone, with their name. |
| **Nemesis** | **A guess.** Nothing tells you who killed *you* — the game only tells the killer. So it blames whoever last hit you. It gets ganks and falls wrong. |
| **Weekly kills** | **Reconstructed.** There's no weekly counter in this version of WoW. It starts at zero when you install, so your first week looks low. That's honest, not broken. |
| **Item level** | Heirlooms are excluded — the game reports them as item level 1, which would wreck the average. |
| **Time to level** | Counts everything: deaths, corpse runs, standing about. It's meant to. Go AFK and it *tells* you the estimate includes a gap rather than quietly hiding it. |

## What gets sent, if you opt in

Per completed level: the level, how long it took, XP by source, kills, quests, deaths, corpse-run time. Plus a display name and a random id. With PvP sharing on: kills, deaths, item level, streaks, achievements, and your top three nemeses.

**Never sent:** where you are, quest names, who you group with, chat, or anything about your account.

Untick the box and the addon deletes its export immediately.
