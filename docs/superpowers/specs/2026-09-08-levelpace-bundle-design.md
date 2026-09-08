# LevelPace Bundle — Design Spec

**Date:** 2026-09-08
**Supersedes:** nothing. Extends `2026-09-08-levelpace-design.md`.
**Status:** awaiting user review.

Three feature modules in one addon, three dashboards, each independently
toggleable, backed by Cloudflare Workers + D1.

| Module | Domain | State |
|---|---|---|
| **LevelPace** | XP, levelling pace, quest-vs-grind advice | built (v0.4.2) |
| **Nemesis** | Battleground PvP | new |
| **RareFinder** | Rare mob kills | new |

---

## 0. Decisions this document makes

Three design documents were produced in parallel and reviewed by three
adversarial critics. The critics found the documents contradicted each other on
eight load-bearing decisions. **This document is the authority.** Where it
disagrees with any working document, this wins.

| # | Question | Decision |
|---|---|---|
| D1 | Auth scheme | Bearer token. Server stores `sha256(key)` only. **No HMAC, no root secret, no recovery codes.** |
| D2 | Character identity | `char_id = sha256(lower(name) ‖ "@" ‖ lower(realm))[:16]`, derived **server-side**. A client-supplied `charId` is ignored. |
| D3 | Impersonation rule | **First install to submit a character owns it.** One column, `owner_install`. No claim/release/rebind protocol. |
| D4 | Character name on the wire | `name` and `realm` become **mandatory** blob fields, separate from the existing opt-out `display`/`shareRealm` privacy settings. See §4.4.1. |
| D5 | RareFinder log | **Every kill**, not first-kills-only. |
| D6 | RareFinder ranking | **Rare kill count**, colour-banded, exactly as asked. Rarity-weighting is a secondary sort, never a replacement. |
| D7 | "Lifetime BG statistics" | Split honestly: lifetime honorable kills are **real** (server-supplied); win/loss records are **since install**. Labelled as such in the UI. |
| D8 | Board window styling | Gets the full colour/opacity/font/size treatment, like every other element. |
| D9 | Static publish credential | Must **not** be able to write `api/config.json`. The control plane is not writable by the thing it addresses. |
| D10 | Legacy token migration | Accepted into a **quarantine**: stored, never ranked, never creates ownership. |

### What this design does NOT do

Stated up front so no one has to infer it.

- **It does not stop you faking your own numbers.** The data is produced by a
  client the player controls, in a file they can open in Notepad. Everything
  below raises the cost of *impersonating someone else* and of *submitting
  impossible values*. Nothing makes "is this number true" answerable. Any
  sentence in any working document claiming otherwise is wrong and is overruled
  here.
- **It does not have accounts.** No signup, no email, no password, no invite, no
  OAuth, no recovery flow. This was an explicit, emphatic user requirement and
  the review found earlier drafts had quietly re-introduced account semantics
  under other names.
- **It does not require the user's Mac.** After cutover, nothing runs at home.

---

## 1. Global constraints

Copied verbatim into every implementation plan.

- **WoW 3.3.5a only** (client build 12340, Interface 30300). Private servers
  (TrinityCore / AzerothCore).
- **No API added after 3.3.5a.** No `C_*` namespaces, no `C_Timer`, no nameplate
  unit tokens, no hyphen-separated GUIDs, no `CombatLogGetCurrentEventInfo`.
- **Lua 5.1, zero dependencies.** No `os`, no `io`, no sockets, no HTTP.
- **SavedVariables are written only on logout, `/reload`, or disconnect.** There
  is no flush API on 3.3.5a.
- **One addon folder, one TOC, one download.**
- **Every visible element gets** colour wheel + opacity + font + size.
- **Free or near-free hosting.** No paid compute tier.
- **Must not touch `unformentoo.org`** or the existing `unformentoo` D1 database.
- **No secret is ever pasted into chat.** `wrangler login` and
  `wrangler secret put` only.

---

## 2. What the API research established

A critic verified every client-API claim against primary sources: Blizzard's
own `## Interface: 30300` FrameXML, the shipping 3.3.5a addon
`BattlegroundTargets-WotLK`, and AzerothCore's battleground source. **No
hallucinated API was found.** The following are confirmed correct for 3.3.5a
and are the foundation of the Nemesis module.

| API | Confirmed detail | Source |
|---|---|---|
| `GetBattlefieldScore(i)` | 12 returns; `rank` at 7, `classToken` at 10. **Modern wiki pages get this wrong.** | `WorldStateFrame.lua:662` |
| `GetNumBattlefieldScores()` | enemy players included; `faction` 0=Horde 1=Alliance | — |
| `RequestBattlefieldScoreData()` | required to refresh; must be throttled | — |
| `GetBattlefieldInstanceRunTime()` | **milliseconds** | `WorldStateFrame.lua:824` |
| `GetBattlefieldStatInfo(i)` | → `text, icon, tooltip` | `:600` |
| `GetBattlefieldStatData(i, statIndex)` | — | `:731` |
| `SetBattlefieldScoreFaction()` | — | `:922` |
| `IsActiveBattlefieldArena()` | — | `:461` |
| `GetNumBattlefieldFlagPositions()` / `GetBattlefieldFlagPosition(i)` | **exist in 3.3.5a** | `WorldMapFrame.lua:874-876` |
| `PLAYER_ENTERING_BATTLEGROUND` | fires | `:59` |
| `PLAYER_PVP_KILLS_CHANGED`, `GetPVPLifetimeStats()` | 2 returns; **true lifetime**, server-supplied | `PVPFrame.lua:15, :513` |
| `GetGuildInfo(unit)` | 3 returns; **unit token only, never a name** | — |
| `UnitClassification(unit)` | `"rare"` / `"rareelite"` | — |
| `bit.band` | available | — |

**Two negative findings that change the design:**

1. **`PlaySoundFile` returns nothing on 3.3.5a.** There is no success/failure
   signal, so the addon cannot detect a bad sound path. Sound options must be a
   fixed list of known-good paths, not free text.
2. **There are no GlobalStrings for flag events.** Flag pickup/capture/return
   text is server-generated and arrives as plain `CHAT_MSG_BG_SYSTEM_*` chat.
   The `ConvertGlobalString` technique **does not apply**. See §5.3 — this is
   the single biggest deviation from my initial estimate to the user.

### GUID decode — verified against the user's own server

The user targeted a mob and produced `0xF13000020D02DD76`.

```
F130          type   = HIGHGUID_UNIT (creature)
    00020D    entry  = 525          -> Mangy Wolf, Elwynn Forest
          02DD76  spawn counter
```

```lua
-- CORRECT: full 24-bit entry
local npcID = tonumber(string.sub(guid, 7, 12), 16)
```

`string.sub(guid, 9, 12)` — which I stated to the user earlier — reads only the
**low 16 bits**. It is correct for every Blizzlike WotLK creature (max entry
38453) and silently decodes custom server NPCs at entry ≥ 65536 as **0**.
`sub(7, 12)` costs the same and has no failure mode. Type is `string.sub(guid, 3, 6)`;
only `F130` is a creature.

---

## 3. Architecture

### 3.1 One addon, three modules

```
LevelPace/
  Core.lua            event bus, scheduler, SavedVariables, module registry
  Compat.lua          util: string conversion, median, percentile, format
  Modules/
    LevelPace/        XP, quests, estimator   (existing files moved)
    Nemesis/          battleground PvP        (new)
    RareFinder/       rare mob kills          (new)
  UI/
    Lib.lua           NEW: shared frame/widget factory
    Board.lua         dashboard host, one tab per enabled module
    Options.lua       options host, one tree per module
  Data/
    XPTable.lua       existing
    Rares.lua         NEW: 420-entry rare catalogue
  Init.lua            bootstrap, strictly last
```

`LP.modules` already exists at `Core.lua:16` and **is never read or written
anywhere in the codebase.** It becomes the registry — the one piece of this
refactor that costs nothing.

### 3.2 The module contract

```lua
LP:RegisterModule({
  id      = "nemesis",           -- saved-variable namespace, slash prefix
  title   = "Nemesis",
  default = true,                -- enabled on a fresh install
  events  = { "PLAYER_ENTERING_BATTLEGROUND", ... },
  OnEnable  = function(self) end,
  OnDisable = function(self) end,
  Options   = function(self) return { ... } end,
  Dashboard = function(self, parent) return frame end,
  Export    = function(self) return { ... } end,
})
```

**Disable semantics — decisive:** a disabled module unregisters its WoW events,
stops collecting, and loses its dashboard tab. Its stored data is **kept**. The
alternative (collect silently while hidden) burns CPU in a 40-player
battleground for output nobody asked for, and the user framed these as things
to turn *off*, not hide.

### 3.3 The shared WoW-event router — the one real refactor

Today **every module opens its own hidden `CreateFrame` and registers WoW events
directly.** With three modules that is triple the frames and triple the
`COMBAT_LOG_EVENT_UNFILTERED` handlers — and CLEU in a 40-player battleground is
the single hottest path in the addon.

One frame, one CLEU handler, dispatching to registered consumers:

```lua
-- NORMATIVE. 3.3.5a CLEU: 8 base args, no hideCaster, no raid flags.
dispatch(timestamp, subevent, srcGUID, srcName, srcFlags,
         dstGUID, dstName, dstFlags, ...)
```

This signature is written once here because the working documents disagreed
about it. Handlers receive exactly these arguments in exactly this order.

**Bail-out order inside the CLEU handler**, cheapest test first:
1. `subevent` not in the interested set → return
2. `string.sub(dstGUID, 3, 6) ~= "F130"` → return (not a creature)
3. only then decode the entry and do a table lookup

### 3.4 Event bus — verified behaviour

Confirmed by execution against the real code:
- A handler that raises is contained by `pcall`; the rest still run.
- A handler registered *during* a `Fire` of the same event does **not** run in
  that pass. The numeric `for` limit is evaluated once.
- **There is no unsubscribe path.** `handlers` is file-local at `Core.lua:23`
  and never exposed. Module disable therefore cannot work by unsubscribing from
  the bus — it must gate at the WoW-event router (§3.3) plus an `enabled` check.
  Adding unsubscribe is the alternative and is more invasive; the gate is chosen.

---

## 4. Security model

### 4.1 Trust boundary

The client is fully attacker-controlled: the companion is a `.ps1` the user can
read, and the addon's SavedVariables is a text file they can edit. **Everything
here is about impersonation and impossible values, not truthfulness.**

### 4.2 Enrolment — no accounts, no interaction

On first run the companion has no key. It POSTs `/api/enrol` with nothing.

```
POST /api/enrol
  -> 200 { "installId": "...", "key": "<32 random bytes, base64url>" }
```

The Worker generates the key with `crypto.getRandomValues`, stores **only**
`sha256(key)`, and returns the key **once**. The companion writes it to
`%LOCALAPPDATA%\LevelPace\install.key` (mode: user-only).

A D1 dump contains no usable key. There is no root secret, so there is no
single point of total forgery. PowerShell 5.1 needs no crypto library — it sends
a bearer header.

**Key loss = identity loss.** No recovery codes; that is account machinery. The
honest statement to users: *keep `install.key`; if you lose it your history
stays on the board under your name but you can no longer add to it, and you
should tell the operator.*

### 4.3 Every subsequent write

```
POST /api/submit
  Authorization: Bearer <key>
```

Worker computes `sha256(key)`, looks up `installs.key_hash`. No match → 401.

Rejected alternatives, recorded so they are not re-proposed: HMAC request
signing (needs crypto in PowerShell 5.1, needs a nonce store to stop replay,
and buys nothing over TLS + a bearer token here); derived keys from a root
secret (one leak forges every identity).

### 4.4 Character ownership — first writer wins

```sql
characters (
  char_id       TEXT PRIMARY KEY,   -- sha256(lower(name)@lower(realm))[:16]
  name          TEXT NOT NULL,
  realm         TEXT NOT NULL,
  owner_install TEXT NOT NULL REFERENCES installs(install_id),
  first_seen    INTEGER NOT NULL
)
```

`char_id` is **derived server-side** from `name` + `realm` in the blob. A
client-supplied `charId` is ignored entirely.

Every write is `... WHERE char_id = ?1 AND owner_install = ?2` with
`?2` = the caller. A mismatch is a **409**, not a silent no-op.

This closes the hole the security critic found: in the earlier draft `char_id`
was client-chosen *and* publicly enumerable via the rare-log cursor, so any
enrolled user could overwrite any other player's rows using a perfectly valid
key.

**Realm is part of the key**, so two players genuinely named `Thrall` on
different realms do not collide.

#### 4.4.1 Identity fields vs privacy fields

Found by reading the code rather than the design documents, and missed by all
three critics:

`Export.lua:102-103` currently emits

```lua
display = (share.alias ~= "" and share.alias) or name,
realm   = share.shareRealm ~= false and realm or nil,
```

So today there is **no `name` field at all**, and **`realm` is behind a
user-facing privacy toggle** (`Options.lua:394`). A player who turns realm
sharing off sends no realm — which would make `char_id` underivable for exactly
those players, and would silently remove their collision protection.

The blob therefore gains two fields that are **identity, not presentation**, and
are always sent:

| Field | Always sent? | Shown on the board? | Purpose |
|---|---|---|---|
| `name` | **yes** | no | derives `char_id` |
| `realm` | **yes** | only if `shareRealm` | derives `char_id`; disambiguates same-named players |
| `display` | yes | **yes** | the alias the player chose, presentation only |
| `showRealm` | yes | — | carries the existing privacy preference to the server |

The privacy toggle keeps working — it now controls **display**, not
transmission. This must be stated plainly in the options tooltip: the realm is
sent to tell two same-named characters apart, and is not shown when the toggle
is off. Quietly widening what gets uploaded while leaving a checkbox that
implies otherwise would be a dishonest change.

**The honest failure case:** if an impersonator submits your character before
you do, they own it and you are locked out. There is no automated fix, because
any automated fix is an account system. The operator can reassign
`owner_install` with one SQL statement. At this scale — a guild — that is the
right trade.

### 4.5 Validation: reject vs flag

Extends the existing `inspect_level` pattern.

| Domain | Reject (impossible) | Flag (implausible) |
|---|---|---|
| Levelling | negative time; level outside 1–80; XP above the level's maximum | levels/hour above the observed population's 99.5th percentile |
| Nemesis | kills > scoreboard total; BG duration > `GetBattlefieldInstanceRunTime()`; negative counters | killing blows per minute above population 99.5th |
| RareFinder | `npc_id` outside 24-bit range; timestamp in the future | kills of the same rare closer together than its minimum respawn |

**`npc_id` acceptance rule — one rule, one place:** accept if the id is in the
bundled 420-entry catalogue **or** the submission carries a matching `learned`
record with `rank ∈ {2, 4}` observed via `UnitClassification`. Learned-only
kills are stored **flagged**, so private-server custom rares work without the
catalogue becoming a hard gate that silently deletes them.

Note honestly: the catalogue ships **inside the addon**, so it is not a security
control. It is a data-quality filter. An earlier draft called it "the single
strongest check in the whole system"; that is false and is overruled.

### 4.6 Rate limits

| Route | Limit | Why |
|---|---|---|
| `/api/enrol` | 5 / hour / IP | enrolment is the cheapest board-stuffing attack and has no auth by definition |
| `/api/submit` | 60 / hour / install | a real companion syncs every few minutes |
| reads | 1000 / hour / IP | Pages absorbs normal load |

### 4.7 Threat table

| Attack | Stopped? | By what |
|---|---|---|
| Read the shipped download, submit as someone else | **Yes** | no shared secret ships; keys are per-install and server-side hashed |
| Overwrite another player's rows with a valid key | **Yes** | `owner_install` predicate on every write |
| Steal a D1 dump and forge | **Yes** | only `sha256(key)` is stored |
| Enrol 500 identities and stuff the board | **Partly** | enrolment rate limit; median-of-percentiles ranking |
| Claim a character before its real owner | **No** | inherent; operator fixes by hand |
| Edit SavedVariables and inflate your own stats | **No** | inherent and permanent — see §0 |
| Replay a captured submit | **Partly** | TLS; writes are idempotent per `(char_id, level)` |

---

## 5. Nemesis module

### 5.1 Enemy joined / left

Poll `RequestBattlefieldScoreData()`, read on `UPDATE_BATTLEFIELD_SCORE`, diff
the enemy-faction set between polls.

- **Throttle: 3 s**, and only while `PLAYER_ENTERING_BATTLEGROUND` has fired and
  `IsActiveBattlefieldArena()` is false.
- The scoreboard lists players *currently present*, so a departure is a real
  "left" — with the caveat that a player who leaves is indistinguishable from
  one the server dropped from the scoreboard momentarily. Two consecutive
  missing polls before announcing.

### 5.2 Arch Nemesis alerts

The enemy set from §5.1 intersected with the existing nemesis list in
`PvP.lua`. Fires `NEMESIS_SPOTTED` with the name and the standing kill/death
record against them.

### 5.3 Flag carrier announcements — **corrected**

I told the user this would reuse the existing `ConvertGlobalString` machinery.
**That was wrong.** The critic verified there are no GlobalStrings for flag
events in 3.3.5a; the text is server-generated and arrives as plain chat on
`CHAT_MSG_BG_SYSTEM_ALLIANCE` / `_HORDE` / `_NEUTRAL`.

Two consequences:

1. Patterns must be **literal English substrings** (`"was picked up by"`,
   `"captured"`, `"was returned"`), which breaks on non-English servers and on
   servers that reworded their BG messages.
2. Therefore the **primary** source is `GetNumBattlefieldFlagPositions()` /
   `GetBattlefieldFlagPosition(i)` — confirmed present at
   `WorldMapFrame.lua:874-876` — which is language-independent and gives
   position. Chat parsing becomes the *fallback* that supplies the carrier's
   name, since flag positions do not carry one.

This inverts the priority I originally described and is a genuine downgrade in
robustness. It is still worth building; it is not the clean win I implied.

### 5.4 Enemy guild names — partial, and labelled

`GetGuildInfo` takes a **unit token**, and 3.3.5a has no nameplate tokens. Guild
is readable only for `target`, `mouseover`, or `focus`.

Capture opportunistically on `UPDATE_MOUSEOVER_UNIT` and `PLAYER_TARGET_CHANGED`,
cache by `name@realm`, and accumulate across matches. The UI must show coverage
honestly — *"guilds known: 6 of 15"* — never a blank that reads as "no guild".

### 5.5 Kill / death / streaks

Extends existing `PvP.lua`. `PARTY_KILL` fires **for the killer only**; the
victim never sees it, so deaths come from `PLAYER_DEAD` plus the last-damage
heuristic already implemented.

Current streak, longest streak. **Streak state is in-memory, never persisted** —
this repeats the fix for the Bloodbath false positive, where persisted
`GetTime()` values looked future-dated because `GetTime()` restarts at zero
every session.

### 5.6 Lifetime battleground statistics — split honestly

| Statistic | Source | Truthfulness |
|---|---|---|
| Lifetime honorable kills | `GetPVPLifetimeStats()` | **real** — server-supplied, spans the character's whole life |
| BG wins / losses | accumulated per match | **since install only** |
| Per-BG breakdown | accumulated per match | **since install only** |

The UI labels the since-install ones. A known gap, stated rather than hidden:
**if the player leaves before the winner is declared, that match is never
recorded.** `GetBattlefieldWinner()` only returns on completion.

### 5.7 Sound alerts

Per-event toggles: enemy joined, nemesis spotted, flag taken, flag capped, kill,
death, streak milestone.

`PlaySoundFile` returns nothing on 3.3.5a, so a bad path fails silently. Sounds
are therefore a **fixed dropdown of known-good paths**, plus optional files
shipped in the addon folder. No free-text path field.

---

## 6. RareFinder module

### 6.1 Detection

On CLEU `UNIT_DIED` / `PARTY_KILL`, after the §3.3 bail-outs, decode the entry
and look it up in `Data/Rares.lua`.

**This sees rares killed by anyone in combat-log range, not only your own kills**
— which is what makes a shared log interesting.

Independently, on `PLAYER_TARGET_CHANGED` / `UPDATE_MOUSEOVER_UNIT`, if
`UnitClassification` is `"rare"` or `"rareelite"`, record a `learned` entry.
This is how custom server rares enter the system (§4.5).

### 6.2 The catalogue

`data/rares_335.json` — **420 entries**, already generated and committed:

- 300 rank 4 (rare), 120 rank 2 (rare elite)
- 372 vanilla, 21 BC, 27 WotLK
- entry range 61–38453

Spot-verified: `32491 Time-Lost Proto Drake`, `32517 Loque'nahak`, `35189 Skoll`,
`38453 Arcturis`, `32485 King Krush`. Mangy Wolf (525) correctly **absent**.
Build step converts it to `Data/Rares.lua`.

### 6.3 The log and the ranking — as asked

The user asked for two things and an earlier draft quietly substituted
something else for both. Corrected:

- **The log:** who killed what rare, when. **Every kill is a row.** The earlier
  "first-kills index" dropped repeat kills, which destroys exactly the "X killed
  Time-Lost Proto Drake again" moment that makes this fun.
- **The ranking:** **rare kill count**, percentile-ranked into the same
  grey/green/blue/purple/orange/pink/gold bands as the other two boards.

A count rewards volume. That is a real property and it is noted — but the user
asked for a count board with colour bands, so that is what gets built.
Rarity-weighting is available as a **secondary sort column**, never as a silent
replacement for the requested metric.

---

## 7. Ranked metrics

| Board | Metric | Why not the obvious alternative |
|---|---|---|
| LevelPace | levels per hour | unchanged |
| Nemesis | **killing blows per BG minute** | K/D rewards not playing; raw kills reward no-lifing |
| RareFinder | **rare kills** | as requested (§6.3) |

Percentile uses **`n - 1`** as the divisor when the player is in their own
population — preserving the fix that stopped the faster of two players being
capped at 50. A single-entry population returns no band, not 100.

Nemesis requires **≥ 30 BG minutes** before banding, or one lucky 2-minute match
tops the board.

---

## 8. Data model (D1)

```sql
installs   (install_id TEXT PK, key_hash TEXT UNIQUE NOT NULL, created INTEGER)
characters (char_id TEXT PK, name, realm, owner_install, first_seen)

levels     (char_id, level, seconds, xp, flags, PRIMARY KEY (char_id, level))
bg_matches (char_id, bg_id, started, duration_ms, won, kbs, deaths, flags)
bg_lifetime(char_id PK, honorable_kills, updated)
nemeses    (char_id, enemy_name, enemy_realm, kills, deaths, guild)
rare_kills (id INTEGER PK, char_id, npc_id, killed_at, learned INTEGER DEFAULT 0)

parse      (char_id, board TEXT, metric REAL, band TEXT, updated)
quarantine (id INTEGER PK, payload TEXT, received INTEGER)   -- §10 legacy
```

Indexes: `rare_kills(npc_id, killed_at)`, `rare_kills(char_id)`,
`bg_matches(char_id, started)`, `parse(board, metric DESC)`.

Every leaderboard query is bounded by `LIMIT` with keyset pagination — D1's free
tier bills **rows read**, and an unbounded `ORDER BY` over the kill log is the
one query here that could plausibly exhaust it.

---

## 9. Hosting and cost

```
Cloudflare Worker  levelpace.<subdomain>.workers.dev   API + writes
Cloudflare D1      levelpace                            (separate from `unformentoo`)
GitHub Pages       monscorps.github.io/levelpace        static board, read-only fallback
GitHub Releases    one URL for downloads
```

No custom domain. Nothing touches `unformentoo.org`.

| Users | Requests/day | Binding limit | Cost |
|---|---|---|---|
| 10 | ~500 | none | £0 |
| 100 | ~5,000 | none | £0 |
| 1000 | ~50,000 | Workers free tier is 100k/day | £0, tight |

Beyond ~1000 users the Workers paid plan is $5/month. The user already pays
Cloudflare.

**The board stays readable when the API is down**, because Pages serves the last
published snapshot. This is why Pages is kept rather than folded into the Worker.

### 9.1 The publish credential

The Worker publishes static JSON to Pages. Its credential's allowed path prefix
is `docs/api/` **minus `config.json`**.

`api/config.json` is the control plane — it is how every companion in the world
discovers where to upload. A credential that can rewrite it can redirect every
client's uploads to an attacker. The thing being addressed must not be able to
rewrite its own address.

---

## 10. Migration

The companion calls `Get-Config` at the top of **every** sync and re-reads
`api/config.json`. That is the migration lever: **point `config.json` at the
Worker and every installed companion moves on its next sync, with no
re-download.**

Ordered cutover:

1. `wrangler d1 create levelpace` — separate database, `unformentoo` untouched
2. Apply schema; import existing SQLite via `wrangler d1 execute --file`
3. Deploy the Worker; verify `GET /api/stats` = 200 and unauthenticated
   `POST /api/submit` = **401**
4. Ship the companion that enrols (§4.2)
5. Flip `api/config.json` to the Worker URL
6. Watch the quarantine table drain as clients upgrade
7. Retire: launchd agent, quick tunnel, `run-everything.command`, the Mac

**Legacy tokens during the window (§0 D10):** a v1 blob authenticates but lands
in `quarantine`. It never creates a `characters` row, never produces a `parse`
row, never reaches the board. Shown as *"unverified — update your companion"*.
A v1 blob must never be able to create or satisfy ownership, or the whole of
§4.4 is bypassable for as long as the window is open.

**Rollback:** flip `config.json` back. The Mac server and its database still
exist until step 7, which is why step 7 is last.

---

## 11. Build order

Each stage ships something working.

| Stage | Contents | Unblocks |
|---|---|---|
| **1** | Module registry, WoW-event router, `UI/Lib.lua`, per-module toggles. LevelPace becomes a module. **No behaviour change.** | everything |
| **2** | Worker + D1 + enrolment + ownership. Cutover. | real hosting |
| **3** | RareFinder — smallest new module, exercises the router and the new board end to end | proves the framework |
| **4** | Nemesis — largest, most API surface, most uncertainty | — |

Stage 1 is deliberately a no-op refactor with the existing 600-assertion test
suite as its acceptance gate. Building Nemesis on an unrefactored core, then
refactoring underneath it, is how this becomes a rewrite.

---

## 12. Open questions for the user

1. **workers.dev subdomain name** — proposed `levelpace`.
2. **Impersonation fix** is a manual SQL statement by the operator (§4.4). At
   guild scale that is right; confirm it is acceptable.
3. **Non-English server?** §5.3's chat fallback assumes English BG messages.

---

## 13. Review record

13 agents: 6 research, 4 design, 3 adversarial critics. **79 findings** — 13
critical, 34 high, 27 medium, 5 low.

The critics' most valuable catches, all incorporated above:

- **The character name is not on the wire.** `Export.lua:99` emits
  `display = alias or name` and no `name` field, so every identity scheme in
  every draft was underivable. Found by reading the actual code.
- **`char_id` was client-chosen and enumerable**, letting any enrolled user
  overwrite any other player's rows with a valid key.
- **Account semantics had crept back in** as claim/release/rebind/recovery-code
  machinery — the exact thing the user rejected.
- **RareFinder had been silently downgraded** on both of its two requested
  features.
- **Security prose overclaimed**, calling a check that ships inside the addon
  "the strongest check in the whole system".
- **No hallucinated 3.3.5a API**, verified against Blizzard's own FrameXML —
  including that `GetBattlefieldScore`'s return order in modern wikis is wrong.
