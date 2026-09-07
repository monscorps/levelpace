package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  local LP = h.loadCore()
  h.load("LevelPace/Ledger.lua")
  h.load("LevelPace/Modifiers.lua")
  h.load("LevelPace/Rates.lua")
  h.load("LevelPace/Estimator.lua")
  return LP
end

local function est(LP, over)
  local s = {
    xp = 0, xpMax = 100000, restedPool = 0,
    baseRateSamples = { 1 }, killXPSamples = {},
    observedFraction = 1, largestGap = 0,
  }
  for k, v in pairs(over or {}) do s[k] = v end
  return LP.Estimator:Update(s)
end

-- ==== rested projection ====
-- A pool of P supplies 2P xp in exchange for P xp of BASE killing.

h.run("unrested projection is simple division", function()
  local r = est(load(), { restedPool = 0 })
  h.near(r.timeToLevel, 100000, 1, "100k xp at 1 xp/s")
end)

h.run("rested pool exactly covering the level", function()
  local r = est(load(), { restedPool = 50000 })
  h.near(r.timeToLevel, 50000, 1, "50k pool doubles 50k base into the full 100k")
end)

h.run("rested pool larger than the level needs", function()
  local r = est(load(), { restedPool = 60000 })
  h.near(r.timeToLevel, 50000, 1, "surplus pool is wasted, not counted -- NOT 10000")
end)

h.run("partial rested pool", function()
  local r = est(load(), { restedPool = 10000 })
  -- 20000 xp covered by 10000 base killing, then 80000 at normal rate.
  h.near(r.timeToLevel, 90000, 1, "10000 + 80000")
end)

h.run("rested can be excluded from the projection", function()
  local r = est(load(), { restedPool = 50000, countRested = false })
  h.near(r.timeToLevel, 100000, 1, "ignoring rested gives the unrested figure")
end)

h.run("already at max xp", function()
  local r = est(load(), { xp = 100000, xpMax = 100000 })
  h.eq(r.xpRemaining, 0, "nothing remaining")
  h.near(r.timeToLevel, 0, 0.001, "no time needed")
end)

-- ==== rate handling ====

h.run("no rate samples yields nil, not infinity", function()
  local r = est(load(), { baseRateSamples = {}, historyRate = nil })
  h.eq(r.timeToLevel, nil, "unknown is nil")
  h.eq(r.baseRate, nil, "no rate")
  h.eq(r.confidence, "none", "confidence reflects it")
end)

h.run("falls back to history when the level has no samples", function()
  local r = est(load(), { baseRateSamples = {}, historyRate = 2, observedFraction = 0 })
  h.near(r.baseRate, 2, 0.001, "uses past levels")
  h.eq(r.rateSource, "past levels", "labelled")
  h.near(r.timeToLevel, 50000, 1, "100k at 2 xp/s")
end)

h.run("blends live and history by observed fraction", function()
  local r = est(load(), { baseRateSamples = { 4 }, historyRate = 2, observedFraction = 0.5 })
  h.near(r.baseRate, 3, 0.001, "halfway between 4 and 2")
  h.eq(r.rateSource, "blended", "labelled")
end)

h.run("late in a level the live rate dominates", function()
  local r = est(load(), { baseRateSamples = { 4 }, historyRate = 2, observedFraction = 1 })
  h.near(r.baseRate, 4, 0.001, "fully live")
end)

h.run("xp per hour is derived from the per-second rate", function()
  local r = est(load(), { baseRateSamples = { 10 } })
  h.near(r.baseRatePerHour, 36000, 0.001, "10/s is 36000/hr")
end)

-- ==== mobs to level ====

h.run("mobs-to-level needs 10 kills", function()
  local LP = load()
  local r = est(LP, { xpMax = 10000, killXPSamples = { 100, 200 } })
  h.eq(r.mobsLow, nil, "under 10 kills -> no estimate")
  h.eq(r.mobsHigh, nil, "no estimate")
  h.eq(r.killSampleCount, 2, "count still reported")
end)

h.run("uniform kills give a point range", function()
  local s = {}
  for i = 1, 12 do s[i] = 100 end
  local r = est(load(), { xpMax = 10000, killXPSamples = s })
  h.eq(r.mobsLow, 100, "10000 / 100")
  h.eq(r.mobsHigh, 100, "uniform -> low == high")
end)

h.run("mixed kills give a true range, low count from high xp", function()
  local s = {}
  for i = 1, 10 do s[i] = 100 end
  for i = 11, 20 do s[i] = 300 end
  local r = est(load(), { xpMax = 12000, killXPSamples = s })
  h.ok(r.mobsLow < r.mobsHigh, "a real range")
  h.ok(r.xpPerKillLow < r.xpPerKillHigh, "p25 below p75")
  -- high xp per kill -> fewer mobs
  h.eq(r.mobsLow, math.ceil(12000 / r.xpPerKillHigh), "low count uses the high xp")
  h.eq(r.mobsHigh, math.ceil(12000 / r.xpPerKillLow), "high count uses the low xp")
end)

h.run("rested reduces the mobs needed", function()
  local s = {}
  for i = 1, 12 do s[i] = 100 end
  local plain = est(load(), { xpMax = 10000, killXPSamples = s, restedPool = 0 })
  local rest  = est(load(), { xpMax = 10000, killXPSamples = s, restedPool = 5000 })
  h.ok(rest.mobsLow < plain.mobsLow, "rested needs fewer kills")
  h.eq(rest.mobsLow, 50, "5000 base killing at 100/kill")
end)

-- ==== honesty annotations ====

h.run("gap warning is reported, never applied", function()
  local r = est(load(), { largestGap = 8040, gapThreshold = 600 })
  h.eq(r.gapWarning, 8040, "surfaced")
  h.near(r.timeToLevel, 100000, 1, "the number itself is NOT corrected")
end)

h.run("gap below the threshold is not flagged", function()
  local r = est(load(), { largestGap = 120, gapThreshold = 600 })
  h.eq(r.gapWarning, nil, "quiet")
end)

h.run("gap warning can be disabled with a zero threshold", function()
  local r = est(load(), { largestGap = 99999, gapThreshold = 0 })
  h.eq(r.gapWarning, nil, "disabled")
end)

h.run("confidence reflects the evidence", function()
  local s = {}
  for i = 1, 12 do s[i] = 100 end
  h.eq(est(load(), { baseRateSamples = {} }).confidence, "none", "no rate")
  h.eq(est(load(), { observedFraction = 0.01, killXPSamples = {} }).confidence, "low", "thin")
  h.eq(est(load(), { observedFraction = 0.5, killXPSamples = s }).confidence, "good", "solid")
end)

h.run("percent complete", function()
  local r = est(load(), { xp = 25000, xpMax = 100000 })
  h.near(r.percent, 25, 0.001, "25%")
end)

h.run("GrindXPPerMinute", function()
  local LP = load()
  est(LP, { baseRateSamples = { 10 } })
  h.near(LP.Estimator:GrindXPPerMinute(), 600, 0.001, "10/s is 600/min")
end)

os.exit(h.report() and 0 or 1)
