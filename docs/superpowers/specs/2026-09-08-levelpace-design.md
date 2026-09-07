# LevelPace — design spec

**Target:** World of Warcraft 3.3.5a (Wrath of the Lich King, build 12340, `## Interface: 30300`) — this client only.
**Date:** 2026-09-08
**Status:** approved design, pending implementation plan

> **Addon name.** `LevelPace` is used throughout. On 3.3.5a the TOC basename *must* match the containing folder name or the addon silently fails to load, and the name is baked into the saved-variables globals and the frame names — so renaming later is a mechanical but multi-file change. Decide now if `LevelPace` is wrong.

---

## 1. What this is

An XP tracker for levelling that answers one question honestly: **given what I am actually doing right now, what is the fastest way to my next level?**

Three things it shows:

1. A slim, fully themeable XP bar and stats box.
2. Mobs-to-level and time-to-level, projected from measurement rather than from a formula guess.
3. **A ranking of the quests in your log by XP per minute of real effort, compared against your measured grind rate** — so you can see whether to keep killing or go do a quest.

Item 3 is the reason the addon exists. Prior-art research found no addon, on any WoW version, that estimates quest *effort* or compares quests to grinding in *time* terms. `XToLevel` (the closest, and it does have a 3.3.5a port) treats a quest as a scalar XP number and stops there.

### Design stance: no sanitising

The user's instruction, verbatim: *"corpse run impacts time to level, we measure time to level, but more granularly and more like how you actually level."*

So: deaths count. Corpse runs count. The walk between camps counts. The bad pull that cost ninety seconds counts. A number that quietly deletes your downtime is not measuring your levelling, it is measuring a fantasy. **The only filter is a manual reset.** There is no AFK detection, no outlier rejection, and no idle-clock-stopping in the default path.

The one place this is relaxed is documented in §6.3 and is opt-in.

---

## 2. Non-goals

- Any client other than 3.3.5a. Explicitly ruled out by the user.
- What-if modelling ("show me my rate without heirlooms"), rate normalisation to x1, and a user-editable custom-buff registry. Considered and cut — the modifier model exists *only* to keep projections honest.
- Zone-level advice ("go quest in Howling Fjord next"). That needs a bundled quest database for quests not yet accepted; cut from v1.
- Per-mob-type XP ranking, a time-allocation breakdown (combat/looting/travel), and a three-pace display. All offered, all declined.
- Dungeon, battleground, or profession XP optimisation.

---

## 3. Platform facts this design depends on

Every claim below was verified against the 3.3.5a `FrameXML` (three byte-identical mirrors: `tekkub/wow-ui-source@3.3.5` commit `c4e0255` "Build 12213", `goldpaw/WoW_UI_Source_WotLK`, `wowgaming/3.3.5-interface-files`) or against TrinityCore/AzerothCore 3.3.5 server source. Anything marked ⚠ is a trap that would otherwise be a silent bug.

### 3.1 Exists and is usable

| API | Signature / note |
|---|---|
| `UnitXP("player")`, `UnitXPMax("player")` | `MainMenuBar.lua:7-8`. `UnitXPMax` is **current level only** — no API for any other level. |
| `GetXPExhaustion()` | Returns **one** value: the remaining rested *bonus* pool. Returns `nil` when not rested. |
| `IsXPUserDisabled()` | Exists — added 3.2.0, not Cataclysm. `MainMenuBar.lua:344`. |
| `GetQuestLogRewardXP()` | **Exists**, added patch 3.3.0. `QuestInfo.lua:279`. No arguments — operates on the currently *selected* quest log entry. |
| `GetQuestLogTitle(i)` | Returns 10 values; **`questID` is at position 9**, `displayQuestID` at 10. Added in 3.3.0. |
| `GetQuestLogLeaderBoard(j, i)` | Returns `text, type, finished`. The objective-progress source. |
| `GetNumQuestLeaderBoards(i)`, `GetNumQuestLogEntries()`, `SelectQuestLogEntry(i)`, `GetQuestLogSelection()` | All present. |
| `UnitAura/UnitBuff(unit, i)` | 11 returns; **`spellId` is index 11, not 10**. Accepts a spell *name* in place of the index on this client. |
| `GetInventoryItemID(unit, slot)` | Added 3.1.0, so present. |
| `INVSLOT_*` | Plain Lua globals from `Constants.lua:189-209`. |
| `SetSize`, `SetBackdrop`, `SetBackdropColor` | Native frame methods on 3.3.5a — **no** `BackdropTemplate` needed. |
| `ColorPickerFrame` + `OpacitySliderFrame` | Present, with `hasOpacity` / `opacityFunc` / `cancelFunc`. |
| Options templates | `UICheckButtonTemplate`, `InterfaceOptionsCheckButtonTemplate`, `OptionsSliderTemplate`, `UIPanelButtonTemplate`, `UIDropDownMenuTemplate`, `InputBoxTemplate`, `UIPanelScrollFrameTemplate` — all confirmed. |
| `InterfaceOptions_AddCategory`, `InterfaceOptionsFrame_OpenToCategory` | Present; the "must call twice" bug is a later regression and does not apply here. |
| `print()` | Exists, `RestrictedEnvironment.lua:92`. |
| `bit` library | Present since 1.9.0. |

### 3.2 Does NOT exist — do not use

| Missing | Use instead |
|---|---|
| `C_Timer` (added 6.0.2) | Throttled `OnUpdate` on a pooled frame. |
| `QUEST_TURNED_IN` (added 6.0.2) | `QUEST_FINISHED` + `hooksecurefunc("GetQuestReward", ...)`. |
| `PLAYER_EQUIPMENT_CHANGED` (added 4.0.1) | `UNIT_INVENTORY_CHANGED` (arg1 = unitID). |
| `PLAYER_AURAS_CHANGED` (removed 3.0.3) | `UNIT_AURA` (arg1 = unitID). |
| `GetMaxPlayerLevel()` (added 4.0.6) | `MAX_PLAYER_LEVEL`, which is a FrameXML global that is **0 until `ReputationFrame` initialises it** from `GetAccountExpansionLevel()`. Read it at `PLAYER_LOGIN`, not at file scope. |
| `C_QuestLog.*`, `GetQuestLogQuestID`, `GetQuestsCompleted` | `select(9, GetQuestLogTitle(i))`. |
| `os.time`, `os.date`, `os.clock`, `io`, `package` | `time()`, `date()`, `GetTime()`. |
| Any API for the server's XP rates | Must be **learned**. See §5. |
| Any API for RAF-active state | Undetectable. Documented limitation. |

⚠ **Registering an unknown event raises a hard Lua error** on 3.3.5a. Every `RegisterEvent` for anything not in §3.1 must be `pcall`-wrapped, or simply not attempted.

### 3.3 The XP-gain chat strings

Exact 3.3.5a enUS values, `GlobalStrings.lua:1685-1708`:

```
COMBATLOG_XPGAIN_FIRSTPERSON          = "%s dies, you gain %d experience."
COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED  = "You gain %d experience."
COMBATLOG_XPGAIN_EXHAUSTION1          = "%s dies, you gain %d experience. (%s exp %s bonus)"
COMBATLOG_XPGAIN_EXHAUSTION2          = "%s dies, you gain %d experience. (%s exp %s bonus)"   -- identical text
COMBATLOG_XPGAIN_EXHAUSTION4          = "%s dies, you gain %d experience. (%s exp %s penalty)"
COMBATLOG_XPGAIN_EXHAUSTION5          = "%s dies, you gain %d experience. (%s exp %s penalty)" -- identical text
COMBATLOG_XPGAIN_QUEST                = "You gain %d experience. (%s exp %s bonus)"
```

⚠ In `(%s exp %s bonus)` the first `%s` is the bonus **amount** (`"+86"`, `"50"`) and the second is the **type label** (`"Rested"`, `"Refer-A-Friend"`). It is **not** a `1.5` multiplier. Getting this backwards silently corrupts every rested calculation.

⚠ The plain `COMBATLOG_XPGAIN` (no suffix) does **not** exist on 3.3.5a, despite `ParserLib` referencing it.

⚠ **The naive format-to-pattern converter is broken.** Escaping only `(` and `)` before substituting `%s`→`(.-)` and `%d`→`(%d+)` fails to match every `_GROUP`/`_RAID` variant, because Lua treats the literal `+` and `-` in the message as quantifiers. The converter must escape `^ ( ) . [ ] * + - ?` **before** placeholder substitution, leaving `%` intact so `%s`/`%d` still mark. This is MSBT's `ConvertGlobalString` and it is the approach to copy.

⚠ **Pattern order matters.** Even anchored with `^`/`$`, the plain `EXHAUSTION1` pattern will match a `_GROUP` message and mis-capture the bonus type as `"Rested bonus, +12 group"`. Patterns must be tried **most-specific first**: `_GROUP`/`_RAID` → `EXHAUSTION*` → `FIRSTPERSON` → `UNNAMED`.

### 3.4 Disambiguating XP sources

⚠ Quest turn-in XP and zone-discovery XP **both** render as `COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED` — `"You gain %d experience."` — and are textually identical. Server-side, `GiveXP(XP, nullptr)` is called for both, so `SMSG_LOG_XPGAIN`'s type byte is `1` for each.

Disambiguation uses `CHAT_MSG_SYSTEM`, which carries the discriminating lines:

```
ERR_QUEST_COMPLETE_S    = "%s completed."
ERR_QUEST_REWARD_EXP_I  = "Experience gained: %d."
ERR_ZONE_EXPLORED_XP    = "Discovered %s: %d experience gained"
```

Attribution rule: an *unnamed* XP gain within a short window (500ms) of a `QUEST_FINISHED` event, or matched by an `ERR_QUEST_REWARD_EXP_I` line, is quest XP. One matched by `ERR_ZONE_EXPLORED_XP` is exploration. Anything else unnamed is `unknown` and is counted in totals but excluded from both the kill rate and the quest rate.

### 3.5 Rested — the mechanics the UI lies about

- Rested is a **strict doubling** of kill XP: `bonus = min(GetRestBonus(), xp)`, so a rested kill grants `base + base` = 200% while the pool lasts.
- ⚠ `GetRestState()` reports a multiplier of **1.5** and the tooltip says "150% of normal experience", but the actual per-kill effect is **200%**. Do not use `GetRestState`'s multiplier for arithmetic.
- ⚠ **Rested does not apply to quest XP or exploration XP.** `bonus_xp = victim ? GetXPRestBonus(xp) : 0` — quests pass `nullptr`, so they get zero bonus and *do not drain the pool*. This is central to the quest-vs-grind comparison: being rested makes grinding better but does nothing for quests.
- Pool cap is `0.75 * UnitXPMax` (worth 1.5 levels of total XP). `GetXPExhaustion()` returns the remaining pool directly.

### 3.6 Group bonus

⚠ TrinityCore 3.3.5 and AzerothCore **both hardcode `group_rate = 1.0`** in `SMSG_LOG_XPGAIN` (with an identical `"should use group_rate here but can't figure out how"` comment). The `(+%d group bonus)` chat variant therefore effectively never appears on these emulators. The parser must still handle it, but the design must not depend on it. Actual group XP effects still reach you — they are just baked into the total, invisibly.

### 3.7 Heirlooms are invisible to the aura API

⚠ Heirloom XP auras are **not returned by `UnitBuff`/`UnitAura`**. TrinityCore's `Aura::CanBeSentToClient()` excludes passive item-equip auras, which never get a client aura slot. So "tie to buffs" cannot be implemented via buff scanning for heirlooms — it must be **equipped-item detection**.

3.3.5a has exactly 20 obtainable XP heirlooms:

- **+10% shoulders (13):** `42949, 42950, 42951, 42952, 42984, 42985, 44099, 44100, 44101, 44102, 44103, 44105, 44107`
- **+10% chests (6):** `48677, 48683, 48685, 48687, 48689, 48691`
- **+5% Dread Pirate Ring:** `50255` (unique-equipped)

Maximum stack is **25%** (shoulder + chest + ring). No WotLK heirloom weapon or trinket grants XP. Heirloom cloaks/helms/legs do not exist on this client.

⚠ On TrinityCore these **compound multiplicatively**, not additively: `1.10 × 1.10 × 1.05 = 1.2705`, i.e. **+27.05%**, not +25%.

⚠ The heirloom bonus applies to **quest XP as well as kill XP** (spell 57353 carries both `Mod Kill Experience Gained %` and `Mod Quest Experience Gained %`). So it cancels out of the grind-vs-quest comparison — but it must still be modelled, because it affects absolute projections.

A tooltip-scrape fallback exists (`"Experience gained from killing monsters and completing quests increased by 10%."`) but has no `GlobalStrings` format string and is therefore locale-dependent. The item-ID list is primary; the scrape is a secondary path for server-custom items.

### 3.8 SavedVariables

- Written **only** on logout, exit, `/reload`, or disconnect. Never on a timer, and there is no flush API on 3.3.5a. A crash or Alt+F4 loses everything since the last write. This is an accepted risk; the mitigation is that the data is inherently re-derivable by playing.
- Load order: addon Lua executes → SavedVariables injected → `ADDON_LOADED` → `PLAYER_LOGIN` → `PLAYER_ENTERING_WORLD`. **File-scope code runs before SavedVariables exist.**
- ⚠ `ADDON_LOADED` fires for *every* addon — filter on `arg1`.
- ⚠ `UnitXP`/`UnitXPMax`/`UnitLevel`/`MAX_PLAYER_LEVEL` are not reliable at `ADDON_LOADED`. Read unit data at `PLAYER_LOGIN`.
- ⚠ `GetPoint()` returns the relative frame as a **userdata object**, which cannot be serialised. Save `relativeTo:GetName()` and guard for anonymous frames.
- Only strings, booleans, numbers and tables serialise. Deep nesting is fine.

---

## 4. Architecture

Zero dependencies. No Ace3, no LibStub. Ace3 does work on 3.3.5a but only as a back-ported build (current CurseForge Ace3 calls `C_Timer`, `BackdropTemplate` and `SetResizeBounds`, none of which exist here), and we would use roughly 4% of it at a cost of ~500KB on a memory-constrained 32-bit client, plus a recurring back-port audit.

Thirteen files, each with one job, communicating through a tiny internal event bus. All shared state lives on a single addon table; no globals beyond the addon name and the two saved-variables tables.

```
LevelPace/
  LevelPace.toc
  Core.lua          -- addon table, event bus, throttled OnUpdate scheduler, module registry
  Compat.lua        -- ConvertGlobalString, safe RegisterEvent, deep copy/merge, number formatting
  Ledger.lua        -- parses XP gains -> normalised events; the single source of truth
  Modifiers.lua     -- rested pool, heirloom scan, XP-disabled state, buff watch
  Rates.lua         -- learns server Rate.XP.Kill and Rate.XP.Quest from observation
  History.lua       -- per-level records; persistence; the learning corpus
  Estimator.lua     -- mobs-to-level, time-to-level, confidence
  Quests.lua        -- quest log scan, objective-tick timing, effort model, ranking
  UI/Bar.lua        -- the XP bar
  UI/Box.lua        -- the stats box + layout presets
  UI/Tooltip.lua    -- hover detail
  UI/Options.lua    -- Interface Options panel, colour pickers, sliders
  Data/XPTable.lua  -- player_xp_for_level 1-79, and the BaseGain constants
```

### Data flow

```
CHAT_MSG_COMBAT_XP_GAIN ─┐
CHAT_MSG_SYSTEM ─────────┼─> Ledger ──> normalised XPEvent
QUEST_FINISHED ──────────┘              { t, source, mobName, total, base, rested, group, questID }
PLAYER_XP_UPDATE ────────┘                    │
                                              ├──> Rates    (learns multipliers)
                                              ├──> History  (accumulates per level)
                                              ├──> Estimator (recomputes projection)
                                              └──> Quests    (attributes quest XP)
                                                      │
UNIT_AURA / UNIT_INVENTORY_CHANGED ──> Modifiers ──────┤
QUEST_LOG_UPDATE ────────────────────> Quests ─────────┤
                                                       v
                                                UI (bar, box, tooltip)
```

`Ledger` is the only module that parses text. Everything downstream consumes structured events, which is what makes the logic testable outside the game (§10).

---

## 5. Learning the server's XP rates

**Why this is load-bearing, not a nicety.** `GetQuestLogRewardXP()` returns the value the *client* computes from its own `QuestXP.dbc`, using the standard WotLK formula. The server's `Rate.XP.Quest` is applied server-side inside `Player::RewardQuest`, at turn-in, and is never transmitted. So on a x5 server the quest log says 4,200 and you actually receive 21,000.

`Rate.XP.Kill` and `Rate.XP.Quest` are **separate config values**. A server can run x5 kills with x1 quests. That single fact can invert the grind-vs-quest recommendation, which is the whole point of the addon. Therefore both rates must be learned independently.

> One research lane asserted `GetQuestLogRewardXP()` returns a "server-correct" number. That is wrong, and it is contradicted by the primary-source reading of `Player::RewardQuest` in the quest lane. The design follows the primary source.

### 5.1 Quest rate

On each turn-in we have a matched pair: the client's predicted XP (captured *before* the quest leaves the log) and the XP actually received.

```
sample = actualXP / (predictedXP * heirloomQuestMultiplier)
```

Store samples per realm. The estimate is the **median** of the last 20 samples, which is robust to a mis-attributed gain without needing outlier-rejection machinery. Report `nil` until at least 3 samples exist, and have the UI say "learning" rather than show a wrong number.

⚠ Capture ordering: `GetQuestLogRewardXP()` must be read **before** the quest is removed from the log. `hooksecurefunc("GetQuestReward", ...)` fires at the right moment — it is a plain unprotected global on 3.3.5a, called from ordinary click handlers.

### 5.2 Kill rate

For each named kill we can compute the client-side expected base from the WotLK formula, then compare.

The formula, from `Trinity::XP::BaseGain` (`Formulas.h`, 3.3.5 branch), reimplemented with truncating division to match:

```lua
-- nBaseExp is selected by the CONTENT TIER OF THE MAP, not by player level:
--   45  = CONTENT_1_60  (Azeroth + vanilla instances)
--   235 = CONTENT_61_70 (Outland)
--   580 = CONTENT_71_80 (Northrend)
local function BaseGain(plLevel, mobLevel, nBaseExp)
    local B = plLevel * 5 + nBaseExp
    if mobLevel >= plLevel then
        local d = math.min(mobLevel - plLevel, 4)          -- +5%/level, capped at +4
        return math.floor((math.floor(B * (20 + d) / 10) + 1) / 2)
    end
    local gray = GrayLevel(plLevel)
    if mobLevel > gray then
        local ZD = ZeroDifference(plLevel)
        return math.floor(B * (ZD + mobLevel - plLevel) / ZD)
    end
    return 0
end
```

⚠ **The widely-quoted `5 * mobLevel + 45` is wrong.** The base term uses **player** level, and the constant is chosen by the **content tier of the map the mob stands in**, not by a player-level band. A level-80 killing a level-70 in Hellfire uses `80*5 + 235`. The same mob level gives 535 more base XP in Northrend than in Azeroth — which is why per-zone context matters.

`GrayLevel(pl)`: `pl<=5 → 0`; `pl<=39 → pl-5-floor(pl/10)`; `pl<=59 → pl-1-floor(pl/5)`; else `pl-9`.
`ZeroDifference(pl)`: `5,6,7,8,9,11,12,13,14,15,16,17` at thresholds `pl<8,<10,<12,<16,<20,<30,<40,<45,<50,<55,<60,else`.

The kill-rate sample is `observedBase / (BaseGain(...) * heirloomKillMultiplier * eliteMultiplier)`.

⚠ **This requires the mob's level**, which the chat message does not carry. We only get it when the killed mob was our target at death. So kill-rate samples are collected opportunistically from `UnitLevel("target")` captured at `PLAYER_REGEN_ENABLED`/kill time, and many kills yield no sample. That is fine — we need a handful, not all of them.

⚠ Confounders that make a sample unusable and must cause it to be **discarded, not corrected**: the mob was elite/rare-elite (rank is not client-visible for a dead mob), the server sets `creature_template.ExperienceModifier` (a per-creature float, invisible to the client), `MinCreatureScaledXPRatio` is enabled (makes gray mobs give XP), or the player was in a group. The median over a rolling window absorbs the rest.

**If the kill rate cannot be learned** — too few clean samples — the addon falls back to reporting the grind side purely empirically (observed XP/hr, no formula), which is all the comparison actually needs. The learned kill rate is a *nicety* for "mobs to level at a level I haven't fought yet"; the learned **quest** rate is the essential one.

---

## 6. Estimation

### 6.1 XP delta across level-ups

⚠ `UnitXP` resets on level-up, so a delta must never be `newXP - oldXP`. It is:

```
delta = (oldMax - oldXP) + (sum of full levels crossed) + newXP
```

The middle term needs XP-per-level for levels other than the current one, which no API provides — hence `Data/XPTable.lua`, the `player_xp_for_level` table for 1-79 (byte-identical across AzerothCore and CMaNGOS: level 1 = 400 … 59 = 172,000, 60 = 290,000, 69 = 717,000, 79 = 1,670,800; total 1→80 = 24,067,200).

⚠ A server can change pacing by editing `player_xp_for_level`, which is visible client-side **only** through `UnitXPMax`. So the bundled table is validated against `UnitXPMax("player")` at every level-up; on mismatch the addon records the observed value, prefers it thereafter, and stops trusting the bundled table for projections beyond the current level.

⚠ Note the cliffs: +68.6% at 59→60 and +112.5% at 69→70. Any "levels per hour" display must not extrapolate across those.

### 6.2 Time to level

Empirical, not formula-driven. On a private server with arbitrary rates and per-creature modifiers, a formula prediction is close to worthless; measurement is the ground truth.

Because rested is a doubling that drains a finite pool, and does not apply to quests, the projection is piecewise. ⚠ The subtlety that is easy to get wrong: a pool of `P` does not supply `P` XP, it supplies `2P` XP in exchange for `P` XP worth of *base* killing.

```
xpRemaining = UnitXPMax - UnitXP
restedPool  = GetXPExhaustion() or 0        -- remaining BONUS pool; kill XP only

xpCoveredByRested = min(2 * restedPool, xpRemaining)   -- total XP the pool can supply
baseWhileRested   = xpCoveredByRested / 2              -- base killing needed to consume it
baseAfterRested   = xpRemaining - xpCoveredByRested    -- the rest, at normal rate

timeToLevel = (baseWhileRested + baseAfterRested) / baseRate
```

where `baseRate` is observed **base** XP per second (rested bonus stripped out by the Ledger — this is exactly why the Ledger decomposes rather than storing totals).

Worked check, `baseRate = 1 xp/s`: with `xpRemaining = 100,000` and `restedPool = 50,000`, the pool exactly covers the level (50,000 base → 100,000 total), so `timeToLevel = 50,000s`. A formulation that computes `restedPool / (2 * baseRate) + (xpRemaining - 2*restedPool) / baseRate` returns 25,000s here and 10,000s at `restedPool = 60,000` — understating by up to 5×. Test case 6 in §10 exists to pin this down.

The rate itself is the median of a rolling window over the current level, blended with the same player's history from previous levels (§6.4) weighted by how much of the current level has been observed. Early in a level, history dominates; late in a level, current observation dominates.

### 6.3 The one concession to reality

The no-sanitising stance produces a genuinely wrong number in exactly one case: you tab out for two hours. Rather than add AFK detection, the addon **detects and reports** it — if a single gap between XP events exceeds a threshold (default 10 min, configurable, `0` disables), the projection is annotated *"includes a 2h 14m gap — /lp reset to clear"*. The number is not silently corrected. This keeps the user's stance intact while making the failure visible rather than baffling. It is a display annotation, not a filter.

### 6.4 Level history

Per level, persisted per character:

```lua
{ level, startedAt, endedAt, elapsed,
  xpBySource = { kill = n, quest = n, explore = n, unknown = n },
  killCount, questCount, deaths, corpseRunSeconds,
  restedConsumed, heirloomPct, zones = { [zoneName] = seconds } }
```

This is the corpus that lets the addon say "you levelled 71→72 in 48 minutes, 70% from quests" and lets the estimator lean on your own past pace rather than a clean-room average when the current level has little data.

Deaths and corpse-run time come from `PLAYER_DEAD` / `PLAYER_UNGHOST` / `PLAYER_ALIVE`.

⚠ Growth is bounded: 79 records per character, each small. No pruning needed.

### 6.5 Mobs to level

Presented as a **range**, not a false-precision integer, because you kill mixed-level mobs:

```
Mobs to level: ~180-240   (based on 47 kills this level, 312-410 XP each)
```

The range is the interquartile span of observed per-kill base XP divided into the remaining requirement, rested-adjusted as in §6.2. If fewer than 10 kills have been observed at this level, it shows `—` and the tooltip says why. Showing a confident wrong number is worse than showing nothing.

---

## 7. The quest ranker

The headline feature.

### 7.1 Value

For each quest in the log, in a single scan (⚠ `SelectQuestLogEntry` changes the *user-visible* selection — capture `GetQuestLogSelection()` first and restore it at the end, exactly as Blizzard's own `WatchFrame_AbandonQuest` does):

```lua
SelectQuestLogEntry(i)
local xp = GetQuestLogRewardXP()
local questID = select(9, GetQuestLogTitle(i))
```

Then `effectiveXP = xp * learnedQuestRate * heirloomQuestMultiplier`.

The scan runs on `QUEST_LOG_UPDATE`, debounced, and results are cached by `questID` — it is not cheap enough to run per frame.

### 7.2 Effort

This is the part nothing else does. Effort is **measured, not guessed**.

For each quest we poll `GetQuestLogLeaderBoard(j, i)` and parse the objective counters using the client's own format strings (`QUEST_MONSTERS_KILLED = "%s slain: %d/%d"`, `QUEST_OBJECTS_FOUND = "%s: %d/%d"`, `QUEST_ITEMS_NEEDED`). Each time a counter ticks we record `(questID, objectiveIndex, delta, timestamp)`.

```
observedTickRate   = ticks observed / elapsed time while progressing
remainingTicks     = sum over objectives of (needed - have)
estimatedMinutes   = remainingTicks / observedTickRate
questValue         = effectiveXP / estimatedMinutes      -- XP per minute
```

This naturally includes travel, deaths, respawn waits and bad luck, because it measures wall-clock between real progress events. That is consistent with the no-sanitising stance.

**Confidence tiers**, shown honestly in the UI:

| Tier | When | Display |
|---|---|---|
| **Measured** | ≥3 objective ticks observed on this quest | Full estimate, solid |
| **Inferred** | Countable objectives, <3 ticks — uses your median tick rate across similar quests at this level | Estimate, marked with `~` |
| **Unmeasurable** | No countable objective (*"speak to X"*, *"explore Y"*, escort quests) | XP shown, effort shown as `?`, sorted last, never given a fake XP/min |

⚠ The "unmeasurable" bucket is real and non-trivial — escorts and travel quests are common. The addon will not invent a number for them. It shows the XP and says it cannot time it.

A quest that is `isComplete` has zero remaining effort except turn-in travel, which we cannot measure; those are surfaced separately as **"ready to turn in"** rather than ranked.

### 7.3 The comparison

The grind baseline is your measured base XP/min in the **current zone** (per-zone, because §5.2's content-tier constants mean the same mob level is worth wildly different XP in Azeroth versus Northrend).

⚠ The comparison must be made on **base** XP on both sides — rested doubles kill XP but not quest XP, so comparing rested-inclusive kill rate against quest XP would systematically overstate grinding. The UI states which regime you are in:

```
Rested (14,200 pool left) — grinding is worth 2x until it drains
```

Output:

```
Ready to turn in
  Report to Vindicator Yaala            9,800 XP

Worth doing
  Kill 10 Ravenous Ghouls   12,600 XP   ~4 min    3,150/min  ★
  Collect 8 Scourge Cores    7,400 XP   ~9 min      822/min

Slower than grinding
  Escort the Prisoner        8,400 XP  ~19 min      442/min
  Speak to Elder Kekek       2,100 XP       ?            ?

── grinding here: 520/min (rested: 1,040/min) ──
```

---

## 8. Modifiers

`Modifiers.lua` maintains the current multiplier state and tells the estimator what is real:

| Source | Detection | Applies to |
|---|---|---|
| Rested | `GetXPExhaustion()` + parsed `EXHAUSTION1/2` bonus captures | Kill XP only |
| Heirlooms | Scan `INVSLOT_SHOULDER`, `CHEST`, `FINGER1`, `FINGER2` against the item-ID list on `UNIT_INVENTORY_CHANGED` and `PLAYER_LOGIN`; tooltip-scrape fallback for server-custom items | Kill **and** quest XP; compounds multiplicatively |
| XP disabled | `IsXPUserDisabled()` | Everything — the addon shows a clear disabled state rather than dividing by zero |
| Group | Parsed group-bonus captures when present | Kill XP; effectively never fires on TC/AC (§3.6) |
| RAF | **Undetectable** — no client API | Documented limitation; the learned rates absorb it as a rate change |
| Unknown server buffs | Any `UNIT_AURA` change that coincides with a step change in observed rate | Not modelled; the rolling median absorbs it |

The user-facing setting here is minimal and matches the approved scope: a per-source **include/exclude in the projection**, so you can tell the addon "don't count rested in my time-to-level" if you are about to run out anyway. It is not a what-if simulator.

---

## 9. UI and appearance

### 9.1 Bar

A `StatusBar` with the current-XP fill, plus a rested/projection overlay drawn as a **Texture on the `BORDER` layer inside the StatusBar**, re-anchored `TOPRIGHT` to the bar's `TOPLEFT` plus an offset — which is exactly how Blizzard does it at `MainMenuBar.lua:337-339`, not a second StatusBar.

⚠ The 3.3.5a XP bar does **not** draw 20 tick segments; there are zero `BarDiv` frames in build 12213. The segmented look comes from four overlay textures TexCoord-cut from `Interface\MainMenuBar\UI-MainMenuBar-Dwarf`. If we want segments we draw them ourselves as thin textures.

Bar textures: `Interface\TargetingFrame\UI-StatusBar` (confirmed), `Interface\ChatFrame\ChatFrameBackground` for a flat tintable fill. ⚠ `Interface\Buttons\WHITE8X8` could **not** be confirmed on 3.3.5a — do not use it.

Movable, `SetClampedToScreen(true)`, position saved as point/relativePoint/x/y with the relative frame stored **by name**.

### 9.2 Box

A separate movable frame with the numbers, offering a few layout presets (`compact` one-line, `stacked` two-column, `full` labelled rows) plus a per-line visibility toggle.

### 9.3 Theming

Per the request — colour wheel plus opacity on every element, a few fonts, and standard size options:

- **Colour + alpha** via `ColorPickerFrame` with `hasOpacity = true`, for: bar fill, bar rested overlay, bar background, bar border, box background, box border, and each text line independently (label, value, and the good/neutral/bad recommendation colours).
- **Fonts:** the four the client ships — `Fonts\FRIZQT__.TTF`, `ARIALN.TTF`, `MORPHEUS.TTF`, `SKURRI.TTF` — with size and outline (`none`/`OUTLINE`/`THICKOUTLINE`) per text element.
- **Sizes:** bar width/height, box scale, spacing.

⚠ `OptionsSliderTemplate` does not snap to `SetValueStep` while dragging on 3.3.5a — round manually in `OnValueChanged`.
⚠ Widgets built from `UICheckButtonTemplate`/`OptionsSliderTemplate` **must be given a name**, or `$parentText` substitution fails and the labels never appear.

### 9.4 Options panel

Native `InterfaceOptions_AddCategory` with sub-panels: General, Appearance, Quests, Data. No Ace3.

### 9.5 Slash commands

`/lp` and `/levelpace`: bare opens options; `reset` clears the current tracking window (the only filter that exists); `quests` prints the ranking to chat; `lock`/`unlock`; `debug` dumps the last 20 parsed XP events for troubleshooting.

---

## 10. Testing

WoW addons resist testing because everything is a global. The mitigation is a **hard boundary**: `Ledger`, `Rates`, `Estimator`, `Quests` (the effort model), and `Data/XPTable` are pure functions over plain tables. They never touch a frame.

A harness under `tests/` provides a mock WoW environment — the real 3.3.5a global strings, stub `UnitXP`/`GetQuestLogRewardXP`/`GetXPExhaustion`, and a fake clock — and runs the modules under a standalone Lua 5.1 interpreter (LuaJIT; ⚠ **not** system Lua 5.5, whose `unpack`/integer-division/`#`-on-holes semantics differ from the target).

Test-first, with these as the non-negotiable cases:

1. Every one of the 12 XP-gain global strings parses, including `_GROUP` variants, and **most-specific-first ordering is asserted** — the known trap where `EXHAUSTION1` swallows a `_GROUP` message.
2. `ConvertGlobalString` correctly escapes `+` and `-` (the documented naive-converter failure).
3. XP delta across a level-up, and across **two** level-ups in one gain.
4. Quest vs exploration disambiguation from identical `"You gain %d experience."` text.
5. `BaseGain` reproduces TrinityCore's integer truncation exactly, at content-tier boundaries and across the gray cliff (a level-70 gets 0 from a level-61 but 492 from a level-62).
6. Rested piecewise projection: pool larger than remaining XP, smaller, and exactly equal.
7. Rate learning converges, and reports `nil` below the sample threshold rather than a wrong number.
8. Quest ranking handles the unmeasurable bucket without producing a number.
9. `XPTable` matches `UnitXPMax` at every level, and the override path engages on a server with a custom table.

In-game verification is manual and unavoidable for the UI layer; the spec accepts that.

---

## 11. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | **Locale.** All parsing is enUS. A deDE/ruRU client breaks the Ledger entirely. | Total loss of function | Patterns are built from the *live* `_G` global strings, not hardcoded English, so it adapts automatically. The heirloom tooltip scrape is the one genuinely locale-bound path, and it is a fallback only. |
| 2 | **Quest-rate learning needs turn-ins.** Cold start gives no recommendation. | Feature unavailable for the first few quests | Show "learning (2/3 quests)" rather than a wrong number. Persist per realm so it is one-time. |
| 3 | **Server customisation.** `creature_template.ExperienceModifier`, `MinCreatureScaledXPRatio`, edited `player_xp_for_level`, custom XP auras. | Kill-rate learning degrades | The empirical path does not depend on the formula. Formula use is confined to the optional "mobs to level at an unfought level" nicety, and `XPTable` self-validates against `UnitXPMax`. |
| 4 | **`SelectQuestLogEntry` side effects.** It moves the user's visible selection. | Visible UI glitch | Save/restore around the scan; debounce so it runs rarely. Blizzard's own code does exactly this. |
| 5 | **SavedVariables lost on crash.** No flush API. | Lost history since last logout | Accepted. Data is re-derivable by playing. Document it. |
| 6 | **Unmeasurable quests are common.** Escorts, travel, "speak to". | Ranking covers less than 100% of the log | Honest `?` display. Never fabricate. |
| 7 | **RAF undetectable.** | Rates silently shift 3x mid-session | Rolling median re-converges; a step change in rate is annotated in the tooltip. |
| 8 | **`GetQuestLogRewardXP` timing.** Must read before the quest leaves the log. | Rate learning silently gets no samples | `hooksecurefunc("GetQuestReward")` captures at the right moment; test asserts a sample is produced. |
| 9 | **Unknown-event registration is a hard error** on 3.3.5a. | Addon fails to load | Every non-§3.1 event goes through a `pcall`-wrapped safe register. |
| 10 | **Testing on Lua 5.5 masks 5.1 bugs.** | False confidence | Harness runs under LuaJIT; CI-equivalent check refuses to run on a non-5.1 interpreter. |

---

## 12. Open decisions for the user

1. **The name `LevelPace`** — cheap to change now, annoying later.
2. **Minimap button.** Not in the approved scope. `LibDataBroker-1.1` + `LibDBIcon-1.0` is ~12KB and the one library exception arguably worth taking (it gives free Titan Panel / ChocolateBar compatibility). Currently **excluded**; say if you want it.
