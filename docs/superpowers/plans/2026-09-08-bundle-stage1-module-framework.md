# Bundle Stage 1 — Module Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn LevelPace's single-purpose core into a module framework that can host three independently-toggleable feature modules, with no observable change to existing behaviour.

**Architecture:** Four additions to `Core.lua` (module registry, module lifecycle, a shared WoW-event router, a combat-log dispatcher), one new shared UI library, and LevelPace itself registered as the first module. The existing 600-assertion suite is the acceptance gate: it must stay green throughout, because Stage 1 changes structure, not behaviour.

**Tech Stack:** Lua 5.1 (LuaJIT for tests), zero dependencies, WoW 3.3.5a client API.

**Spec:** `docs/superpowers/specs/2026-09-08-levelpace-bundle-design.md` §3, §11 (Stage 1).

## Global Constraints

- **WoW 3.3.5a only** (Interface 30300). No API added after 3.3.5a: no `C_*`, no `C_Timer`, no nameplate unit tokens, no hyphen GUIDs, no `CombatLogGetCurrentEventInfo`.
- **Lua 5.1 semantics.** Tests run under `luajit`; `tests/run.sh` refuses anything else because system Lua 5.5's `unpack`/`#`/integer-division differ and would mask bugs.
- **Zero dependencies.** No `os`, no `io`, no sockets.
- **SavedVariables are written only on logout / `/reload` / disconnect.** No flush API exists.
- **`COMBAT_LOG_EVENT_UNFILTERED` on 3.3.5a carries 8 base args**, no `hideCaster`, no raid flags. The normative dispatch signature is `(timestamp, subevent, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)`.
- **Creature GUID decode:** type is `string.sub(guid, 3, 6)` and only `"F130"` is a creature; entry is `tonumber(string.sub(guid, 7, 12), 16)` — the full 24 bits, never `sub(9, 12)`.
- **No behaviour change in this stage.** Every existing test must pass unmodified.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `LevelPace/Core.lua` | modify | gains module registry, lifecycle, event router, CLEU dispatcher |
| `LevelPace/Compat.lua` | modify | gains `util.CreatureID` |
| `LevelPace/UI/Lib.lua` | **create** | shared frame/backdrop/font factory for future module dashboards |
| `LevelPace/Modules/LevelPace.lua` | **create** | registers the existing feature set as the first module |
| `LevelPace/LevelPace.toc` | modify | load `UI\Lib.lua` and `Modules\LevelPace.lua` |
| `tests/test_modules.lua` | **create** | registry + lifecycle |
| `tests/test_events.lua` | **create** | event router + CLEU dispatcher |
| `tests/test_uilib.lua` | **create** | UI library |

`LP.modules` already exists at `Core.lua:16` and is **never read or written anywhere in the codebase** — grep returns exactly that one line. It becomes the registry at zero cost.

**Deliberately NOT in this stage:** rewiring `UI/Bar.lua`, `UI/Box.lua` and `UI/Gauge.lua` onto the new `UI/Lib.lua`. The library is created and tested so Nemesis and RareFinder can build on it; migrating three working frames buys nothing this stage and is exactly where a "no behaviour change" refactor silently changes behaviour. They migrate opportunistically later.

---

### Task 1: Module registry

**Files:**
- Modify: `LevelPace/Core.lua:16` (the dead `LP.modules = {}`) and `LevelPace/Core.lua:146` (defaults)
- Test: `tests/test_modules.lua`

**Interfaces:**
- Consumes: `LP.util.CopyDefaults` (Compat.lua), `LP.db` (Core.lua:148)
- Produces: `LP:RegisterModule(def) -> def`, `LP:GetModule(id) -> def|nil`, `LP:ModuleOrder() -> {id,...}`, `LP:ModuleEnabled(id) -> boolean`

- [x] **Step 1: Write the failing test**

Create `tests/test_modules.lua`:

```lua
package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  return LP
end

h.run("registers a module and reads it back", function()
  local LP = load()
  local def = LP:RegisterModule({ id = "demo", title = "Demo" })
  h.ok(def, "returns the definition")
  h.eq(LP:GetModule("demo"), def, "GetModule finds it")
  h.eq(LP:GetModule("nope"), nil, "unknown id is nil")
end)

h.run("registration order is preserved", function()
  local LP = load()
  LP:RegisterModule({ id = "a" })
  LP:RegisterModule({ id = "b" })
  LP:RegisterModule({ id = "c" })
  local order = LP:ModuleOrder()
  h.eq(#order, 3, "three modules")
  h.eq(order[1], "a", "first")
  h.eq(order[3], "c", "third")
end)

h.run("ModuleOrder returns a copy, not the live table", function()
  local LP = load()
  LP:RegisterModule({ id = "a" })
  local order = LP:ModuleOrder()
  order[1] = "tampered"
  h.eq(LP:ModuleOrder()[1], "a", "internal order is unaffected")
end)

h.run("default enabled state honours def.default", function()
  local LP = load()
  LP:RegisterModule({ id = "on" })
  LP:RegisterModule({ id = "off", default = false })
  h.eq(LP:ModuleEnabled("on"), true, "default is enabled")
  h.eq(LP:ModuleEnabled("off"), false, "explicit default=false")
  h.eq(LP:ModuleEnabled("missing"), false, "unknown module is not enabled")
end)

h.run("saved state overrides the default", function()
  local LP = load()
  LP:RegisterModule({ id = "m", default = true })
  LP.db.profile.modules.m = { enabled = false }
  h.eq(LP:ModuleEnabled("m"), false, "saved false beats default true")
end)

h.run("duplicate id is refused", function()
  local LP = load()
  LP:RegisterModule({ id = "dup" })
  local ok = pcall(function() LP:RegisterModule({ id = "dup" }) end)
  h.eq(ok, false, "second registration raises")
end)

h.run("a module without an id is refused", function()
  local LP = load()
  h.eq(pcall(function() LP:RegisterModule({}) end), false, "no id raises")
  h.eq(pcall(function() LP:RegisterModule("nope") end), false, "non-table raises")
end)

os.exit(h.report() and 0 or 1)
```

- [x] **Step 2: Run it to confirm it fails**

Run: `luajit tests/test_modules.lua`
Expected: FAIL — `attempt to call method 'RegisterModule' (a nil value)`

- [x] **Step 3: Add `modules` to the saved defaults**

In `LevelPace/Core.lua`, inside `LP.defaults.profile` (the table that ends at `Core.lua:146` with `countRestedInProjection = true`), add one line:

```lua
    -- Per-module enable state, keyed by module id. Absent means "use the
    -- module's own default", which is how a module added in a later version
    -- turns itself on for people who already have a saved profile.
    modules = {},
```

- [x] **Step 4: Implement the registry**

In `LevelPace/Core.lua`, replace line 16 (`LP.modules = {}`) with the same line, and add this block immediately after the event bus section (after `LP:Print`, before the Scheduler comment at line ~50):

```lua
-- ---------------------------------------------------------------------------
-- Module registry
--
-- LP.modules is keyed by id for lookup; moduleOrder preserves registration
-- order so the dashboard tabs and the options tree do not reshuffle between
-- sessions (pairs() order is undefined and would).
-- ---------------------------------------------------------------------------

local moduleOrder = {}

function LP:RegisterModule(def)
  if type(def) ~= "table" then error("module definition must be a table", 2) end
  if type(def.id) ~= "string" or def.id == "" then error("module needs an id", 2) end
  if LP.modules[def.id] then error("module already registered: " .. def.id, 2) end
  if def.default == nil then def.default = true end
  def.enabled = false          -- runtime state; the saved flag is separate
  LP.modules[def.id] = def
  moduleOrder[#moduleOrder + 1] = def.id
  return def
end

function LP:GetModule(id)
  return LP.modules[id]
end

function LP:ModuleOrder()
  local out = {}
  for i = 1, #moduleOrder do out[i] = moduleOrder[i] end
  return out
end

function LP:ModuleEnabled(id)
  local def = LP.modules[id]
  if not def then return false end
  local saved = LP.db and LP.db.profile and LP.db.profile.modules
  local row = saved and saved[id]
  if row and row.enabled ~= nil then return row.enabled and true or false end
  return def.default and true or false
end
```

- [x] **Step 5: Run the test to confirm it passes**

Run: `luajit tests/test_modules.lua`
Expected: PASS, 16 assertions

- [x] **Step 6: Confirm nothing else broke**

Run: `./tests/run.sh`
Expected: `ALL GREEN`

- [x] **Step 7: Commit**

```bash
git add LevelPace/Core.lua tests/test_modules.lua
git commit -m "feat(core): module registry

LP.modules has existed and been dead since the first commit. It becomes
the registry. Registration order is kept separately because pairs() order
is undefined and would reshuffle dashboard tabs between sessions."
```

---

### Task 2: Module lifecycle

**Files:**
- Modify: `LevelPace/Core.lua` (registry block from Task 1; `LP:Bootstrap` at `Core.lua:169-188`)
- Test: `tests/test_modules.lua` (append)

**Interfaces:**
- Consumes: `LP:ModuleEnabled`, `LP:ModuleOrder`, `LP:Fire` (Core.lua:30)
- Produces: `LP:SetModuleEnabled(id, on) -> boolean`, `LP:StartModules()`, and the events `MODULE_ENABLED` / `MODULE_DISABLED`, each carrying the module id

- [x] **Step 1: Write the failing test**

Append to `tests/test_modules.lua`, before `os.exit(h.report() and 0 or 1)`:

```lua
h.run("enabling a module calls OnEnable exactly once", function()
  local LP = load()
  local calls = 0
  LP:RegisterModule({ id = "m", OnEnable = function() calls = calls + 1 end })
  LP:SetModuleEnabled("m", true)
  h.eq(calls, 1, "OnEnable ran")
  LP:SetModuleEnabled("m", true)
  h.eq(calls, 1, "enabling an enabled module is a no-op")
end)

h.run("disabling calls OnDisable and persists", function()
  local LP = load()
  local off = 0
  LP:RegisterModule({ id = "m", OnDisable = function() off = off + 1 end })
  LP:SetModuleEnabled("m", true)
  LP:SetModuleEnabled("m", false)
  h.eq(off, 1, "OnDisable ran")
  h.eq(LP.db.profile.modules.m.enabled, false, "state saved")
  h.eq(LP:ModuleEnabled("m"), false, "reads back disabled")
  LP:SetModuleEnabled("m", false)
  h.eq(off, 1, "disabling a disabled module is a no-op")
end)

h.run("lifecycle fires bus events", function()
  local LP = load()
  local seen = {}
  LP:On("MODULE_ENABLED", function(id) seen[#seen + 1] = "on:" .. id end)
  LP:On("MODULE_DISABLED", function(id) seen[#seen + 1] = "off:" .. id end)
  LP:RegisterModule({ id = "m" })
  LP:SetModuleEnabled("m", true)
  LP:SetModuleEnabled("m", false)
  h.eq(seen[1], "on:m", "enable event")
  h.eq(seen[2], "off:m", "disable event")
end)

h.run("a raising OnEnable does not take down the addon", function()
  local LP = load()
  LP:RegisterModule({ id = "bad", OnEnable = function() error("boom") end })
  local ok = pcall(function() LP:SetModuleEnabled("bad", true) end)
  h.eq(ok, true, "SetModuleEnabled survived")
  h.eq(LP:GetModule("bad").enabled, true, "still marked enabled")
end)

h.run("StartModules enables only what is enabled", function()
  local LP = load()
  local started = {}
  LP:RegisterModule({ id = "a", OnEnable = function() started[#started + 1] = "a" end })
  LP:RegisterModule({ id = "b", default = false,
                      OnEnable = function() started[#started + 1] = "b" end })
  LP:StartModules()
  h.eq(#started, 1, "one module started")
  h.eq(started[1], "a", "the enabled one")
end)

h.run("SetModuleEnabled on an unknown id returns false", function()
  local LP = load()
  h.eq(LP:SetModuleEnabled("ghost", true), false, "no such module")
end)
```

- [x] **Step 2: Run it to confirm it fails**

Run: `luajit tests/test_modules.lua`
Expected: FAIL — `attempt to call method 'SetModuleEnabled' (a nil value)`

- [x] **Step 3: Implement the lifecycle**

Append to the module registry block in `LevelPace/Core.lua`:

```lua
function LP:SetModuleEnabled(id, on)
  local def = LP.modules[id]
  if not def then return false end
  on = on and true or false

  if LP.db and LP.db.profile then
    LP.db.profile.modules = LP.db.profile.modules or {}
    LP.db.profile.modules[id] = LP.db.profile.modules[id] or {}
    LP.db.profile.modules[id].enabled = on
  end

  if on == def.enabled then return true end     -- already in the wanted state
  def.enabled = on

  if on then
    -- A module that throws while starting must not stop the others, exactly
    -- as with the event bus.
    if def.OnEnable then
      local ok, err = pcall(def.OnEnable, def)
      if not ok and LP.debug then
        LP:Print("|cffff5555" .. id .. " OnEnable:|r " .. tostring(err))
      end
    end
    LP:Fire("MODULE_ENABLED", id)
  else
    LP:UnregisterModuleEvents(id)
    if def.OnDisable then
      local ok, err = pcall(def.OnDisable, def)
      if not ok and LP.debug then
        LP:Print("|cffff5555" .. id .. " OnDisable:|r " .. tostring(err))
      end
    end
    LP:Fire("MODULE_DISABLED", id)
  end
  return true
end

function LP:StartModules()
  local order = LP:ModuleOrder()
  for i = 1, #order do
    if LP:ModuleEnabled(order[i]) then LP:SetModuleEnabled(order[i], true) end
  end
end
```

`LP:UnregisterModuleEvents` does not exist until Task 3. Add this temporary stub immediately above `LP:SetModuleEnabled`, to be replaced in Task 3:

```lua
-- Replaced by the real implementation in the event router below.
function LP:UnregisterModuleEvents(_) end
```

- [x] **Step 4: Run the test to confirm it passes**

Run: `luajit tests/test_modules.lua`
Expected: PASS

- [x] **Step 5: Call StartModules from Bootstrap**

In `LevelPace/Core.lua`, inside `LP:Bootstrap`'s `PLAYER_LOGIN` branch (`Core.lua:180-186`), add `LP:StartModules()` **after** `LP:Fire("PLAYER_READY")`:

```lua
    elseif event == "PLAYER_LOGIN" then
      if not LP.db then LP:InitDB() end
      LP:StartDriver()
      LP:Fire("PLAYER_READY")
      LP:StartModules()
      LP:Print("loaded. /lp for options, /lp board for rankings.")
      LP:CheckVersion()
    end
```

Order is deliberate: every existing file hooks `PLAYER_READY` at file scope, so firing it first keeps their wiring identical and guarantees this stage changes no behaviour.

- [x] **Step 6: Run the full suite**

Run: `./tests/run.sh`
Expected: `ALL GREEN` — in particular `tests/test_smoke.lua`, which drives the real `ADDON_LOADED` → `PLAYER_LOGIN` path

- [x] **Step 7: Commit**

```bash
git add LevelPace/Core.lua tests/test_modules.lua
git commit -m "feat(core): module enable/disable lifecycle

StartModules runs after PLAYER_READY so existing file-scope wiring is
untouched and this stage stays behaviour-neutral."
```

---

### Task 3: Shared WoW-event router

**Files:**
- Modify: `LevelPace/Core.lua` (replace the Task 2 stub)
- Test: `tests/test_events.lua`

**Interfaces:**
- Consumes: `LP.util.SafeRegisterEvent` (Compat.lua)
- Produces: `LP:RegisterEvent(event, moduleID, fn) -> boolean`, `LP:UnregisterModuleEvents(moduleID)`, `LP.eventFrame`

Today every module opens its own hidden frame and registers WoW events directly. Three modules would mean three frames and three `COMBAT_LOG_EVENT_UNFILTERED` handlers — the hottest path in the addon during a 40-player battleground.

- [x] **Step 1: Write the failing test**

Create `tests/test_events.lua`:

```lua
package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  return LP
end

local function fire(LP, event, ...)
  LP.eventFrame.scripts.OnEvent(LP.eventFrame, event, ...)
end

h.run("routes an event to its handler", function()
  local LP = load()
  local got
  LP:RegisterEvent("PLAYER_DEAD", "m", function(a) got = a end)
  h.ok(LP.eventFrame, "one shared frame was created")
  h.eq(LP.eventFrame.events.PLAYER_DEAD, true, "registered with the client")
  fire(LP, "PLAYER_DEAD", "arg")
  h.eq(got, "arg", "handler received the payload")
end)

h.run("two modules share one frame and both receive", function()
  local LP = load()
  local seen = {}
  LP:RegisterEvent("PLAYER_DEAD", "a", function() seen[#seen + 1] = "a" end)
  LP:RegisterEvent("PLAYER_DEAD", "b", function() seen[#seen + 1] = "b" end)
  local frame = LP.eventFrame
  LP:RegisterEvent("PLAYER_ALIVE", "a", function() end)
  h.eq(LP.eventFrame, frame, "still the same frame")
  fire(LP, "PLAYER_DEAD")
  h.eq(#seen, 2, "both handlers ran")
end)

h.run("a raising handler does not stop the others", function()
  local LP = load()
  local ran = false
  LP:RegisterEvent("PLAYER_DEAD", "bad", function() error("boom") end)
  LP:RegisterEvent("PLAYER_DEAD", "good", function() ran = true end)
  fire(LP, "PLAYER_DEAD")
  h.eq(ran, true, "the good handler still ran")
end)

h.run("unregistering a module drops only its handlers", function()
  local LP = load()
  local seen = {}
  LP:RegisterEvent("PLAYER_DEAD", "a", function() seen[#seen + 1] = "a" end)
  LP:RegisterEvent("PLAYER_DEAD", "b", function() seen[#seen + 1] = "b" end)
  LP:UnregisterModuleEvents("a")
  fire(LP, "PLAYER_DEAD")
  h.eq(#seen, 1, "one handler left")
  h.eq(seen[1], "b", "the right one")
  h.eq(LP.eventFrame.events.PLAYER_DEAD, true, "still registered, b needs it")
end)

h.run("the last handler for an event unregisters it from the client", function()
  local LP = load()
  LP:RegisterEvent("PLAYER_DEAD", "a", function() end)
  LP:UnregisterModuleEvents("a")
  h.eq(LP.eventFrame.events.PLAYER_DEAD, nil, "unregistered with the client")
end)

h.run("firing an event with no handlers is safe", function()
  local LP = load()
  LP:RegisterEvent("PLAYER_DEAD", "a", function() end)
  h.eq(pcall(fire, LP, "SOMETHING_ELSE"), true, "no error")
end)

os.exit(h.report() and 0 or 1)
```

- [x] **Step 2: Run it to confirm it fails**

Run: `luajit tests/test_events.lua`
Expected: FAIL — `attempt to call method 'RegisterEvent' (a nil value)`

- [x] **Step 3: Implement the router**

In `LevelPace/Core.lua`, delete the `LP:UnregisterModuleEvents` stub from Task 2 and add this section immediately after the module registry block:

```lua
-- ---------------------------------------------------------------------------
-- Shared WoW-event router
--
-- ONE frame for the whole addon. Frames are never garbage collected on
-- 3.3.5a, and COMBAT_LOG_EVENT_UNFILTERED is the hottest path in the addon
-- during a battleground -- three modules each registering their own handler
-- for it would triple that cost for no gain.
-- ---------------------------------------------------------------------------

local eventOwners = {}     -- event -> array of { id = moduleID, fn = handler }

local function ensureEventFrame()
  if LP.eventFrame then return LP.eventFrame end
  if not CreateFrame then return nil end
  local f = CreateFrame("Frame", "LevelPaceEvents")
  f:SetScript("OnEvent", function(_, event, ...)
    local list = eventOwners[event]
    if not list then return end
    for i = 1, #list do
      local ok, err = pcall(list[i].fn, ...)
      if not ok and LP.debug then
        LP:Print("|cffff5555" .. list[i].id .. " / " .. event .. ":|r " .. tostring(err))
      end
    end
  end)
  LP.eventFrame = f
  return f
end

function LP:RegisterEvent(event, moduleID, fn)
  local f = ensureEventFrame()
  if not f then return false end
  if not eventOwners[event] then
    eventOwners[event] = {}
    LP.util.SafeRegisterEvent(f, event)
  end
  table.insert(eventOwners[event], { id = moduleID, fn = fn })
  return true
end

function LP:UnregisterModuleEvents(moduleID)
  for event, list in pairs(eventOwners) do
    for i = #list, 1, -1 do
      if list[i].id == moduleID then table.remove(list, i) end
    end
    if #list == 0 then
      eventOwners[event] = nil
      if LP.eventFrame and LP.eventFrame.UnregisterEvent then
        LP.eventFrame:UnregisterEvent(event)
      end
    end
  end
end
```

- [x] **Step 4: Run both test files**

Run: `luajit tests/test_events.lua && luajit tests/test_modules.lua`
Expected: PASS for both

- [x] **Step 5: Run the full suite**

Run: `./tests/run.sh`
Expected: `ALL GREEN`

- [x] **Step 6: Commit**

```bash
git add LevelPace/Core.lua tests/test_events.lua
git commit -m "feat(core): shared WoW-event router

One frame for the whole addon, dispatching to per-module handlers, so a
disabled module can actually stop receiving events. Frames are never
garbage collected on 3.3.5a and CLEU is the hottest path in a BG."
```

---

### Task 4: Combat-log dispatcher and creature GUID decode

**Files:**
- Modify: `LevelPace/Compat.lua` (add `util.CreatureID`), `LevelPace/Core.lua` (add the dispatcher)
- Test: `tests/test_events.lua` (append), `tests/test_compat.lua` (append)

**Interfaces:**
- Consumes: `LP:RegisterEvent` (Task 3)
- Produces: `LP.util.CreatureID(guid) -> number|nil`, `LP:OnCombatLog(moduleID, subevents, fn)`, `LP:DispatchCombatLog(...)`

- [x] **Step 1: Write the failing GUID test**

Append to `tests/test_compat.lua`, before `os.exit(h.report() and 0 or 1)`:

```lua
h.run("CreatureID decodes a real 3.3.5a creature GUID", function()
  local LP = load()
  -- Captured live from the user's own 3.3.5a server: Mangy Wolf, Elwynn Forest.
  h.eq(LP.util.CreatureID("0xF13000020D02DD76"), 525, "entry 525")
end)

h.run("CreatureID reads the full 24-bit entry", function()
  local LP = load()
  -- Entry 0x010000 = 65536. sub(9,12) would read "0000" and return 0; custom
  -- NPCs on private servers routinely live above 65535.
  h.eq(LP.util.CreatureID("0xF13001000000000001"), nil, "malformed length is nil")
  h.eq(LP.util.CreatureID("0xF130010000000001"), 65536, "24-bit entry")
end)

h.run("CreatureID rejects non-creatures", function()
  local LP = load()
  h.eq(LP.util.CreatureID("0xF140000C6D000001"), nil, "pet (F140)")
  h.eq(LP.util.CreatureID("0xF150000C6D000001"), nil, "vehicle (F150)")
  h.eq(LP.util.CreatureID("0x0000000000ABCDEF"), nil, "player")
end)

h.run("CreatureID is defensive about junk", function()
  local LP = load()
  h.eq(LP.util.CreatureID(nil), nil, "nil")
  h.eq(LP.util.CreatureID(42), nil, "number")
  h.eq(LP.util.CreatureID(""), nil, "empty string")
  h.eq(LP.util.CreatureID("0xF130"), nil, "too short")
end)
```

- [x] **Step 2: Run it to confirm it fails**

Run: `luajit tests/test_compat.lua`
Expected: FAIL — `attempt to call field 'CreatureID' (a nil value)`

- [x] **Step 3: Implement CreatureID**

Add to `LevelPace/Compat.lua`, alongside the other `util.*` functions:

```lua
-- Decode a 3.3.5a creature GUID.
--
-- Format is "0x" plus 16 hex digits: 4 digits of type, 6 of creature entry,
-- 6 of spawn counter. Returns nil for anything that is not a creature.
--
--   0xF13000020D02DD76
--     F130            type   = HIGHGUID_UNIT
--         00020D      entry  = 525   (Mangy Wolf)
--               02DD76  spawn counter
--
-- The entry is 24 bits. Reading only sub(9,12) -- the low 16 -- is correct for
-- every Blizzlike WotLK creature (max entry 38453) and silently decodes custom
-- server NPCs at entry >= 65536 as 0.
function util.CreatureID(guid)
  if type(guid) ~= "string" then return nil end
  if string.len(guid) ~= 18 then return nil end
  if string.upper(string.sub(guid, 3, 6)) ~= "F130" then return nil end
  return tonumber(string.sub(guid, 7, 12), 16)
end
```

- [x] **Step 4: Run the GUID test**

Run: `luajit tests/test_compat.lua`
Expected: PASS

- [x] **Step 5: Write the failing dispatcher test**

Append to `tests/test_events.lua`, before `os.exit(h.report() and 0 or 1)`:

```lua
h.run("combat log dispatches only the subevents a module asked for", function()
  local LP = load()
  local seen = {}
  LP:OnCombatLog("m", { "UNIT_DIED" }, function(_, subevent) seen[#seen + 1] = subevent end)
  -- NORMATIVE 3.3.5a order: 8 base args, no hideCaster, no raid flags.
  fire(LP, "COMBAT_LOG_EVENT_UNFILTERED",
       1, "UNIT_DIED",     "0x1", "Src", 0, "0xF13000020D02DD76", "Wolf", 0)
  fire(LP, "COMBAT_LOG_EVENT_UNFILTERED",
       2, "SPELL_DAMAGE",  "0x1", "Src", 0, "0xF13000020D02DD76", "Wolf", 0)
  h.eq(#seen, 1, "only the subscribed subevent")
  h.eq(seen[1], "UNIT_DIED", "the right one")
end)

h.run("combat log preserves the full 3.3.5a argument order", function()
  local LP = load()
  local a = {}
  LP:OnCombatLog("m", { "PARTY_KILL" }, function(...)
    for i = 1, select("#", ...) do a[i] = (select(i, ...)) end
  end)
  fire(LP, "COMBAT_LOG_EVENT_UNFILTERED",
       99, "PARTY_KILL", "0xSRC", "Killer", 1, "0xF13000020D02DD76", "Wolf", 2, "extra")
  h.eq(a[1], 99, "timestamp")
  h.eq(a[2], "PARTY_KILL", "subevent")
  h.eq(a[3], "0xSRC", "srcGUID")
  h.eq(a[4], "Killer", "srcName")
  h.eq(a[5], 1, "srcFlags")
  h.eq(a[6], "0xF13000020D02DD76", "dstGUID")
  h.eq(a[7], "Wolf", "dstName")
  h.eq(a[8], 2, "dstFlags")
  h.eq(a[9], "extra", "trailing args pass through")
end)

h.run("disabling a module stops its combat log handler", function()
  local LP = load()
  local n = 0
  LP:RegisterModule({ id = "m" })
  LP:OnCombatLog("m", { "UNIT_DIED" }, function() n = n + 1 end)
  fire(LP, "COMBAT_LOG_EVENT_UNFILTERED", 1, "UNIT_DIED", "0x1", "S", 0, "0x2", "D", 0)
  h.eq(n, 1, "received while enabled")
  LP:UnregisterModuleEvents("m")
  fire(LP, "COMBAT_LOG_EVENT_UNFILTERED", 2, "UNIT_DIED", "0x1", "S", 0, "0x2", "D", 0)
  h.eq(n, 1, "silent after unregister")
end)
```

- [x] **Step 6: Run it to confirm it fails**

Run: `luajit tests/test_events.lua`
Expected: FAIL — `attempt to call method 'OnCombatLog' (a nil value)`

- [x] **Step 7: Implement the dispatcher**

Append to the event-router section in `LevelPace/Core.lua`:

```lua
-- Combat log.
--
-- The dispatch signature is NORMATIVE and matches 3.3.5a exactly: 8 base
-- args, no hideCaster (Cataclysm), no raid flags (MoP). Handlers receive
-- these arguments in this order.
--
--   (timestamp, subevent, srcGUID, srcName, srcFlags,
--    dstGUID, dstName, dstFlags, ...)

local cleuHandlers = {}

function LP:DispatchCombatLog(timestamp, subevent, srcGUID, srcName, srcFlags,
                              dstGUID, dstName, dstFlags, ...)
  for i = 1, #cleuHandlers do
    local hnd = cleuHandlers[i]
    -- Cheapest possible rejection first: this runs for every combat log line
    -- in a 40-player battleground.
    if hnd.subevents[subevent] then
      local ok, err = pcall(hnd.fn, timestamp, subevent, srcGUID, srcName, srcFlags,
                            dstGUID, dstName, dstFlags, ...)
      if not ok and LP.debug then
        LP:Print("|cffff5555" .. hnd.id .. " / CLEU:|r " .. tostring(err))
      end
    end
  end
end

function LP:OnCombatLog(moduleID, subevents, fn)
  local set = {}
  for i = 1, #subevents do set[subevents[i]] = true end
  cleuHandlers[#cleuHandlers + 1] = { id = moduleID, subevents = set, fn = fn }
  if #cleuHandlers == 1 then
    LP:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", "__cleu", function(...)
      LP:DispatchCombatLog(...)
    end)
  end
  return true
end
```

`UnregisterModuleEvents` must also drop CLEU handlers. Add this loop at the top of its body, before the `for event, list in pairs(eventOwners)` loop:

```lua
  for i = #cleuHandlers, 1, -1 do
    if cleuHandlers[i].id == moduleID then table.remove(cleuHandlers, i) end
  end
```

- [x] **Step 8: Run the tests**

Run: `luajit tests/test_events.lua && luajit tests/test_compat.lua`
Expected: PASS for both

- [x] **Step 9: Run the full suite**

Run: `./tests/run.sh`
Expected: `ALL GREEN`

- [x] **Step 10: Commit**

```bash
git add LevelPace/Core.lua LevelPace/Compat.lua tests/test_events.lua tests/test_compat.lua
git commit -m "feat(core): combat log dispatcher and creature GUID decode

The dispatch signature is normative 3.3.5a: 8 base args, no hideCaster,
no raid flags. CreatureID reads the full 24-bit entry -- sub(9,12) reads
only the low 16 and decodes custom NPCs above 65535 as 0.

GUID decode verified against a live capture from the target server:
0xF13000020D02DD76 -> entry 525, Mangy Wolf."
```

---

### Task 5: Shared UI library

**Files:**
- Create: `LevelPace/UI/Lib.lua`
- Modify: `LevelPace/LevelPace.toc` (add `UI\Lib.lua` after `UI\Bar.lua`'s line — see step 4)
- Test: `tests/test_uilib.lua`

**Interfaces:**
- Consumes: `LP.util` (Compat.lua)
- Produces: `LP.UI.Panel(name, opts) -> frame`, `LP.UI.ApplyColor(region, color)`, `LP.UI.ApplyFont(fontString, style)`, `LP.UI.Style(frame, style)`

Nemesis and RareFinder each need a dashboard. Without this, each grows its own copy of the backdrop/font/colour code that `UI/Box.lua` and `UI/Gauge.lua` already duplicate.

- [x] **Step 1: Write the failing test**

Create `tests/test_uilib.lua`:

```lua
package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/UI/Lib.lua")
  return _G.LevelPace
end

h.run("Panel builds a frame with a backdrop", function()
  local LP = load()
  local f = LP.UI.Panel("TestPanel", { width = 200, height = 80 })
  h.ok(f, "frame returned")
  h.eq(f:GetWidth(), 200, "width applied")
  h.eq(f:GetHeight(), 80, "height applied")
  h.eq(f:GetName(), "TestPanel", "named")
end)

h.run("ApplyColor handles a colour table with alpha", function()
  local LP = load()
  local region = { }
  function region:SetTexture(r, g, b, a) self.c = { r, g, b, a } end
  LP.UI.ApplyColor(region, { r = 0.5, g = 0.25, b = 1, a = 0.8 })
  h.eq(region.c[1], 0.5, "r")
  h.eq(region.c[4], 0.8, "a")
end)

h.run("ApplyColor defaults a missing alpha to 1", function()
  local LP = load()
  local region = {}
  function region:SetTexture(r, g, b, a) self.c = { r, g, b, a } end
  LP.UI.ApplyColor(region, { r = 1, g = 1, b = 1 })
  h.eq(region.c[4], 1, "alpha defaulted")
end)

h.run("ApplyColor ignores junk rather than raising", function()
  local LP = load()
  local region = {}
  function region:SetTexture() self.called = true end
  h.eq(pcall(LP.UI.ApplyColor, region, nil), true, "nil colour is safe")
  h.eq(pcall(LP.UI.ApplyColor, nil, { r = 1, g = 1, b = 1 }), true, "nil region is safe")
end)

h.run("ApplyFont sets path, size and outline", function()
  local LP = load()
  local fs = {}
  function fs:SetFont(p, s, o) self.font = { p, s, o } end
  LP.UI.ApplyFont(fs, { font = "Fonts\\FRIZQT__.TTF", fontSize = 13, outline = "OUTLINE" })
  h.eq(fs.font[1], "Fonts\\FRIZQT__.TTF", "path")
  h.eq(fs.font[2], 13, "size")
  h.eq(fs.font[3], "OUTLINE", "outline")
end)

os.exit(h.report() and 0 or 1)
```

- [x] **Step 2: Run it to confirm it fails**

Run: `luajit tests/test_uilib.lua`
Expected: FAIL — `module 'LevelPace/UI/Lib.lua' not found` or `attempt to index field 'UI' (a nil value)`

- [x] **Step 3: Implement the library**

Create `LevelPace/UI/Lib.lua`:

```lua
-- LevelPace :: UI/Lib
--
-- Shared frame, colour and font helpers. Every module dashboard is built from
-- these so the colour/opacity/font/size options behave identically everywhere
-- instead of each module growing its own copy.

local LP = _G.LevelPace
LP.UI = LP.UI or {}
local UI = LP.UI

local BACKDROP = {
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

function UI.Panel(name, opts)
  if not CreateFrame then return nil end
  opts = opts or {}
  local f = CreateFrame("Frame", name, opts.parent or UIParent)
  f:SetWidth(opts.width or 200)
  f:SetHeight(opts.height or 100)
  f:SetPoint(opts.point or "CENTER", UIParent,
             opts.relPoint or "CENTER", opts.x or 0, opts.y or 0)
  if f.SetBackdrop then f:SetBackdrop(opts.backdrop or BACKDROP) end
  if opts.movable and f.SetMovable then
    f:SetMovable(true)
    f:EnableMouse(true)
  end
  return f
end

function UI.ApplyColor(region, color)
  if not region or not color then return end
  local a = color.a
  if a == nil then a = 1 end
  if region.SetTexture then
    region:SetTexture(color.r or 0, color.g or 0, color.b or 0, a)
  elseif region.SetTextColor then
    region:SetTextColor(color.r or 0, color.g or 0, color.b or 0, a)
  end
end

function UI.ApplyFont(fontString, style)
  if not fontString or not style or not fontString.SetFont then return end
  fontString:SetFont(style.font or "Fonts\\FRIZQT__.TTF",
                     style.fontSize or 11,
                     style.outline or "")
end

function UI.Style(frame, style)
  if not frame or not style then return end
  if style.scale and frame.SetScale then frame:SetScale(style.scale) end
  if style.alpha and frame.SetAlpha then frame:SetAlpha(style.alpha) end
end
```

- [x] **Step 4: Add it to the TOC**

In `LevelPace/LevelPace.toc`, insert `UI\Lib.lua` **before** `UI\Bar.lua` (currently line 23), so the library exists before anything that might use it:

```
UI\Lib.lua
UI\Bar.lua
```

- [x] **Step 5: Run the test**

Run: `luajit tests/test_uilib.lua`
Expected: PASS

- [x] **Step 6: Run the full suite**

Run: `./tests/run.sh`
Expected: `ALL GREEN`

- [x] **Step 7: Commit**

```bash
git add LevelPace/UI/Lib.lua LevelPace/LevelPace.toc tests/test_uilib.lua
git commit -m "feat(ui): shared frame, colour and font helpers

Additive only. Bar/Box/Gauge keep their own code this stage -- migrating
three working frames buys nothing here and is exactly where a
behaviour-neutral refactor stops being behaviour-neutral."
```

---

### Task 6: Register LevelPace as the first module

**Files:**
- Create: `LevelPace/Modules/LevelPace.lua`
- Modify: `LevelPace/LevelPace.toc`
- Test: `tests/test_modules.lua` (append)

**Interfaces:**
- Consumes: `LP:RegisterModule` (Task 1), `LP.Bar` / `LP.Box` / `LP.Gauge` (UI files)
- Produces: the registered module `"levelpace"`

The toggle controls the module's **visible surface**. The existing files keep their own `PLAYER_READY` wiring, so this stage stays behaviour-neutral; wholesale relocation of eight files into `OnEnable` is a later stage's work and is not needed to unblock Nemesis or RareFinder.

- [x] **Step 1: Write the failing test**

Append to `tests/test_modules.lua`, before `os.exit(h.report() and 0 or 1)`:

```lua
h.run("levelpace registers itself as a module", function()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Modules/LevelPace.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  local m = LP:GetModule("levelpace")
  h.ok(m, "registered")
  h.eq(m.title, "LevelPace", "has a title")
  h.eq(m.default, true, "enabled by default")
  h.eq(LP:ModuleEnabled("levelpace"), true, "reads as enabled")
end)

h.run("disabling levelpace hides its frames", function()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Modules/LevelPace.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  local shown = { bar = true, box = true }
  LP.Bar = { frame = { Hide = function(s) shown.bar = false end,
                       Show = function(s) shown.bar = true end } }
  LP.Box = { frame = { Hide = function(s) shown.box = false end,
                       Show = function(s) shown.box = true end } }
  LP:SetModuleEnabled("levelpace", true)
  LP:SetModuleEnabled("levelpace", false)
  h.eq(shown.bar, false, "bar hidden")
  h.eq(shown.box, false, "box hidden")
  LP:SetModuleEnabled("levelpace", true)
  h.eq(shown.bar, true, "bar shown again")
end)
```

- [x] **Step 2: Run it to confirm it fails**

Run: `luajit tests/test_modules.lua`
Expected: FAIL — file not found

- [x] **Step 3: Implement the module**

Create `LevelPace/Modules/LevelPace.lua`:

```lua
-- LevelPace :: Modules/LevelPace
--
-- The levelling feature set, registered as a module so it can be toggled
-- alongside Nemesis and RareFinder.
--
-- The existing files keep their own PLAYER_READY wiring. This module owns the
-- visible surface only, which is what "turn the dashboard off" means to a
-- player, and keeps this stage behaviour-neutral.

local LP = _G.LevelPace

local function each(fn)
  for _, part in ipairs({ LP.Bar, LP.Box, LP.Gauge }) do
    if part and part.frame then fn(part.frame) end
  end
end

LP:RegisterModule({
  id = "levelpace",
  title = "LevelPace",
  desc = "XP pace, time to level, and whether your quests beat grinding.",
  default = true,

  OnEnable = function()
    each(function(f) if f.Show then f:Show() end end)
  end,

  OnDisable = function()
    each(function(f) if f.Hide then f:Hide() end end)
  end,
})
```

- [x] **Step 4: Add it to the TOC**

In `LevelPace/LevelPace.toc`, add `Modules\LevelPace.lua` immediately **before** `Init.lua` (currently the last entry, line 29):

```
Modules\LevelPace.lua
Init.lua
```

- [x] **Step 5: Run the test**

Run: `luajit tests/test_modules.lua`
Expected: PASS

- [x] **Step 6: Run the full suite**

Run: `./tests/run.sh`
Expected: `ALL GREEN` — all 12 existing suites plus the 3 new ones

- [x] **Step 7: Verify the TOC lists every file**

Run:

```bash
for f in $(grep -Eo '^[A-Za-z].*\.lua' LevelPace/LevelPace.toc | tr '\\' '/'); do
  [ -f "LevelPace/$f" ] || echo "MISSING: $f"
done; echo "toc check done"
```

Expected: `toc check done` with no `MISSING` lines. A file present but absent from the TOC loads in tests and not in game — the failure mode that once made the whole addon load and do nothing.

- [x] **Step 8: Commit**

```bash
git add LevelPace/Modules/LevelPace.lua LevelPace/LevelPace.toc tests/test_modules.lua
git commit -m "feat: register LevelPace as the first module

Completes Stage 1. The framework now hosts a real module; Nemesis and
RareFinder plug into the same registry, router and UI library."
```

---

## Manual verification in game

The suite cannot prove the addon loads in the real client. After Task 6:

1. Copy `LevelPace/` into `Interface\AddOns\`, launch, log in.
2. Expect the usual `LevelPace: loaded. /lp for options...` line — its absence means a TOC or load-order fault.
3. `/lp` — options open, bar and box render as before.
4. `/reload` — settings survive.
5. `/dump LevelPace:ModuleOrder()` → `{ "levelpace" }`.
6. `/dump LevelPace:SetModuleEnabled("levelpace", false)` → bar, box and gauge disappear. Re-enable → they return.
7. `/dump LevelPace.util.CreatureID(UnitGUID("target"))` on any mob → its NPC entry.

---

## Self-review

**Spec coverage.** Stage 1 per spec §11 is "module registry, WoW-event router, `UI/Lib.lua`, per-module toggles, LevelPace becomes a module, no behaviour change" — Tasks 1+2, 3+4, 5, 1+2+6, 6, and the full-suite gate at the end of every task respectively. The normative CLEU signature (spec §3.3) is Task 4 Step 7; the GUID decode (spec §2) is Task 4 Step 3; disable semantics (spec §3.2) are Task 2 Step 3 plus Task 3's unregistration.

**Placeholders.** None. Every step carries the code or the exact command.

**Type consistency.** `LP:RegisterModule` / `GetModule` / `ModuleOrder` / `ModuleEnabled` / `SetModuleEnabled` / `StartModules` / `RegisterEvent` / `UnregisterModuleEvents` / `OnCombatLog` / `DispatchCombatLog` / `util.CreatureID` / `UI.Panel` / `UI.ApplyColor` / `UI.ApplyFont` / `UI.Style` are each defined once and used consistently. `LP:UnregisterModuleEvents` is a stub in Task 2 and replaced in Task 3 — flagged in both places rather than left as a forward reference.

**One known gap, deliberate.** `LP:On` still has no unsubscribe path; `handlers` is file-local at `Core.lua:23`. Module disable therefore gates at the WoW-event router, not the internal bus, so a disabled module's *bus* handlers still run. Harmless for LevelPace, whose bus handlers only redraw hidden frames. Nemesis and RareFinder must put their collection on the router, not the bus — recorded here because it is a real constraint on Stages 3 and 4.
