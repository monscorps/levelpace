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
