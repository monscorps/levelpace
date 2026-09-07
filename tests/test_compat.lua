package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  return _G.LevelPace
end

h.run("core loads and exposes the bus", function()
  local LP = load()
  h.ok(LP, "LevelPace global exists")
  h.eq(type(LP.On), "function", "LP:On exists")
  h.eq(type(LP.Fire), "function", "LP:Fire exists")
end)

h.run("event bus delivers to all handlers in order", function()
  local LP = load()
  local seen = {}
  LP:On("TEST", function(a, b) seen[#seen + 1] = a + b end)
  LP:On("TEST", function(a, b) seen[#seen + 1] = a * b end)
  LP:Fire("TEST", 3, 4)
  h.eq(#seen, 2, "both handlers ran")
  h.eq(seen[1], 7, "first got args")
  h.eq(seen[2], 12, "second got args")
end)

h.run("a throwing handler does not stop later handlers", function()
  local LP = load()
  local reached = false
  LP:On("BOOM", function() error("intentional") end)
  LP:On("BOOM", function() reached = true end)
  LP:Fire("BOOM")
  h.ok(reached, "later handler still ran")
end)

h.run("scheduler fires on interval", function()
  local LP = load()
  local n = 0
  LP:Schedule(1, function() n = n + 1 end)
  LP:_Tick(0.5); h.eq(n, 0, "not yet")
  LP:_Tick(0.6); h.eq(n, 1, "fired at 1.1s")
  LP:_Tick(1.0); h.eq(n, 2, "fired again")
end)

-- ==== ConvertGlobalString ====

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

-- THE regression test. Escaping only ( and ) makes the literal + and - in a
-- _GROUP message act as Lua quantifiers, and the match silently fails.
h.run("escapes + and - so _GROUP variants match", function()
  local LP = load()
  local p = LP.util.ConvertGlobalString(
    "%s dies, you gain %d experience. (%s exp %s bonus, +%d group bonus)")
  local name, xp, bonus, btype, grp = string.match(
    "Ghoul dies, you gain 412 experience. (+86 exp Rested bonus, +12 group bonus)", p)
  h.eq(name, "Ghoul", "name")
  h.eq(xp, "412", "xp")
  h.eq(bonus, "+86", "bonus AMOUNT is the first %s")
  h.eq(btype, "Rested", "bonus TYPE is the second %s")
  h.eq(grp, "12", "group bonus")
end)

h.run("escapes magic characters in literal text", function()
  local LP = load()
  local p = LP.util.ConvertGlobalString("Discovered %s: %d experience gained")
  local zone, xp = string.match("Discovered Howling Fjord: 975 experience gained", p)
  h.eq(zone, "Howling Fjord", "zone")
  h.eq(xp, "975", "xp")
end)

h.run("anchoring stops a partial match", function()
  local LP = load()
  local p = LP.util.ConvertGlobalString("You gain %d experience.")
  h.eq(string.match("Blah. You gain 412 experience. Blah.", p), nil, "anchored")
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

-- ==== formatting ====

h.run("FormatTime", function()
  local LP = load()
  h.eq(LP.util.FormatTime(45), "45s", "seconds")
  h.eq(LP.util.FormatTime(90), "1m 30s", "minutes")
  h.eq(LP.util.FormatTime(5040), "1h 24m", "hours")
  h.eq(LP.util.FormatTime(nil), "--", "nil is not a crash")
  h.eq(LP.util.FormatTime(math.huge), "--", "infinity is not a crash")
end)

h.run("FormatNumber groups thousands", function()
  local LP = load()
  h.eq(LP.util.FormatNumber(12600), "12,600", "thousands")
  h.eq(LP.util.FormatNumber(1670800), "1,670,800", "millions")
  h.eq(LP.util.FormatNumber(412), "412", "small")
  h.eq(LP.util.FormatNumber(0), "0", "zero")
end)

h.run("Median", function()
  local LP = load()
  h.eq(LP.util.Median({ 5, 1, 3 }), 3, "odd count")
  h.eq(LP.util.Median({ 4, 1, 3, 2 }), 2.5, "even count averages the middle pair")
  h.eq(LP.util.Median({}), nil, "empty is nil, not zero")
end)

h.run("Percentile", function()
  local LP = load()
  local s = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 }
  h.eq(LP.util.Percentile(s, 0), 10, "p0")
  h.eq(LP.util.Percentile(s, 1), 100, "p100")
  h.ok(LP.util.Percentile(s, 0.25) <= LP.util.Percentile(s, 0.75), "p25 <= p75")
end)

h.run("PushBounded keeps the window bounded", function()
  local LP = load()
  local list = {}
  for i = 1, 25 do LP.util.PushBounded(list, i, 20) end
  h.eq(#list, 20, "bounded to 20")
  h.eq(list[20], 25, "keeps the newest")
  h.eq(list[1], 6, "drops the oldest")
end)

h.run("ToNumber strips signs", function()
  local LP = load()
  h.eq(LP.util.ToNumber("+86"), 86, "plus")
  h.eq(LP.util.ToNumber("-50"), 50, "minus -- magnitude only")
  h.eq(LP.util.ToNumber("412"), 412, "plain")
  h.eq(LP.util.ToNumber("none"), nil, "no digits")
end)

h.run("CopyDefaults fills without clobbering", function()
  local LP = load()
  local dst = { a = 1, nested = { keep = "mine" } }
  LP.util.CopyDefaults(dst, { a = 99, b = 2, nested = { keep = "theirs", add = 3 } })
  h.eq(dst.a, 1, "existing value preserved")
  h.eq(dst.b, 2, "missing value filled")
  h.eq(dst.nested.keep, "mine", "nested existing preserved")
  h.eq(dst.nested.add, 3, "nested missing filled")
end)

os.exit(h.report() and 0 or 1)
