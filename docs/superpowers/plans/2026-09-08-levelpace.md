# LevelPace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A World of Warcraft 3.3.5a addon that tracks XP honestly and ranks the quests in your log by XP per minute of measured effort against your grind rate.

**Architecture:** Zero-dependency plain Lua 5.1. A `Ledger` parses XP-gain chat into structured events; every other module consumes structured events and never touches text. Pure modules (`Compat`, `XPTable`, `Ledger`, `Rates`, `Estimator`, `Quests`) are testable outside the game under LuaJIT with a mock WoW environment. UI modules are thin and verified manually in-game.

**Tech Stack:** Lua 5.1 (WoW 3.3.5a client), LuaJIT 2.1 for the test harness, no external libraries.

**Spec:** `docs/superpowers/specs/2026-09-08-levelpace-design.md` — read it before starting. Section references below (§3.3, §5.2 etc.) point into it.

## Global Constraints

- Target client is **WoW 3.3.5a only**, `## Interface: 30300`. No other client version.
- **Zero runtime dependencies.** No Ace3, no LibStub, no LibDataBroker. Bundle nothing.
- **Lua 5.1 semantics only.** No `goto`, no integer division `//`, no `table.unpack` (use `unpack`), no `os.*`, no `io.*`. Tests run under `luajit`, never system `lua` (which is 5.5 here).
- **Addon folder and TOC basename must both be exactly `LevelPace`** or the client silently fails to load it.
- **Never register an event not confirmed to exist on 3.3.5a** — it raises a hard Lua error. Route every registration through `LP.util.SafeRegisterEvent`.
- **Never hardcode English strings for parsing.** Build patterns from the live `_G` globals so other locales work.
- All files are listed in the TOC in dependency order. Lua files do not `require`; they share the `LevelPace` global.
- Global namespace budget: exactly three globals — `LevelPace`, `LevelPaceDB`, `LevelPaceCharDB`. Everything else is `local`.

---

## File Structure

```
LevelPace/                     <- this folder is what gets copied to Interface\AddOns\
  LevelPace.toc
  Core.lua                     -- addon table, event bus, scheduler, saved-vars bootstrap
  Compat.lua                   -- ConvertGlobalString, SafeRegisterEvent, formatting helpers
  Data/XPTable.lua             -- player_xp_for_level 1-79, heirloom IDs, BaseGain formula
  Ledger.lua                   -- the ONLY text parser; emits normalised XP events
  Modifiers.lua                -- rested pool, heirloom scan, XP-disabled state
  Rates.lua                    -- learns server Rate.XP.Kill / Rate.XP.Quest
  History.lua                  -- per-level records, persistence
  Estimator.lua                -- time-to-level, mobs-to-level, confidence
  Quests.lua                   -- quest scan, objective-tick timing, effort, ranking
  UI/Bar.lua                   -- XP StatusBar + rested overlay
  UI/Box.lua                   -- stats box, layout presets
  UI/Tooltip.lua               -- hover detail
  UI/Options.lua               -- Interface Options panel, colour pickers, sliders
tests/
  harness.lua                  -- mock WoW environment + assertion helpers
  run.sh                       -- runs every test_*.lua under luajit
  test_compat.lua
  test_xptable.lua
  test_ledger.lua
  test_rates.lua
  test_estimator.lua
  test_quests.lua
```

**Responsibility boundaries:** `Ledger` is the only module allowed to call `string.match` on a chat message. `UI/*` is the only code allowed to call `CreateFrame`. `Estimator` and `Quests` are pure functions over tables passed in — they read no WoW globals directly, which is what makes them testable.

---

## Task 1: Test harness and addon skeleton

Gets a loadable addon plus a working test runner. After this task you can log in and see it load.

**Files:**
- Create: `LevelPace/LevelPace.toc`
- Create: `LevelPace/Core.lua`
- Create: `tests/harness.lua`
- Create: `tests/run.sh`
- Create: `tests/test_core.lua`

**Interfaces produced:**
- `LevelPace` table with: `LP.modules`, `LP:On(event, fn)`, `LP:Fire(event, ...)`, `LP:Schedule(interval, fn)`, `LP:Print(...)`, `LP.VERSION`
- `tests/harness.lua` returns `harness` with `harness.reset()`, `harness.setTime(t)`, `harness.advance(dt)`, `harness.load(path)`, `harness.eq(a,b,msg)`, `harness.near(a,b,tol,msg)`, `harness.ok(v,msg)`, `harness.run(name, fn)`, `harness.report()`

- [ ] **Step 1: Write `tests/harness.lua`**

Provides the mock WoW environment. Must define, at minimum: `GetTime`, `time`, `print`, `CreateFrame` (returning a stub frame that records `RegisterEvent` calls and stores scripts), `UnitXP`, `UnitXPMax`, `UnitLevel`, `GetXPExhaustion`, `IsXPUserDisabled`, and the real 3.3.5a global strings.

```lua
local harness = {}
local clock = 0
harness.state = {}

function harness.setTime(t) clock = t end
function harness.advance(dt) clock = clock + dt end

local function installGlobals()
  _G.GetTime = function() return clock end
  _G.time = function() return math.floor(clock) end
  _G.strsplit = function(sep, str)
    local out = {}
    for piece in string.gmatch(str, "([^" .. sep .. "]+)") do out[#out+1] = piece end
    return unpack(out)
  end
  _G.strtrim = function(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end

  -- Real 3.3.5a enUS GlobalStrings (spec 3.3). Verbatim -- do not paraphrase.
  _G.COMBATLOG_XPGAIN_FIRSTPERSON         = "%s dies, you gain %d experience."
  _G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = "You gain %d experience."
  _G.COMBATLOG_XPGAIN_EXHAUSTION1         = "%s dies, you gain %d experience. (%s exp %s bonus)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION2         = "%s dies, you gain %d experience. (%s exp %s bonus)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION4         = "%s dies, you gain %d experience. (%s exp %s penalty)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION5         = "%s dies, you gain %d experience. (%s exp %s penalty)"
  _G.COMBATLOG_XPGAIN_QUEST               = "You gain %d experience. (%s exp %s bonus)"
  _G.ERR_QUEST_COMPLETE_S                 = "%s completed."
  _G.ERR_QUEST_REWARD_EXP_I               = "Experience gained: %d."
  _G.ERR_ZONE_EXPLORED_XP                 = "Discovered %s: %d experience gained"
  _G.QUEST_MONSTERS_KILLED                = "%s slain: %d/%d"
  _G.QUEST_OBJECTS_FOUND                  = "%s: %d/%d"
  _G.QUEST_ITEMS_NEEDED                   = "%s: %d/%d"

  -- Group variants: the client builds these by appending to the base string.
  _G.COMBATLOG_XPGAIN_EXHAUSTION1_GROUP   = "%s dies, you gain %d experience. (%s exp %s bonus, +%d group bonus)"
  _G.COMBATLOG_XPGAIN_FIRSTPERSON_GROUP   = "%s dies, you gain %d experience. (+%d group bonus)"

  _G.UnitXP        = function() return harness.state.xp or 0 end
  _G.UnitXPMax     = function() return harness.state.xpMax or 1000 end
  _G.UnitLevel     = function() return harness.state.level or 1 end
  _G.GetXPExhaustion = function() return harness.state.rested end
  _G.IsXPUserDisabled = function() return harness.state.xpDisabled end
  _G.GetInventoryItemID = function(_, slot) return (harness.state.gear or {})[slot] end
  _G.INVSLOT_SHOULDER, _G.INVSLOT_CHEST = 3, 5
  _G.INVSLOT_FINGER1, _G.INVSLOT_FINGER2 = 11, 12

  local function stubFrame()
    local f = { events = {}, scripts = {}, points = {}, children = {} }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:GetScript(k) return self.scripts[k] end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:SetPoint(...) self.points[#self.points+1] = {...} end
    function f:GetPoint() return unpack(self.points[1] or {}) end
    local noop = function() end
    for _, m in ipairs{"SetSize","SetWidth","SetHeight","SetBackdrop","SetBackdropColor",
      "SetBackdropBorderColor","SetMovable","EnableMouse","RegisterForDrag","SetClampedToScreen",
      "SetFrameStrata","SetStatusBarTexture","SetStatusBarColor","SetMinMaxValues","SetValue",
      "CreateFontString","CreateTexture","SetText","SetFont","SetTextColor","SetAlpha",
      "StartMoving","StopMovingOrSizing","SetAllPoints","ClearAllPoints","SetParent"} do
      f[m] = f[m] or noop
    end
    return f
  end
  harness.stubFrame = stubFrame
  _G.CreateFrame = function() return stubFrame() end
  _G.UIParent = stubFrame()
end

function harness.reset()
  clock = 0
  harness.state = { xp = 0, xpMax = 1000, level = 1, gear = {} }
  _G.LevelPace = nil
  _G.LevelPaceDB = nil
  _G.LevelPaceCharDB = nil
  installGlobals()
end

function harness.load(path)
  local chunk = assert(loadfile(path))
  return chunk("LevelPace", _G.LevelPace)
end

-- assertions
local pass, fail, failures = 0, 0, {}
function harness.ok(v, msg)
  if v then pass = pass + 1 else fail = fail + 1; failures[#failures+1] = msg or "assertion failed" end
end
function harness.eq(a, b, msg)
  harness.ok(a == b, string.format("%s (expected %s, got %s)", msg or "eq", tostring(b), tostring(a)))
end
function harness.near(a, b, tol, msg)
  harness.ok(a and math.abs(a - b) <= tol,
    string.format("%s (expected ~%s, got %s)", msg or "near", tostring(b), tostring(a)))
end
function harness.run(name, fn)
  harness.reset()
  local okRun, err = pcall(fn)
  if not okRun then fail = fail + 1; failures[#failures+1] = name .. ": " .. tostring(err) end
end
function harness.report()
  print(string.format("  %d passed, %d failed", pass, fail))
  for _, f in ipairs(failures) do print("    FAIL: " .. f) end
  return fail == 0
end

harness.reset()
return harness
```

- [ ] **Step 2: Write `tests/run.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
if ! command -v luajit >/dev/null; then
  echo "luajit is required (target client is Lua 5.1; system lua is 5.5 and will mask bugs)" >&2
  exit 2
fi
ver=$(luajit -e 'print(_VERSION)')
[ "$ver" = "Lua 5.1" ] || { echo "expected Lua 5.1 semantics, got $ver" >&2; exit 2; }
status=0
for t in tests/test_*.lua; do
  echo "== $t"
  luajit "$t" || status=1
done
exit $status
```

Then `chmod +x tests/run.sh`.

- [ ] **Step 3: Write the failing test `tests/test_core.lua`**

```lua
package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

h.run("core loads and exposes bus", function()
  h.load("LevelPace/Core.lua")
  local LP = _G.LevelPace
  h.ok(LP, "LevelPace global exists")
  h.eq(type(LP.On), "function", "LP:On exists")
  h.eq(type(LP.Fire), "function", "LP:Fire exists")
end)

h.run("event bus delivers payload to all handlers", function()
  h.load("LevelPace/Core.lua")
  local LP = _G.LevelPace
  local seen = {}
  LP:On("TEST", function(a, b) seen[#seen+1] = a + b end)
  LP:On("TEST", function(a, b) seen[#seen+1] = a * b end)
  LP:Fire("TEST", 3, 4)
  h.eq(#seen, 2, "both handlers ran")
  h.eq(seen[1], 7, "first handler got args")
  h.eq(seen[2], 12, "second handler got args")
end)

h.run("event bus isolates handler errors", function()
  h.load("LevelPace/Core.lua")
  local LP = _G.LevelPace
  local reached = false
  LP:On("BOOM", function() error("intentional") end)
  LP:On("BOOM", function() reached = true end)
  LP:Fire("BOOM")
  h.ok(reached, "a throwing handler does not stop later handlers")
end)

os.exit(h.report() and 0 or 1)
```

- [ ] **Step 4: Run it and verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `LevelPace/Core.lua` does not exist.

- [ ] **Step 5: Write `LevelPace/Core.lua`**

```lua
local ADDON = ...
local LP = {}
_G.LevelPace = LP

LP.VERSION = "0.1.0"
LP.modules = {}

local handlers = {}

function LP:On(event, fn)
  handlers[event] = handlers[event] or {}
  table.insert(handlers[event], fn)
end

function LP:Fire(event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    -- One bad handler must never break the others, or a parse error in the
    -- ledger takes the whole addon down mid-grind.
    local ok, err = pcall(list[i], ...)
    if not ok and LP.debug then
      LP:Print("|cffff5555error in " .. event .. ":|r " .. tostring(err))
    end
  end
end

function LP:Print(...)
  local msg = "|cff44ddffLevelPace:|r"
  for i = 1, select("#", ...) do msg = msg .. " " .. tostring((select(i, ...))) end
  (DEFAULT_CHAT_FRAME or { AddMessage = print }):AddMessage(msg)
end

-- Throttled scheduler. 3.3.5a has no C_Timer, and frames are never garbage
-- collected, so we use exactly ONE driver frame for every repeating job.
local scheduled = {}
local driver

function LP:Schedule(interval, fn)
  local job = { interval = interval, fn = fn, elapsed = 0 }
  table.insert(scheduled, job)
  return job
end

function LP:Unschedule(job)
  for i = #scheduled, 1, -1 do
    if scheduled[i] == job then table.remove(scheduled, i) end
  end
end

function LP:StartDriver()
  if driver or not CreateFrame then return end
  driver = CreateFrame("Frame")
  driver:SetScript("OnUpdate", function(_, elapsed)
    for i = 1, #scheduled do
      local job = scheduled[i]
      job.elapsed = job.elapsed + elapsed
      if job.elapsed >= job.interval then
        job.elapsed = 0
        pcall(job.fn)
      end
    end
  end)
end

-- Exposed so tests can pump the scheduler without a real frame.
function LP:_Tick(elapsed)
  for i = 1, #scheduled do
    local job = scheduled[i]
    job.elapsed = job.elapsed + elapsed
    if job.elapsed >= job.interval then job.elapsed = 0; pcall(job.fn) end
  end
end

return LP
```

- [ ] **Step 6: Run tests and verify they pass**

Run: `./tests/run.sh`
Expected: PASS, 6 assertions.

- [ ] **Step 7: Write `LevelPace/LevelPace.toc`**

⚠ Basename must equal folder name. File order is load order.

```
## Interface: 30300
## Title: LevelPace
## Notes: Honest XP tracking and quest-vs-grind ranking.
## Author: Dan
## Version: 0.1.0
## SavedVariables: LevelPaceDB
## SavedVariablesPerCharacter: LevelPaceCharDB

Core.lua
Compat.lua
Data\XPTable.lua
Ledger.lua
Modifiers.lua
Rates.lua
History.lua
Estimator.lua
Quests.lua
UI\Bar.lua
UI\Box.lua
UI\Tooltip.lua
UI\Options.lua
```

⚠ TOC paths use **backslashes**. Only list files that exist — a missing file listed in the TOC prevents the addon loading. Add lines as tasks land; for now list only `Core.lua`.

- [ ] **Step 8: Commit**

```bash
git add LevelPace tests
git commit -m "feat: addon skeleton, event bus, and LuaJIT test harness"
```

---

## Task 2: Compat — the global-string pattern converter

The single most bug-prone function in the addon (spec §3.3).

**Files:**
- Create: `LevelPace/Compat.lua`
- Create: `tests/test_compat.lua`
- Modify: `LevelPace/LevelPace.toc` (add `Compat.lua`)

**Interfaces:**
- Consumes: `LevelPace` from Task 1.
- Produces: `LP.util.ConvertGlobalString(fmt) -> pattern`, `LP.util.SafeRegisterEvent(frame, event) -> boolean`, `LP.util.FormatTime(sec) -> string`, `LP.util.FormatNumber(n) -> string`, `LP.util.Round(n, dp) -> number`, `LP.util.CopyDefaults(dst, src) -> dst`, `LP.util.Median(list) -> number|nil`

- [ ] **Step 1: Write the failing test `tests/test_compat.lua`**

```lua
package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  return _G.LevelPace
end

h.run("converts a simple string", function()
  local LP = load()
  local p = LP.util.ConvertGlobalString("You gain %d experience.")
  h.eq(string.match("You gain 412 experience.", p), "412", "captures the number")
end)

h.run("captures name and number in order", function()
  local LP = load()
  local p = LP.util.ConvertGlobalString("%s dies, you gain %d experience.")
  local name, xp = string.match("Ravenous Ghoul dies, you gain 412 experience.", p)
  h.eq(name, "Ravenous Ghoul", "mob name")
  h.eq(xp, "412", "xp")
end)

-- THE regression test. The naive converter escapes only ( and ), so the
-- literal + and - in a _GROUP message are treated as Lua quantifiers and
-- the match silently fails. Spec 3.3.
h.run("escapes + and - so _GROUP variants match", function()
  local LP = load()
  local p = LP.util.ConvertGlobalString(
    "%s dies, you gain %d experience. (%s exp %s bonus, +%d group bonus)")
  local name, xp, bonus, btype, grp = string.match(
    "Ghoul dies, you gain 412 experience. (+86 exp Rested bonus, +12 group bonus)", p)
  h.eq(name, "Ghoul", "name")
  h.eq(xp, "412", "xp")
  h.eq(bonus, "+86", "bonus amount is the FIRST %s")
  h.eq(btype, "Rested", "bonus type is the SECOND %s")
  h.eq(grp, "12", "group bonus")
end)

h.run("escapes magic characters in literal text", function()
  local LP = load()
  local p = LP.util.ConvertGlobalString("Discovered %s: %d experience gained")
  local zone, xp = string.match("Discovered Howling Fjord: 975 experience gained", p)
  h.eq(zone, "Howling Fjord", "zone")
  h.eq(xp, "975", "xp")
end)

h.run("SafeRegisterEvent reports failure instead of erroring", function()
  local LP = load()
  local f = h.stubFrame()
  f.RegisterEvent = function(_, e)
    if e == "NOPE" then error('Attempt to register unknown event "NOPE"') end
  end
  h.eq(LP.util.SafeRegisterEvent(f, "NOPE"), false, "unknown event returns false")
  h.eq(LP.util.SafeRegisterEvent(f, "PLAYER_LOGIN"), true, "known event returns true")
end)

h.run("FormatTime", function()
  local LP = load()
  h.eq(LP.util.FormatTime(45), "45s", "seconds")
  h.eq(LP.util.FormatTime(90), "1m 30s", "minutes")
  h.eq(LP.util.FormatTime(5040), "1h 24m", "hours")
  h.eq(LP.util.FormatTime(nil), "--", "nil is not a crash")
end)

h.run("FormatNumber groups thousands", function()
  local LP = load()
  h.eq(LP.util.FormatNumber(12600), "12,600", "thousands")
  h.eq(LP.util.FormatNumber(1670800), "1,670,800", "millions")
  h.eq(LP.util.FormatNumber(412), "412", "small")
end)

h.run("Median", function()
  local LP = load()
  h.eq(LP.util.Median({5, 1, 3}), 3, "odd count")
  h.eq(LP.util.Median({4, 1, 3, 2}), 2.5, "even count averages the middle pair")
  h.eq(LP.util.Median({}), nil, "empty is nil, not zero")
end)

os.exit(h.report() and 0 or 1)
```

- [ ] **Step 2: Run and verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `Compat.lua` missing.

- [ ] **Step 3: Write `LevelPace/Compat.lua`**

```lua
local LP = _G.LevelPace
LP.util = {}
local util = LP.util

-- Turn a WoW format string into a Lua pattern.
--
-- The order here is load-bearing. We must escape every Lua magic character
-- that appears LITERALLY in the message -- including + and -, which show up
-- in "(+86 exp Rested bonus)" -- but we must NOT escape %, because % is what
-- marks the %s / %d placeholders we still need to find.
--
-- The naive version that escapes only ( and ) matches the plain strings fine
-- and silently fails on every _GROUP variant. Spec 3.3.
function util.ConvertGlobalString(fmt)
  if type(fmt) ~= "string" then return nil end
  local p = fmt
  -- 1. escape magic chars EXCEPT % (and except $, handled last)
  p = string.gsub(p, "([%^%(%)%.%[%]%*%+%-%?])", "%%%1")
  -- 2. placeholders -> captures. %s is non-greedy so adjacent captures split.
  p = string.gsub(p, "%%%%s", "(.-)")
  p = string.gsub(p, "%%%%d", "(%%d+)")
  -- WoW also uses indexed placeholders like %1$s in some locales.
  p = string.gsub(p, "%%%%(%d)%%%$s", "(.-)")
  p = string.gsub(p, "%%%%(%d)%%%$d", "(%%d+)")
  -- 3. any leftover literal $
  p = string.gsub(p, "%$", "%%$")
  return "^" .. p .. "$"
end

-- Registering an event that does not exist on 3.3.5a raises a hard Lua error
-- and aborts addon load. Always go through this.
function util.SafeRegisterEvent(frame, event)
  local ok = pcall(frame.RegisterEvent, frame, event)
  return ok and true or false
end

function util.Round(n, dp)
  if not n then return nil end
  local m = 10 ^ (dp or 0)
  return math.floor(n * m + 0.5) / m
end

function util.FormatTime(sec)
  if not sec or sec ~= sec or sec < 0 or sec == math.huge then return "--" end
  sec = math.floor(sec)
  if sec < 60 then return sec .. "s" end
  if sec < 3600 then
    return string.format("%dm %ds", math.floor(sec / 60), sec % 60)
  end
  return string.format("%dh %dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

function util.FormatNumber(n)
  if not n then return "--" end
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

function util.CopyDefaults(dst, src)
  if type(dst) ~= "table" then dst = {} end
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = util.CopyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

function util.Median(list)
  local n = #list
  if n == 0 then return nil end
  local copy = {}
  for i = 1, n do copy[i] = list[i] end
  table.sort(copy)
  if n % 2 == 1 then return copy[(n + 1) / 2] end
  return (copy[n / 2] + copy[n / 2 + 1]) / 2
end
```

- [ ] **Step 4: Run and verify pass**

Run: `./tests/run.sh`
Expected: PASS. If the `_GROUP` test fails, the escape set in step 1 is wrong — check that `+` and `-` are both in the character class.

- [ ] **Step 5: Add `Compat.lua` to the TOC, after `Core.lua`.**

- [ ] **Step 6: Commit**

```bash
git add LevelPace/Compat.lua LevelPace/LevelPace.toc tests/test_compat.lua
git commit -m "feat: global-string to Lua-pattern converter with +/- escaping"
```

---

## Task 3: Data/XPTable — XP curve and the BaseGain formula

**Files:**
- Create: `LevelPace/Data/XPTable.lua`
- Create: `tests/test_xptable.lua`
- Modify: `LevelPace/LevelPace.toc`

**Interfaces:**
- Produces: `LP.data.XP_FOR_LEVEL[1..79] -> number`, `LP.data.HEIRLOOM_XP[itemID] -> pct`, `LP.data.GrayLevel(pl) -> number`, `LP.data.ZeroDifference(pl) -> number`, `LP.data.BaseGain(plLevel, mobLevel, nBaseExp) -> number`, `LP.data.CONTENT = { AZEROTH = 45, OUTLAND = 235, NORTHREND = 580 }`

- [ ] **Step 1: Write the failing test `tests/test_xptable.lua`**

```lua
package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua"); h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Data/XPTable.lua")
  return _G.LevelPace
end

h.run("xp table anchors match AzerothCore player_xp_for_level", function()
  local LP = load(); local t = LP.data.XP_FOR_LEVEL
  h.eq(t[1], 400, "level 1")
  h.eq(t[59], 172000, "level 59")
  h.eq(t[60], 290000, "level 60 -- the 68.6% cliff")
  h.eq(t[69], 717000, "level 69")
  h.eq(t[70], 1523800, "level 70 -- the 112.5% cliff")
  h.eq(t[79], 1670800, "level 79")
  h.eq(t[80], nil, "no level 80 entry -- 80 is the cap")
end)

h.run("total 1->80 is 24,067,200", function()
  local LP = load(); local sum = 0
  for i = 1, 79 do sum = sum + LP.data.XP_FOR_LEVEL[i] end
  h.eq(sum, 24067200, "documented total")
end)

h.run("GrayLevel matches TrinityCore", function()
  local LP = load(); local g = LP.data.GrayLevel
  h.eq(g(5), 0, "<=5 is 0")
  h.eq(g(30), 30 - 5 - 3, "<=39 band")
  h.eq(g(50), 50 - 1 - 10, "<=59 band")
  h.eq(g(70), 61, ">=60 band is pl-9")
end)

h.run("ZeroDifference thresholds", function()
  local LP = load(); local z = LP.data.ZeroDifference
  h.eq(z(7), 5, "pl<8"); h.eq(z(9), 6, "pl<10"); h.eq(z(11), 7, "pl<12")
  h.eq(z(15), 8, "pl<16"); h.eq(z(19), 9, "pl<20"); h.eq(z(29), 11, "pl<30")
  h.eq(z(39), 12, "pl<40"); h.eq(z(44), 13, "pl<45"); h.eq(z(49), 14, "pl<50")
  h.eq(z(54), 15, "pl<55"); h.eq(z(59), 16, "pl<60"); h.eq(z(70), 17, "else")
end)

h.run("BaseGain uses PLAYER level, not mob level", function()
  local LP = load()
  -- Equal level in Azeroth: 5*L + 45.
  h.eq(LP.data.BaseGain(10, 10, 45), 95, "level 10 equal")
  h.eq(LP.data.BaseGain(60, 60, 45), 345, "level 60 equal, Azeroth")
  -- Same player+mob level but Northrend content constant.
  h.eq(LP.data.BaseGain(70, 70, 580), 930, "level 70 equal, Northrend")
  -- Level-80 in Outland uses 80*5+235, NOT 70*5+235.
  h.eq(LP.data.BaseGain(80, 70, 235) > 0, true, "level 80 vs 70 in Outland is nonzero")
end)

h.run("higher mobs give +5%/level capped at +4", function()
  local LP = load()
  local base = LP.data.BaseGain(60, 60, 45)
  local plus4 = LP.data.BaseGain(60, 64, 45)
  local plus7 = LP.data.BaseGain(60, 67, 45)
  h.eq(plus7, plus4, "beyond +4 is capped")
  h.ok(plus4 > base, "+4 beats equal level")
end)

-- The gray cutoff is a cliff, not a fade. Spec 5.2.
h.run("gray cliff at level 70", function()
  local LP = load()
  h.eq(LP.data.BaseGain(70, 61, 580), 0, "level 61 is gray to a level 70")
  h.eq(LP.data.BaseGain(70, 62, 580), 492, "level 62 gives 492")
end)

h.run("heirloom table", function()
  local LP = load()
  h.eq(LP.data.HEIRLOOM_XP[42949], 10, "a +10% shoulder")
  h.eq(LP.data.HEIRLOOM_XP[48677], 10, "a +10% chest")
  h.eq(LP.data.HEIRLOOM_XP[50255], 5, "Dread Pirate Ring is +5%")
  h.eq(LP.data.HEIRLOOM_XP[42991], nil, "Swift Hand of Justice grants NO xp")
end)

os.exit(h.report() and 0 or 1)
```

- [ ] **Step 2: Run and verify failure.**

- [ ] **Step 3: Write `LevelPace/Data/XPTable.lua`**

The full `player_xp_for_level` table for 1..79 must be present. Source it from AzerothCore `data/sql/base/db_world/player_xp_for_level.sql` (byte-identical to CMaNGOS). The four anchor values asserted in the test plus the total of 24,067,200 will catch a transcription error.

```lua
local LP = _G.LevelPace
LP.data = {}
local d = LP.data

d.CONTENT = { AZEROTH = 45, OUTLAND = 235, NORTHREND = 580 }

-- XP required to advance FROM this level. 3.3.5a values.
d.XP_FOR_LEVEL = {
  400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
  8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
  25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
  50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
  95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
  153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 172000, 290000,
  317000, 349000, 386000, 428000, 475000, 527000, 585000, 648000, 717000, 1523800,
  1539800, 1555700, 1571600, 1587600, 1603500, 1619400, 1635400, 1651300, 1670800,
}

-- 3.3.5a XP heirlooms, by item ID -> percent. Spec 3.7.
-- These are NOT visible via UnitBuff -- passive item auras get no client aura
-- slot -- so equipped-item scanning is the only detection path.
d.HEIRLOOM_XP = {}
for _, id in ipairs{42949,42950,42951,42952,42984,42985,44099,44100,44101,44102,44103,44105,44107} do
  d.HEIRLOOM_XP[id] = 10   -- shoulders
end
for _, id in ipairs{48677,48683,48685,48687,48689,48691} do
  d.HEIRLOOM_XP[id] = 10   -- chests
end
d.HEIRLOOM_XP[50255] = 5   -- Dread Pirate Ring

function d.GrayLevel(pl)
  if pl <= 5 then return 0 end
  if pl <= 39 then return pl - 5 - math.floor(pl / 10) end
  if pl <= 59 then return pl - 1 - math.floor(pl / 5) end
  return pl - 9
end

function d.ZeroDifference(pl)
  if pl < 8 then return 5 elseif pl < 10 then return 6
  elseif pl < 12 then return 7 elseif pl < 16 then return 8
  elseif pl < 20 then return 9 elseif pl < 30 then return 11
  elseif pl < 40 then return 12 elseif pl < 45 then return 13
  elseif pl < 50 then return 14 elseif pl < 55 then return 15
  elseif pl < 60 then return 16 else return 17 end
end

-- Trinity::XP::BaseGain, 3.3.5 branch. All division truncates -- match it
-- exactly or the predictions drift.
-- NOTE: the base term uses PLAYER level. The widely-quoted "5*mobLevel + 45"
-- is wrong. nBaseExp comes from the MAP's expansion tier, not player level.
function d.BaseGain(plLevel, mobLevel, nBaseExp)
  nBaseExp = nBaseExp or d.CONTENT.AZEROTH
  local B = plLevel * 5 + nBaseExp
  if mobLevel >= plLevel then
    local diff = math.min(mobLevel - plLevel, 4)
    return math.floor((math.floor(B * (20 + diff) / 10) + 1) / 2)
  end
  local gray = d.GrayLevel(plLevel)
  if mobLevel > gray then
    local ZD = d.ZeroDifference(plLevel)
    return math.floor(B * (ZD + mobLevel - plLevel) / ZD)
  end
  return 0
end

-- XP needed to go from `from` to `to`. Used for multi-level deltas, which
-- UnitXPMax cannot answer (it only knows the current level).
function d.XPBetween(from, to)
  local sum = 0
  for lvl = from, to - 1 do sum = sum + (d.XP_FOR_LEVEL[lvl] or 0) end
  return sum
end
```

- [ ] **Step 4: Run and verify pass.** If the total assertion fails, a value was mistyped — diff against the SQL source rather than guessing.

- [ ] **Step 5: Add `Data\XPTable.lua` to the TOC.**

- [ ] **Step 6: Commit**

```bash
git add LevelPace/Data tests/test_xptable.lua LevelPace/LevelPace.toc
git commit -m "feat: 3.3.5a XP curve, heirloom IDs, and TrinityCore BaseGain formula"
```

---

## Task 4: Ledger — parse XP gains into structured events

The heart. Everything downstream depends on this being right.

**Files:**
- Create: `LevelPace/Ledger.lua`
- Create: `tests/test_ledger.lua`
- Modify: `LevelPace/LevelPace.toc`

**Interfaces:**
- Produces:
  - `LP.Ledger:Parse(msg) -> event|nil` where event is
    `{ kind = "kill"|"unnamed", mobName, total, bonusAmount, bonusType, penaltyAmount, penaltyType, groupBonus }`
  - Fires `LP:Fire("XP_EVENT", e)` with
    `{ t, source = "kill"|"quest"|"explore"|"unknown", mobName, total, base, rested, group, questID }`
  - `LP.Ledger:NoteQuestFinished(questID, predictedXP)` — called by `Quests` to arm attribution
  - `LP.Ledger:HandleSystem(msg)` — for `CHAT_MSG_SYSTEM` disambiguation

- [ ] **Step 1: Write the failing test `tests/test_ledger.lua`**

```lua
package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua"); h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Data/XPTable.lua"); h.load("LevelPace/Ledger.lua")
  return _G.LevelPace
end

local function capture(LP)
  local got = {}
  LP:On("XP_EVENT", function(e) got[#got+1] = e end)
  return got
end

h.run("plain kill", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ravenous Ghoul dies, you gain 412 experience.")
  h.eq(#got, 1, "one event")
  h.eq(got[1].source, "kill", "source")
  h.eq(got[1].mobName, "Ravenous Ghoul", "mob")
  h.eq(got[1].total, 412, "total")
  h.eq(got[1].base, 412, "base equals total when unrested")
  h.eq(got[1].rested, 0, "no rested")
end)

h.run("rested kill splits base from bonus", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies, you gain 824 experience. (+412 exp Rested bonus)")
  h.eq(got[1].total, 824, "total is the full amount")
  h.eq(got[1].rested, 412, "rested bonus extracted")
  h.eq(got[1].base, 412, "base is total minus bonus")
end)

-- Ordering regression. The plain EXHAUSTION1 pattern will happily match a
-- _GROUP message and mis-capture bonusType as "Rested bonus, +12 group".
-- Patterns must be tried most-specific-first. Spec 3.3.
h.run("group variant is matched by the group pattern, not the plain one", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies, you gain 500 experience. (+86 exp Rested bonus, +12 group bonus)")
  h.eq(got[1].rested, 86, "rested is 86, not mangled")
  h.eq(got[1].group, 12, "group bonus extracted")
  h.eq(got[1].base, 500 - 86 - 12, "base excludes both bonuses")
end)

h.run("penalty variant", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies, you gain 200 experience. (-50 exp Penalty penalty)")
  h.eq(got[1].total, 200, "total")
  h.eq(got[1].rested, 0, "a penalty is not a rested bonus")
end)

-- Quest and exploration XP are TEXTUALLY IDENTICAL on 3.3.5a. Spec 3.4.
h.run("unnamed gain defaults to unknown", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("You gain 9800 experience.")
  h.eq(got[1].source, "unknown", "no context means unknown, not quest")
end)

h.run("unnamed gain after QUEST_FINISHED is attributed to the quest", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:NoteQuestFinished(12345, 4200)
  LP.Ledger:OnChat("You gain 21000 experience.")
  h.eq(got[1].source, "quest", "attributed")
  h.eq(got[1].questID, 12345, "carries the quest id")
  h.eq(got[1].predictedXP, 4200, "carries the client prediction for rate learning")
end)

h.run("quest attribution expires after the window", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:NoteQuestFinished(12345, 4200)
  h.advance(5)
  LP.Ledger:OnChat("You gain 21000 experience.")
  h.eq(got[1].source, "unknown", "stale arm does not attribute")
end)

h.run("exploration is recognised from the system message", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:HandleSystem("Discovered Howling Fjord: 975 experience gained")
  LP.Ledger:OnChat("You gain 975 experience.")
  h.eq(got[1].source, "explore", "explore, not quest")
end)

h.run("non-xp chat is ignored", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies.")
  LP.Ledger:OnChat("You have gained a level!")
  h.eq(#got, 0, "no spurious events")
end)

os.exit(h.report() and 0 or 1)
```

- [ ] **Step 2: Run and verify failure.**

- [ ] **Step 3: Write `LevelPace/Ledger.lua`**

Key implementation notes for whoever writes this:

- Build the pattern list **once** at load, from `_G` globals via `LP.util.ConvertGlobalString`. Never hardcode English.
- Order the list **most-specific first**: `_GROUP` and `_RAID` variants → `EXHAUSTION4/5` (penalty) → `EXHAUSTION1/2` (bonus) → `FIRSTPERSON` → `FIRSTPERSON_UNNAMED`. Store each entry as `{ pattern = p, fields = {"mobName","total","bonusAmount","bonusType","groupBonus"} }` so the captures map by name rather than by position.
- `EXHAUSTION1` and `EXHAUSTION2` have identical text — dedupe the pattern list so the same pattern is not tried twice.
- Bonus captures: first `%s` is the **amount** (may carry a leading `+`), second is the **type label**. Strip non-digits before `tonumber`.
- `base = total - (rested or 0) - (group or 0)`.
- Quest attribution: `NoteQuestFinished` stores `{ questID, predictedXP, at = GetTime() }`. An unnamed gain within `2` seconds consumes it. `HandleSystem` arms an `explore` flag the same way with the same window.
- Register `CHAT_MSG_COMBAT_XP_GAIN` and `CHAT_MSG_SYSTEM` through `LP.util.SafeRegisterEvent`. ⚠ `CHAT_MSG_*` carries **12** args on 3.3.5a; `arg1` is the message.
- Guard the whole `OnChat` body so a locale whose strings do not parse degrades to "no events" rather than erroring every kill.

- [ ] **Step 4: Run and verify all ledger tests pass.**

- [ ] **Step 5: Add `Ledger.lua` to the TOC.**

- [ ] **Step 6: Commit**

```bash
git add LevelPace/Ledger.lua tests/test_ledger.lua LevelPace/LevelPace.toc
git commit -m "feat: XP-gain ledger with specificity-ordered parsing and source attribution"
```

---

## Task 5: Modifiers — rested, heirlooms, XP-disabled

**Files:**
- Create: `LevelPace/Modifiers.lua`
- Modify: `LevelPace/LevelPace.toc`
- Test: covered by `tests/test_estimator.lua` (Task 8) which injects modifier values directly; add a focused block to `tests/test_xptable.lua` for the heirloom multiplier maths.

**Interfaces:**
- Produces: `LP.Modifiers:GetRestedPool() -> number`, `LP.Modifiers:HeirloomMultiplier() -> number`, `LP.Modifiers:IsXPDisabled() -> boolean`, `LP.Modifiers:Refresh()`

- [ ] **Step 1: Write the failing test** — append to `tests/test_xptable.lua`:

```lua
h.run("heirloom multiplier compounds multiplicatively", function()
  h.load("LevelPace/Core.lua"); h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Data/XPTable.lua"); h.load("LevelPace/Modifiers.lua")
  local LP = _G.LevelPace
  h.state.gear = { [3] = 42949, [5] = 48677, [11] = 50255 }  -- shoulder, chest, ring
  LP.Modifiers:Refresh()
  -- TrinityCore applies AddPct per aura, so it is 1.10 * 1.10 * 1.05, NOT 1.25.
  h.near(LP.Modifiers:HeirloomMultiplier(), 1.2705, 0.0001, "compounds to 27.05%")
end)

h.run("no heirlooms is 1.0", function()
  h.load("LevelPace/Core.lua"); h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Data/XPTable.lua"); h.load("LevelPace/Modifiers.lua")
  local LP = _G.LevelPace
  h.state.gear = {}
  LP.Modifiers:Refresh()
  h.eq(LP.Modifiers:HeirloomMultiplier(), 1, "identity")
end)
```

- [ ] **Step 2: Run and verify failure.**

- [ ] **Step 3: Write `LevelPace/Modifiers.lua`**

- Scan `INVSLOT_SHOULDER (3)`, `INVSLOT_CHEST (5)`, `INVSLOT_FINGER1 (11)`, `INVSLOT_FINGER2 (12)` with `GetInventoryItemID("player", slot)`, look up `LP.data.HEIRLOOM_XP`, and multiply `(1 + pct/100)` per match.
- `Refresh()` on `PLAYER_LOGIN` and `UNIT_INVENTORY_CHANGED` (⚠ **not** `PLAYER_EQUIPMENT_CHANGED`, which does not exist on this client).
- `GetRestedPool()` returns `GetXPExhaustion() or 0`.
- `IsXPDisabled()` returns `IsXPUserDisabled() and true or false`.
- Fires `LP:Fire("MODIFIERS_CHANGED")` when the multiplier changes so the UI can refresh.

- [ ] **Step 4: Run and verify pass.**

- [ ] **Step 5: Add to TOC. Commit.**

```bash
git add LevelPace/Modifiers.lua LevelPace/LevelPace.toc tests/test_xptable.lua
git commit -m "feat: modifier detection via equipped-item scan and rested pool"
```

---

## Task 6: History — per-level records

**Files:**
- Create: `LevelPace/History.lua`
- Modify: `LevelPace/Core.lua` (saved-variables bootstrap on `ADDON_LOADED`/`PLAYER_LOGIN`)
- Create: `tests/test_history.lua`
- Modify: `LevelPace/LevelPace.toc`

**Interfaces:**
- Produces: `LP.History:Current() -> record`, `LP.History:Get(level) -> record|nil`, `LP.History:All() -> array`, `LP.History:MedianBaseRate() -> xpPerSec|nil`, `LP.History:Reset()`, `LP.History:OnLevelUp(newLevel)`
- Record shape (exactly this — Task 8 and the UI read these field names):

```lua
{ level, startedAt, endedAt, elapsed,
  xpBySource = { kill = 0, quest = 0, explore = 0, unknown = 0 },
  killCount = 0, questCount = 0, deaths = 0, corpseRunSeconds = 0,
  restedConsumed = 0, baseXP = 0, activeSeconds = 0, largestGap = 0 }
```

- [ ] **Step 1: Write `tests/test_history.lua`** covering: a fresh record is created at load; `XP_EVENT` accumulates into the right `xpBySource` bucket and increments `killCount`/`questCount`; `largestGap` records the biggest interval between consecutive XP events (⚠ this is the §6.3 annotation, **not** a filter — the time still counts); `OnLevelUp` closes the record with `endedAt`/`elapsed` and opens a new one; `Reset` clears the current record but leaves completed ones; `MedianBaseRate` returns `nil` with no completed levels and the median of `baseXP/elapsed` otherwise.

- [ ] **Step 2: Run and verify failure.**

- [ ] **Step 3: Write `LevelPace/History.lua` and the Core saved-vars bootstrap.**

⚠ Bootstrap ordering (spec §3.8): file-scope code runs **before** SavedVariables exist. Read `LevelPaceDB`/`LevelPaceCharDB` in `ADDON_LOADED` filtered on `arg1 == "LevelPace"`, and read `UnitLevel`/`UnitXP`/`MAX_PLAYER_LEVEL` only at `PLAYER_LOGIN`.

Deaths and corpse-run time come from `PLAYER_DEAD` → start timer, `PLAYER_UNGHOST`/`PLAYER_ALIVE` → accumulate `corpseRunSeconds`.

- [ ] **Step 4: Run and verify pass. Add to TOC. Commit.**

```bash
git add LevelPace/History.lua LevelPace/Core.lua LevelPace/LevelPace.toc tests/test_history.lua
git commit -m "feat: per-level history records with no-sanitising accounting"
```

---

## Task 7: Rates — learn the server's XP multipliers

**Files:**
- Create: `LevelPace/Rates.lua`
- Create: `tests/test_rates.lua`
- Modify: `LevelPace/LevelPace.toc`

**Interfaces:**
- Produces: `LP.Rates:GetQuestRate() -> number|nil`, `LP.Rates:QuestSampleCount() -> number`, `LP.Rates:AddQuestSample(predicted, actual, heirloomMult)`, `LP.Rates:GetKillRate() -> number|nil`, `LP.Rates:AddKillSample(observedBase, expectedBase)`, `LP.Rates.MIN_SAMPLES = 3`

- [ ] **Step 1: Write the failing test `tests/test_rates.lua`**

```lua
h.run("quest rate is nil below the sample threshold", function()
  local LP = load()
  LP.Rates:AddQuestSample(4200, 21000, 1)
  LP.Rates:AddQuestSample(3000, 15000, 1)
  h.eq(LP.Rates:GetQuestRate(), nil, "2 samples is not enough -- say 'learning', not a wrong number")
  h.eq(LP.Rates:QuestSampleCount(), 2, "counted")
end)

h.run("quest rate converges to the server multiplier", function()
  local LP = load()
  for _ = 1, 5 do LP.Rates:AddQuestSample(4200, 21000, 1) end
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.001, "x5 server")
end)

h.run("quest rate divides out the heirloom bonus", function()
  local LP = load()
  -- x5 server AND +27.05% heirlooms: actual = 4200 * 5 * 1.2705
  for _ = 1, 5 do LP.Rates:AddQuestSample(4200, 4200 * 5 * 1.2705, 1.2705) end
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.01, "heirlooms must not inflate the learned rate")
end)

h.run("median resists a single mis-attributed sample", function()
  local LP = load()
  for _ = 1, 5 do LP.Rates:AddQuestSample(4200, 21000, 1) end
  LP.Rates:AddQuestSample(4200, 999999, 1)   -- a wildly wrong attribution
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.001, "median is unmoved by one outlier")
end)

h.run("window is bounded to the last 20 samples", function()
  local LP = load()
  for _ = 1, 25 do LP.Rates:AddQuestSample(1000, 1000, 1) end
  h.ok(LP.Rates:QuestSampleCount() <= 20, "window bounded")
end)
```

- [ ] **Step 2: Run and verify failure.**

- [ ] **Step 3: Write `LevelPace/Rates.lua`.**

`sample = actual / (predicted * heirloomMult)`. Push to a bounded ring of 20. `Get*Rate()` returns `LP.util.Median(samples)` when `#samples >= MIN_SAMPLES`, else `nil`. Persist per realm under `LevelPaceDB.rates[realmName]`.

Wire `AddQuestSample` to the `XP_EVENT` handler for `source == "quest"` when `e.predictedXP` is present.

- [ ] **Step 4: Run and verify pass. Add to TOC. Commit.**

```bash
git add LevelPace/Rates.lua tests/test_rates.lua LevelPace/LevelPace.toc
git commit -m "feat: learn server quest/kill XP rates from observation"
```

---

## Task 8: Estimator — time and mobs to level

**Files:**
- Create: `LevelPace/Estimator.lua`
- Create: `tests/test_estimator.lua`
- Modify: `LevelPace/LevelPace.toc`

**Interfaces:**
- Produces: `LP.Estimator:Update(state)` and `LP.Estimator:Result() -> { timeToLevel, baseRate, mobsLow, mobsHigh, restedCovered, gapWarning, confidence }`
- ⚠ `Estimator` reads **no** WoW globals. `Update` takes a plain table `{ xp, xpMax, restedPool, baseRateSamples, killXPSamples, now, levelStartedAt, largestGap }` so it is fully testable.

- [ ] **Step 1: Write the failing test `tests/test_estimator.lua`**

The rested projection is the one that was wrong in the first draft of the spec. These cases are non-negotiable:

```lua
h.run("unrested projection is simple division", function()
  local LP = load()
  LP.Estimator:Update{ xp = 0, xpMax = 100000, restedPool = 0,
                       baseRateSamples = {1}, now = 0, levelStartedAt = 0 }
  h.near(LP.Estimator:Result().timeToLevel, 100000, 1, "100k xp at 1 xp/s")
end)

-- A pool of P supplies 2P xp in exchange for P xp of BASE killing.
h.run("rested pool exactly covering the level", function()
  local LP = load()
  LP.Estimator:Update{ xp = 0, xpMax = 100000, restedPool = 50000,
                       baseRateSamples = {1}, now = 0, levelStartedAt = 0 }
  h.near(LP.Estimator:Result().timeToLevel, 50000, 1,
         "50k pool doubles 50k base into the full 100k")
end)

h.run("rested pool larger than the level needs", function()
  local LP = load()
  LP.Estimator:Update{ xp = 0, xpMax = 100000, restedPool = 60000,
                       baseRateSamples = {1}, now = 0, levelStartedAt = 0 }
  h.near(LP.Estimator:Result().timeToLevel, 50000, 1,
         "surplus pool is wasted, not counted -- NOT 10000")
end)

h.run("partial rested pool", function()
  local LP = load()
  LP.Estimator:Update{ xp = 0, xpMax = 100000, restedPool = 10000,
                       baseRateSamples = {1}, now = 0, levelStartedAt = 0 }
  -- 20000 xp covered by 10000 base, then 80000 at normal rate.
  h.near(LP.Estimator:Result().timeToLevel, 90000, 1, "10000 + 80000")
end)

h.run("no rate samples yields nil, not infinity", function()
  local LP = load()
  LP.Estimator:Update{ xp = 0, xpMax = 100000, restedPool = 0,
                       baseRateSamples = {}, now = 0, levelStartedAt = 0 }
  h.eq(LP.Estimator:Result().timeToLevel, nil, "unknown is nil")
end)

h.run("mobs-to-level is a range and needs 10 kills", function()
  local LP = load()
  LP.Estimator:Update{ xp = 0, xpMax = 10000, restedPool = 0,
                       baseRateSamples = {1}, killXPSamples = {100, 200},
                       now = 0, levelStartedAt = 0 }
  h.eq(LP.Estimator:Result().mobsLow, nil, "under 10 kills -> no estimate")

  local s = {}; for i = 1, 12 do s[i] = 100 end
  LP.Estimator:Update{ xp = 0, xpMax = 10000, restedPool = 0,
                       baseRateSamples = {1}, killXPSamples = s,
                       now = 0, levelStartedAt = 0 }
  local r = LP.Estimator:Result()
  h.eq(r.mobsLow, 100, "10000 / 100"); h.eq(r.mobsHigh, 100, "uniform kills give a point range")
end)

h.run("gap warning is reported, not filtered", function()
  local LP = load()
  LP.Estimator:Update{ xp = 0, xpMax = 100000, restedPool = 0,
                       baseRateSamples = {1}, now = 0, levelStartedAt = 0,
                       largestGap = 8040 }
  local r = LP.Estimator:Result()
  h.eq(r.gapWarning, 8040, "surfaced")
  h.near(r.timeToLevel, 100000, 1, "the number itself is NOT adjusted")
end)
```

- [ ] **Step 2: Run and verify failure.**

- [ ] **Step 3: Write `LevelPace/Estimator.lua`** using exactly the spec §6.2 formulation:

```lua
local xpRemaining       = state.xpMax - state.xp
local pool              = state.restedPool or 0
local xpCoveredByRested = math.min(2 * pool, xpRemaining)
local baseWhileRested   = xpCoveredByRested / 2
local baseAfterRested   = xpRemaining - xpCoveredByRested
local timeToLevel       = (baseWhileRested + baseAfterRested) / baseRate
```

`baseRate` is `LP.util.Median(state.baseRateSamples)`; return `nil` for everything rate-derived when it is `nil`.

`mobsLow`/`mobsHigh` come from the interquartile span of `killXPSamples`: sort, take the 25th and 75th percentile values, and divide the rested-adjusted base requirement (`baseWhileRested + baseAfterRested`) by each — **high XP per kill gives the low mob count**, so mind the direction. Return `nil` for both when `#killXPSamples < 10`.

- [ ] **Step 4: Run and verify pass. Add to TOC. Commit.**

```bash
git add LevelPace/Estimator.lua tests/test_estimator.lua LevelPace/LevelPace.toc
git commit -m "feat: rested-aware time-to-level and mobs-to-level range estimator"
```

---

## Task 9: Quests — scan, effort, ranking

The headline feature.

**Files:**
- Create: `LevelPace/Quests.lua`
- Create: `tests/test_quests.lua`
- Modify: `LevelPace/LevelPace.toc`

**Interfaces:**
- Produces:
  - `LP.Quests:Scan() -> array of { index, questID, title, level, xp, complete, objectives = { {have, need, text} } }`
  - `LP.Quests:NoteProgress(questID, objIndex, have, now)` — records an objective tick
  - `LP.Quests:EstimateMinutes(questID) -> minutes|nil, tier` where tier is `"measured"|"inferred"|"unmeasurable"`
  - `LP.Quests:Rank(grindXPPerMin) -> { ready = {...}, worth = {...}, slower = {...} }`

- [ ] **Step 1: Write the failing test `tests/test_quests.lua`** covering:
  - Objective text parsing via the live `QUEST_MONSTERS_KILLED` pattern: `"Ravenous Ghoul slain: 3/10"` → `have = 3, need = 10`.
  - A quest with three recorded ticks over a known elapsed time yields `tier == "measured"` and the right minutes: 3 ticks in 60s with 7 remaining → 140s → ~2.33 min.
  - A quest with one tick yields `tier == "inferred"`.
  - A quest with **no countable objectives** yields `tier == "unmeasurable"` and `minutes == nil` — and `Rank` must place it in `slower` with no fabricated `xpPerMin`. **This is the honesty requirement; assert `xpPerMin == nil`.**
  - `Rank` splits `complete` quests into `ready`, and splits the rest on `xpPerMin > grindXPPerMin`.
  - ⚠ `Scan` saves and restores `GetQuestLogSelection()` — assert the selection is unchanged after a scan. Blizzard's own `WatchFrame_AbandonQuest` does this; failing to restore visibly jumps the user's quest log.

Extend `tests/harness.lua` with quest-log stubs (`GetNumQuestLogEntries`, `GetQuestLogTitle` returning the **10-value** 3.3.5a list with `questID` at position 9, `SelectQuestLogEntry`, `GetQuestLogSelection`, `GetQuestLogRewardXP`, `GetNumQuestLeaderBoards`, `GetQuestLogLeaderBoard`) driven from `harness.state.questLog`.

- [ ] **Step 2: Run and verify failure.**

- [ ] **Step 3: Write `LevelPace/Quests.lua`.**

- `Scan` is debounced off `QUEST_LOG_UPDATE` (fire at most every 1s via `LP:Schedule`) — it is far too expensive per-frame.
- ⚠ Capture `local prev = GetQuestLogSelection()` first; `SelectQuestLogEntry(prev)` in a `finally`-style tail even on error.
- ⚠ `GetQuestLogRewardXP()` takes **no arguments** and reads the currently selected entry.
- ⚠ `questID` is `select(9, GetQuestLogTitle(i))`. Skip header rows (`isHeader` is return 5).
- Effort: `remainingTicks / tickRate`, where `tickRate = ticksObserved / (lastTickTime - firstTickTime)`. Guard division by zero.
- `effectiveXP = xp * (LP.Rates:GetQuestRate() or 1) * LP.Modifiers:HeirloomMultiplier()`. When `GetQuestRate()` is `nil`, mark the result `learning = true` so the UI can say so rather than implying x1 is known.

- [ ] **Step 4: Run and verify pass. Add to TOC. Commit.**

```bash
git add LevelPace/Quests.lua tests/test_quests.lua tests/harness.lua LevelPace/LevelPace.toc
git commit -m "feat: quest scan, measured-effort model, and XP-per-minute ranking"
```

---

## Task 10: UI/Bar — the XP bar

**Files:**
- Create: `LevelPace/UI/Bar.lua`
- Modify: `LevelPace/LevelPace.toc`

No unit tests — verified in-game. Keep the logic out of here; this module only renders what `Estimator` and `Modifiers` already computed.

- [ ] **Step 1: Build the frame.**

`CreateFrame("StatusBar", "LevelPaceBar", UIParent)`. `SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")`. ⚠ Do **not** use `Interface\Buttons\WHITE8X8` — it could not be confirmed on 3.3.5a. Use `Interface\ChatFrame\ChatFrameBackground` for a flat tintable fill.

- [ ] **Step 2: Add the rested overlay.**

⚠ As a `Texture` on the `BORDER` layer **inside** the StatusBar, anchored `TOPRIGHT` to the bar's `TOPLEFT` plus a pixel offset — this is Blizzard's own approach at `MainMenuBar.lua:337-339`. Do **not** create a second StatusBar.

- [ ] **Step 3: Make it movable.** `SetMovable(true)`, `EnableMouse(true)`, `RegisterForDrag("LeftButton")`, `SetClampedToScreen(true)`, `StartMoving`/`StopMovingOrSizing`. ⚠ On save, store `relativeTo:GetName()` — `GetPoint()` returns a **userdata** frame object that cannot be serialised.

- [ ] **Step 4: Backdrop.** ⚠ `SetBackdrop` is a **native method** on 3.3.5a — no `BackdropTemplate`, no template argument.

- [ ] **Step 5: Update on `XP_EVENT`, `PLAYER_XP_UPDATE`, `UPDATE_EXHAUSTION`, and a 1s scheduled tick** (so the time-to-level countdown moves while idle).

- [ ] **Step 6: In-game check.** Copy the folder to `Interface\AddOns\`, `/reload`, confirm the bar appears, fills, and drags. Commit.

```bash
git add LevelPace/UI LevelPace/LevelPace.toc
git commit -m "feat: movable XP bar with Blizzard-style rested overlay"
```

---

## Task 11: UI/Box and UI/Tooltip

**Files:**
- Create: `LevelPace/UI/Box.lua`, `LevelPace/UI/Tooltip.lua`
- Modify: `LevelPace/LevelPace.toc`

- [ ] **Step 1: Box frame** with three layout presets — `compact` (one line), `stacked` (two columns), `full` (labelled rows) — selected from `LP.db.profile.box.layout`. Each line is an independently colourable `FontString` created with `CreateFontString(nil, "OVERLAY")` and `SetFont(path, size, outline)`.

- [ ] **Step 2: Lines rendered** (each individually toggleable): level and %, XP/hr, time to level, mobs to level (range, or `—`), rested pool, and the top-ranked quest.

- [ ] **Step 3: Tooltip** on bar and box hover: `GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")`, then `AddDoubleLine` rows for the level-history summary, source split, confidence, and the gap warning when present. ⚠ `GameTooltip:NumLines()` is unconfirmed on 3.3.5a — do not use it; track your own line count.

- [ ] **Step 4: In-game check. Commit.**

```bash
git add LevelPace/UI/Box.lua LevelPace/UI/Tooltip.lua LevelPace/LevelPace.toc
git commit -m "feat: stats box with layout presets and hover detail tooltip"
```

---

## Task 12: UI/Options — theming and settings

**Files:**
- Create: `LevelPace/UI/Options.lua`
- Modify: `LevelPace/LevelPace.toc`, `LevelPace/Core.lua` (slash commands)

- [ ] **Step 1: Panels.** `InterfaceOptions_AddCategory(panel)` for a root `LevelPace` panel plus sub-panels (`panel.parent = "LevelPace"`) for Appearance, Quests, and Data. Honour `.name`, `.okay`, `.cancel`, `.default`, `.refresh`.

- [ ] **Step 2: Colour pickers.** A reusable swatch button that opens `ColorPickerFrame` with `hasOpacity = true`:

```lua
ColorPickerFrame.func = onChange
ColorPickerFrame.opacityFunc = onChange
ColorPickerFrame.cancelFunc = onCancel      -- receives the previous {r,g,b,opacity}
ColorPickerFrame.hasOpacity = true
ColorPickerFrame.opacity = 1 - alpha        -- NOTE: this is INVERTED, it is "opacity" as transparency
ColorPickerFrame:SetColorRGB(r, g, b)
ColorPickerFrame.previousValues = { r, g, b, 1 - alpha }
ColorPickerFrame:Hide(); ColorPickerFrame:Show()   -- Hide-then-Show forces the callbacks to rebind
```

⚠ `OpacitySliderFrame:GetValue()` returns **transparency**, so alpha is `1 - value`. Getting this backwards makes the sliders feel inverted.

Swatches for: bar fill, bar rested overlay, bar background, bar border, box background, box border, and each text line (label, value, good, neutral, bad).

- [ ] **Step 3: Fonts.** Dropdown over the four fonts the client ships — `Fonts\FRIZQT__.TTF`, `Fonts\ARIALN.TTF`, `Fonts\MORPHEUS.TTF`, `Fonts\SKURRI.TTF` — plus size and outline (`none`/`OUTLINE`/`THICKOUTLINE`) per text element.

- [ ] **Step 4: Sliders** for bar width, bar height, box scale, spacing, and the gap-warning threshold. ⚠ Name every widget (`CreateFrame(..., "LevelPaceOptWidth", ...)`) or `$parentText` fails to resolve and labels never appear. ⚠ `OptionsSliderTemplate` does not snap to `SetValueStep` during a drag — round manually in `OnValueChanged`.

- [ ] **Step 5: Slash commands** in `Core.lua`: `SLASH_LEVELPACE1 = "/lp"`, `SLASH_LEVELPACE2 = "/levelpace"`, with `SlashCmdList["LEVELPACE"]` dispatching bare → options, `reset`, `quests`, `lock`, `unlock`, `debug`.

- [ ] **Step 6: In-game check. Commit.**

```bash
git add LevelPace/UI/Options.lua LevelPace/Core.lua LevelPace/LevelPace.toc
git commit -m "feat: options panel with per-element colour, opacity, font and size"
```

---

## Task 13: Packaging and in-game verification

- [ ] **Step 1: Full test run.** `./tests/run.sh` — all green.
- [ ] **Step 2: Verify the TOC lists every file that exists, in dependency order, with backslashes**, and that no listed file is missing.
- [ ] **Step 3: Write `README.md`** with install instructions (copy the `LevelPace` folder into `World of Warcraft\Interface\AddOns\`), the slash commands, and an honest "known limitations" section: RAF is undetectable, unmeasurable quests get no estimate, quest-rate learning needs 3 turn-ins, SavedVariables are lost on a client crash.
- [ ] **Step 4: Build a zip** for easy transfer: `cd LevelPace/.. && zip -r LevelPace.zip LevelPace`.
- [ ] **Step 5: In-game smoke test:** addon loads with no Lua error; bar appears and drags; kill a mob and confirm XP is counted and the mob name shows in `/lp debug`; accept and complete a quest and confirm a rate sample is recorded; `/lp quests` prints a ranking.
- [ ] **Step 6: Commit.**

```bash
git add README.md
git commit -m "docs: install instructions and known limitations"
```

---

## Self-review notes

**Spec coverage.** §3 platform facts → Tasks 2-5 (traps encoded as tests). §4 architecture → the file structure. §5 rate learning → Task 7. §6.1 level-up delta → Task 3 (`XPBetween`) + Task 6. §6.2 rested projection → Task 8 with the corrected formula. §6.3 gap annotation → Task 6 (`largestGap`) + Task 8 (`gapWarning`) — reported, never filtered. §6.4 history → Task 6. §6.5 mobs range → Task 8. §7 quest ranker → Task 9. §8 modifiers → Task 5. §9 UI and theming → Tasks 10-12. §10 testing → Task 1 harness, then per-task. §11 risks → each has a test or a documented limitation in Task 13's README.

**Not covered, deliberately:** minimap button (spec §12, excluded pending the user's decision); zone-level quest database (spec §2 non-goal).

**Naming consistency check.** `LP.util.*` (Task 2), `LP.data.*` (Task 3), `LP.Ledger`, `LP.Modifiers`, `LP.Rates`, `LP.History`, `LP.Estimator`, `LP.Quests` — module tables are capitalised, helper namespaces lowercase, used consistently in every task. `baseRateSamples` / `killXPSamples` / `restedPool` / `largestGap` are spelled identically in Tasks 6, 8 and 9.
