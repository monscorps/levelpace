-- LevelPace :: Core
-- Addon table, internal event bus, throttled scheduler, saved-variables
-- bootstrap and slash commands.

local ADDON_NAME = ...

local LP = {}
_G.LevelPace = LP

LP.ADDON_NAME = "LevelPace"
LP.VERSION = "0.1.0"
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
    },
    gapWarnSeconds = 600,
    countRestedInProjection = true,
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
      LP:Fire("PLAYER_READY")
      LP:Print("loaded. /lp for options.")
    end
  end)
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
  elseif cmd == "share" then
    if not LP.Export then LP:Print("export module not loaded") return end
    LP:Print(LP.Export:Summary())
    if LP.Export:Enabled() then
      LP:Print("data is written on logout or /reload; the uploader sends it from there.")
    else
      LP:Print("sharing is off. /lp then Leaderboard to turn it on.")
    end
  elseif cmd == "debug" then
    LP.debug = not LP.debug
    LP:Print("debug " .. (LP.debug and "on" or "off"))
    if LP.Ledger then LP.Ledger:DumpRecent() end
  elseif cmd == "show" then
    LP:Fire("TOGGLE_SHOWN", true)
  elseif cmd == "hide" then
    LP:Fire("TOGGLE_SHOWN", false)
  else
    LP:Print("commands: reset, quests, share, lock, unlock, show, hide, debug")
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
