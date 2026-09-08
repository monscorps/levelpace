**LevelPace** — XP tracking, quest-vs-grind ranking, and PvP stats for WoW 3.3.5a.

---

## Download

| | |
|---|---|
| **`LevelPace.zip`** | **The addon.** This is the one you want. |
| `LevelPace-Leaderboard.zip` | Server + uploader. Only if you're joining or hosting a board. **Not an addon** — don't put it in AddOns. |

## Install

Unzip `LevelPace.zip` into your WoW folder so you end up with:

```
...\Interface\AddOns\LevelPace\LevelPace.toc
```

If you see `AddOns\LevelPace\LevelPace\LevelPace.toc`, you went one folder too deep — move it up one.

Start WoW, tick **LevelPace** in the AddOns list at the character screen (and **Load out of date AddOns** if it's greyed), then type `/lp` in game.

**That's it.** Everything below works offline, on your own, with nothing else installed.

---

## What's new

**Kill streaks — and these are exact.** `PARTY_KILL` fires for the killer with the victim's real name, so your kills and streaks are measured, not guessed. (It never reaches the victim, which is exactly why nemesis has to guess.) Current streak resets on death; best streak persists.

**Fourteen achievements**, announced once in chat when earned. The good ones lean on the nemesis data:

- **Revenge** — kill whoever killed you last
- **Nemesis Down** — kill someone who's got you 3+ times
- **Even Score** — draw level with a nemesis who had you 5+ times
- **Arch-Rival** — 10 kills each way with the same player
- **Humbled** — die to the same player 10 times, because that deserves recognition too

**A "My PvP" tab** on `/lp board` — your kills, streaks, item level, top 3 nemeses and recent achievements. It reads your saved data directly, so it works for someone who shares nothing.

**A `READ-ME-FIRST.txt`** inside the zip, written for someone who's never installed an addon.

---

## Commands

| | |
|---|---|
| `/lp` | Settings — colours, fonts, layout, what to show |
| `/lp board` | Rankings and your PvP record |
| `/lp quests` | Which of your quests are worth doing right now |
| `/lp reset` | Start this level's tracking over |

---

## Joining the leaderboard

Optional, and off by default.

1. `/lp` → **Leaderboard** → tick **Share my levelling stats**
   (and **Also share PvP stats** for the twink board — separate on purpose, since it includes the names of players who killed you)
2. **Log out, or `/reload`.** WoW only writes its saved data then — never while you're playing, so there's nothing to send until you do.
3. Unzip `LevelPace-Leaderboard.zip` anywhere and double-click **`run-uploader.bat`**

Nothing to install — it uses the PowerShell that already ships with Windows. `run-uploader-dryrun.bat` shows exactly what would be sent without sending it, and `run-uploader-auto.bat` does it for you whenever you finish playing.

---

## Which numbers are exact, and which aren't

Not everything WoW 3.3.5a shows you is actually available to an addon. Where something had to be reconstructed, it's labelled rather than dressed up:

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
