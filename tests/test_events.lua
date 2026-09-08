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

os.exit(h.report() and 0 or 1)
