-- LevelPace :: Core
-- Addon table, internal event bus, throttled scheduler, saved-variables
-- bootstrap and slash commands.

local ADDON_NAME = ...

local LP = {}
_G.LevelPace = LP

LP.ADDON_NAME = "LevelPace"

-- Single source of truth is the TOC, so a release bump touches one line.
-- GetAddOnMetadata works on 3.3.5a; the fallback covers being loaded outside
-- the game, as the test harness does.
LP.VERSION = (GetAddOnMetadata and GetAddOnMetadata("LevelPace", "Version")) or "0.0.0"
LP.modules = {}
LP.debug = false

-- ---------------------------------------------------------------------------
-- Event bus
-- ---------------------------------------------------------------------------

local handlers = {}

function LP:On(event, fn)
  handlers[event] = handlers[event] or {}
  table.insert(handlers[event], fn)
end

function LP:Fire(event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    -- One bad handler must never take down the others. A parse error in the
    -- ledger should not stop the bar redrawing.
    local ok, err = pcall(list[i], ...)
    if not ok and LP.debug then
      LP:Print("|cffff5555error in " .. tostring(event) .. ":|r " .. tostring(err))
    end
  end
end

function LP:Print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  local msg = "|cff44ddffLevelPace:|r " .. table.concat(parts, " ")
  local frame = _G.DEFAULT_CHAT_FRAME
  if frame and frame.AddMessage then frame:AddMessage(msg) else print(msg) end
end

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

function LP:UnregisterModuleEvents(moduleID)
  for i = #cleuHandlers, 1, -1 do
    if cleuHandlers[i].id == moduleID then table.remove(cleuHandlers, i) end
  end
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

-- A frame owned by a module must not draw while that module is switched off.
--
-- This is not belt-and-braces. The internal bus has NO unsubscribe path, so
-- TICK and XP_EVENT keep reaching every UI Update function after OnDisable has
-- run. Without this check the frame is hidden by OnDisable and shown again a
-- second later by the next tick -- which is exactly what "it flashed and the
-- boxes were still there" looks like.
function LP:ModuleOff(id)
  return not LP:ModuleEnabled(id)
end

function LP:StartModules()
  local order = LP:ModuleOrder()
  for i = 1, #order do
    if LP:ModuleEnabled(order[i]) then LP:SetModuleEnabled(order[i], true) end
  end
end

-- ---------------------------------------------------------------------------
-- Scheduler
--
-- 3.3.5a has no C_Timer, and frames are never garbage collected, so every
-- repeating job shares ONE driver frame rather than each allocating its own.
-- ---------------------------------------------------------------------------

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

-- Exposed so tests can pump the scheduler without a real frame.
function LP:_Tick(elapsed)
  for i = 1, #scheduled do
    local job = scheduled[i]
    job.elapsed = job.elapsed + elapsed
    if job.elapsed >= job.interval then
      job.elapsed = 0
      pcall(job.fn)
    end
  end
end

function LP:StartDriver()
  if driver or not CreateFrame then return end
  driver = CreateFrame("Frame", "LevelPaceDriver")
  LP.driverStarted = true
  driver:SetScript("OnUpdate", function(_, elapsed) LP:_Tick(elapsed) end)
end

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------

LP.defaults = {
  profile = {
    locked = false,
    bar = {
      shown = true, width = 260, height = 14,
      point = "CENTER", relPoint = "CENTER", x = 0, y = -160,
      texture = "Interface\\TargetingFrame\\UI-StatusBar",
      colors = {
        fill    = { r = 0.25, g = 0.55, b = 0.90, a = 1.00 },
        rested  = { r = 0.35, g = 0.30, b = 0.70, a = 0.55 },
        bg      = { r = 0.05, g = 0.05, b = 0.07, a = 0.80 },
        border  = { r = 0.00, g = 0.00, b = 0.00, a = 0.90 },
      },
    },
    box = {
      shown = true, layout = "stacked", scale = 1.0, spacing = 2,
      point = "CENTER", relPoint = "CENTER", x = 0, y = -190,
      font = "Fonts\\FRIZQT__.TTF", fontSize = 11, outline = "OUTLINE",
      colors = {
        bg      = { r = 0.05, g = 0.05, b = 0.07, a = 0.60 },
        border  = { r = 0.00, g = 0.00, b = 0.00, a = 0.90 },
        label   = { r = 0.65, g = 0.65, b = 0.70, a = 1.00 },
        value   = { r = 1.00, g = 1.00, b = 1.00, a = 1.00 },
        good    = { r = 0.40, g = 0.90, b = 0.40, a = 1.00 },
        neutral = { r = 0.95, g = 0.85, b = 0.35, a = 1.00 },
        bad     = { r = 0.95, g = 0.45, b = 0.40, a = 1.00 },
      },
      lines = {
        level = true, xpPerHour = true, timeToLevel = true,
        mobsToLevel = true, rested = true, topQuest = true, parse = true,
      },
    },
    gauge = {
      shown = false, width = 160, height = 16,
      point = "CENTER", relPoint = "CENTER", x = 0, y = -215,
    },
    -- Sharing is OFF by default and stays off until explicitly enabled.
    share = {
      enabled = false,
      alias = "",
      shareRealm = true,
      shareClass = true,
      shareFaction = true,
      -- Separate opt-in: the PvP payload contains OTHER players' character
      -- names (your nemeses), who never agreed to anything. That deserves its
      -- own decision rather than riding along with your own levelling stats.
      sharePvP = false,
    },
    gapWarnSeconds = 600,
    countRestedInProjection = true,
    -- Per-module enable state, keyed by module id. Absent means "use the
    -- module's own default", which is how a module added in a later version
    -- turns itself on for people who already have a saved profile.
    modules = {},
  },
}

function LP:InitDB()
  local util = LP.util
  _G.LevelPaceDB = util.CopyDefaults(_G.LevelPaceDB or {}, { rates = {} })
  _G.LevelPaceCharDB = util.CopyDefaults(_G.LevelPaceCharDB or {}, {
    profile = LP.defaults.profile,
    history = {},
    current = false,
  })
  LP.db = _G.LevelPaceCharDB
  LP.gdb = _G.LevelPaceDB
  return LP.db
end

-- ---------------------------------------------------------------------------
-- Bootstrap
--
-- Ordering matters (spec 3.8): file-scope code runs BEFORE SavedVariables
-- exist, so the DB is read at ADDON_LOADED and unit data only at PLAYER_LOGIN.
-- ---------------------------------------------------------------------------

function LP:Bootstrap()
  if not CreateFrame then return end
  local f = CreateFrame("Frame", "LevelPaceBootstrap")
  LP.bootstrapFrame = f
  LP.util.SafeRegisterEvent(f, "ADDON_LOADED")
  LP.util.SafeRegisterEvent(f, "PLAYER_LOGIN")
  f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
      if arg1 ~= LP.ADDON_NAME then return end
      LP:InitDB()
      LP:Fire("DB_READY")
    elseif event == "PLAYER_LOGIN" then
      if not LP.db then LP:InitDB() end
      LP:StartDriver()
      -- PLAYER_READY first: every existing file hooks it at file scope, so
      -- firing it before StartModules keeps their wiring identical and this
      -- refactor stays behaviour-neutral.
      LP:Fire("PLAYER_READY")
      LP:StartModules()
      LP:Print("loaded. /lp for options, /lp board for rankings.")
      LP:CheckVersion()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Version check
--
-- The addon cannot reach the network, so it cannot ask GitHub anything. The
-- uploader already fetches the board; it carries the current version along
-- with it, and this compares. Costs one string comparison at login.
--
-- Deliberately a single chat line, once per session, with no popup and no
-- nagging. An addon that interrupts you about its own version is worse than
-- one that is slightly out of date.
-- ---------------------------------------------------------------------------

-- Returns true when `a` is a strictly newer dotted version than `b`.
-- Compares numerically per segment, so 0.10.0 beats 0.9.0 -- string
-- comparison would get that backwards.
function LP:IsNewer(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  local ai, bi = {}, {}
  for n in string.gmatch(a, "%d+") do ai[#ai + 1] = tonumber(n) end
  for n in string.gmatch(b, "%d+") do bi[#bi + 1] = tonumber(n) end
  for i = 1, math.max(#ai, #bi) do
    local x, y = ai[i] or 0, bi[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

function LP:CheckVersion()
  local board = _G.LevelPaceBoard
  local latest = type(board) == "table" and board.addonVersion or nil
  if not latest then return end
  if not self:IsNewer(latest, self.VERSION) then return end
  self:Print(string.format(
    "|cffe0a040version %s is available|r (you have %s) -- %s",
    latest, self.VERSION, board.downloadUrl or "check where you got it"))
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local function dispatch(input)
  local cmd, rest = string.match(strtrim(input or ""), "^(%S*)%s*(.*)$")
  cmd = string.lower(cmd or "")

  if cmd == "" then
    if InterfaceOptionsFrame_OpenToCategory and LP.optionsPanel then
      InterfaceOptionsFrame_OpenToCategory(LP.optionsPanel)
    else
      LP:Print("options unavailable; try /lp quests")
    end
  elseif cmd == "reset" then
    if not LP.db then LP:Print("not ready yet."); return end
    if LP.History then LP.History:Reset() end
    LP:Print("tracking reset for this level.")
  elseif cmd == "quests" then
    if LP.Quests then LP.Quests:PrintRanking() else LP:Print("quest module not loaded") end
  elseif cmd == "lock" or cmd == "unlock" then
    if not LP.db then LP:Print("not ready yet."); return end
    LP.db.profile.locked = (cmd == "lock")
    LP:Fire("LOCK_CHANGED", LP.db.profile.locked)
    LP:Print(cmd == "lock" and "frames locked." or "frames unlocked -- drag to move.")
  elseif cmd == "board" or cmd == "rank" or cmd == "ranks" then
    if LP.Board then LP.Board:Toggle() else LP:Print("board module not loaded") end
  elseif cmd == "share" then
    if not LP.Export then LP:Print("export module not loaded") return end
    local arg = string.lower(strtrim(rest or ""))
    -- Turning sharing on used to mean finding a checkbox three clicks into an
    -- options panel. It is the single thing standing between a player and the
    -- board, so it gets a command.
    if arg == "on" or arg == "off" then
      LP.db.profile.share.enabled = (arg == "on")
      LP:Fire("SHARE_CHANGED")
      LP:Print("sharing " .. arg ..
        (arg == "on" and " -- log out or /reload, then the companion sends it." or ""))
      return
    elseif arg == "pvp on" or arg == "pvp off" then
      LP.db.profile.share.sharePvP = (arg == "pvp on")
      LP:Fire("SHARE_CHANGED")
      LP:Print("PvP sharing " .. (LP.db.profile.share.sharePvP and "on" or "off"))
      return
    end
    LP:Print(LP.Export:Summary())
    if LP.Export:Enabled() then
      LP:Print("data is written on logout or /reload; the companion sends it from there.")
    else
      LP:Print("sharing is OFF. Turn it on with:  /lp share on")
    end
  elseif cmd == "debug" then
    LP.debug = not LP.debug
    LP:Print("debug " .. (LP.debug and "on" or "off"))
    if LP.Ledger then LP.Ledger:DumpRecent() end
  elseif cmd == "show" then
    LP:Fire("TOGGLE_SHOWN", true)
  elseif cmd == "hide" then
    LP:Fire("TOGGLE_SHOWN", false)
  elseif cmd == "minimap" or cmd == "mm" then
    if LP.Minimap then
      LP.Minimap:Toggle()
      LP:Print("minimap button " .. (LP.Minimap:IsShown() and "shown" or "hidden"))
    else LP:Print("minimap button not loaded") end
  elseif cmd == "meter" then
    if LP.Meter then
      LP.Meter:Toggle()
      LP:Print("meter " .. (LP.Meter:IsShown() and "on" or "off") ..
               " -- click its header to change view, drag the corner to resize.")
    else LP:Print("meter not loaded") end
  elseif cmd == "dash" or cmd == "stats" then
    if LP.Dash then LP.Dash:Toggle() else LP:Print("dashboard not loaded") end
  elseif cmd == "rares" or cmd == "rare" then
    if LP.RareFinder then LP.RareFinder:PrintSummary()
    else LP:Print("rare finder not loaded") end
  elseif cmd == "nemesis" or cmd == "nem" or cmd == "pvp" then
    if LP.Nemesis then LP.Nemesis:PrintSummary()
    else LP:Print("nemesis not loaded") end
  elseif cmd == "modules" then
    local order = LP:ModuleOrder()
    LP:Print("modules (/lp toggle <id> to switch one off):")
    for i = 1, #order do
      local m = LP:GetModule(order[i])
      LP:Print(string.format("  %s -- %s%s|r%s",
        m.id,
        LP:ModuleEnabled(m.id) and "|cff44dd44" or "|cffdd4444",
        LP:ModuleEnabled(m.id) and "on" or "off",
        m.desc and ("  " .. m.desc) or ""))
    end
  elseif cmd == "toggle" then
    local id = string.lower(strtrim(rest or ""))
    if not LP:GetModule(id) then
      LP:Print("no such module: '" .. id .. "'. Try /lp modules")
    else
      local now = not LP:ModuleEnabled(id)
      LP:SetModuleEnabled(id, now)
      LP:Print(id .. " is now " .. (now and "on" or "off"))
    end
  else
    LP:Print("commands: minimap, meter, dash, board, rares, nemesis,")
    LP:Print("          modules, toggle <id>, reset, quests, share, lock, debug")
  end
  LP.lastCommand = cmd
end

LP.Dispatch = dispatch

if _G.SlashCmdList then
  _G.SLASH_LEVELPACE1 = "/lp"
  _G.SLASH_LEVELPACE2 = "/levelpace"
  _G.SlashCmdList["LEVELPACE"] = dispatch
end

return LP
