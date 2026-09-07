package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  local LP = h.loadCore()
  for _, f in ipairs({ "Ledger", "Modifiers", "Rates", "History", "Estimator", "Quests", "Parse" }) do
    h.load("LevelPace/" .. f .. ".lua")
  end
  LP:InitDB(); LP.Rates:Load(); LP.History:Init()
  return LP
end

-- Complete `n` levels each taking `secs`, so the baseline has real values.
local function completeLevels(LP, list)
  for i, secs in ipairs(list) do
    h.state.level = 70 + i
    LP.History:Reset()
    h.advance(1)
    LP.Ledger:OnChat("Ghoul dies, you gain 1000 experience.")
    h.advance(secs - 1)
    LP.History:OnLevelUp(71 + i)
  end
end

h.run("bands map to the WarcraftLogs scheme", function()
  local P = load().Parse
  h.eq(P:Band(100).key, "artifact", "100 is the gold parse")
  h.eq(P:Band(99).key, "pink", "99 is pink")
  h.eq(P:Band(96).key, "legendary", "95-98 legendary")
  h.eq(P:Band(95).key, "legendary", "95 boundary")
  h.eq(P:Band(94).key, "epic", "75-94 epic")
  h.eq(P:Band(75).key, "epic", "75 boundary")
  h.eq(P:Band(74).key, "rare", "50-74 rare")
  h.eq(P:Band(50).key, "rare", "50 boundary")
  h.eq(P:Band(49).key, "uncommon", "25-49 uncommon")
  h.eq(P:Band(25).key, "uncommon", "25 boundary")
  h.eq(P:Band(24).key, "common", "0-24 common")
  h.eq(P:Band(0).key, "common", "0")
  h.eq(P:Band(nil), nil, "nil is not a band")
end)

h.run("band colours are the canonical hex values", function()
  local P = load().Parse
  local function hex(b)
    return string.format("%02x%02x%02x",
      math.floor(b.r * 255 + 0.5), math.floor(b.g * 255 + 0.5), math.floor(b.b * 255 + 0.5))
  end
  h.eq(hex(P:Band(100)), "e5cc80", "artifact gold")
  h.eq(hex(P:Band(99)),  "e268a8", "pink")
  h.eq(hex(P:Band(96)),  "ff8000", "legendary orange")
  h.eq(hex(P:Band(80)),  "a335ee", "epic purple")
  h.eq(hex(P:Band(60)),  "0070ff", "rare blue")
  h.eq(hex(P:Band(30)),  "1eff00", "uncommon green")
end)

h.run("Colorize wraps text in the band colour", function()
  local P = load().Parse
  h.eq(P:Colorize(100, "100"), "|cffe5cc80100|r", "gold escape sequence")
  h.eq(P:Colorize(10, "10"), "|cff66666610|r", "common grey")
end)

h.run("PercentileOf measures what you beat", function()
  local P = load().Parse
  local base = { 1, 2, 3, 4 }
  h.eq(P:PercentileOf(5, base), 100, "beats everything")
  h.eq(P:PercentileOf(0, base), 0, "beats nothing")
  h.eq(P:PercentileOf(2.5, base), 50, "beats half")
  h.eq(P:PercentileOf(5, {}), nil, "no baseline means no percentile")
  h.eq(P:PercentileOf(nil, base), nil, "nil value")
end)

-- Honesty: a percentile drawn from one or two samples is noise.
h.run("no score until the baseline is deep enough", function()
  local LP = load()
  h.state.level, h.state.xpMax = 75, 100000
  completeLevels(LP, { 3600, 3600 })          -- only two completed levels
  h.state.level = 75
  LP.History:Reset()
  h.advance(1)
  LP.Ledger:OnChat("Ghoul dies, you gain 5000 experience.")
  LP.Estimator:Refresh()
  local pct, band, lph, label, n = LP.Parse:Current()
  h.eq(pct, nil, "no percentile")
  h.eq(band, nil, "no band")
  h.ok(lph and lph > 0, "but the pace itself is known")
  h.eq(n, 2, "reports how many samples it has")
end)

h.run("a fast pace scores high against your own history", function()
  local LP = load()
  h.state.xpMax = 100000
  completeLevels(LP, { 7200, 7200, 7200 })    -- three slow levels: 0.5 lvl/hr
  h.state.level = 75
  LP.History:Reset()
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 10000 experience.")  -- 1000 xp/s
  LP.Estimator:Refresh()
  local pct, band = LP.Parse:Current()
  h.ok(pct, "scored")
  h.eq(pct, 100, "beats all three of your slow levels")
  h.eq(band.key, "artifact", "gold parse")
end)

h.run("a slow pace scores low", function()
  local LP = load()
  h.state.xpMax = 100000
  completeLevels(LP, { 600, 600, 600 })       -- three fast levels: 6 lvl/hr
  h.state.level = 75
  LP.History:Reset()
  h.advance(3600)
  LP.Ledger:OnChat("Ghoul dies, you gain 100 experience.")
  LP.Estimator:Refresh()
  local pct, band = LP.Parse:Current()
  h.eq(pct, 0, "beats none of them")
  h.eq(band.key, "common", "grey parse")
end)

-- The metric must be levels/hr, not xp/hr, or a high level always wins.
h.run("the metric is levels per hour, so it is level-independent", function()
  local LP = load()
  h.state.xpMax = 1000
  LP.Estimator:Update({ xp = 0, xpMax = 1000, baseRateSamples = { 1 }, observedFraction = 1 })
  local low = LP.Parse:CurrentLevelsPerHour()
  h.state.xpMax = 100000
  LP.Estimator:Update({ xp = 0, xpMax = 100000, baseRateSamples = { 100 }, observedFraction = 1 })
  local high = LP.Parse:CurrentLevelsPerHour()
  -- 100x the XP rate but 100x the level cost: identical pace.
  h.near(low, high, 0.001, "same levels/hr despite 100x the XP/hr")
end)

h.run("an external baseline overrides the personal one", function()
  local LP = load()
  h.state.xpMax = 100000
  completeLevels(LP, { 7200, 7200, 7200 })
  h.state.level = 75
  LP.History:Reset()
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 10000 experience.")
  LP.Estimator:Refresh()
  h.eq(select(1, LP.Parse:Current()), 100, "top of your own history")
  -- A global distribution where everyone is much faster.
  LP.Parse:SetBaseline({ 100, 200, 300, 400 }, "global")
  local pct, band, _, label = LP.Parse:Current()
  h.eq(pct, 0, "middling against the world")
  h.eq(label, "global", "labelled so the UI can say what it compared against")
  LP.Parse:SetBaseline(nil)
  h.eq(select(1, LP.Parse:Current()), 100, "cleared, back to personal")
end)

h.run("no score at max level", function()
  local LP = load()
  h.state.level, h.state.xp, h.state.xpMax = 80, 0, 0
  LP.Estimator:Refresh()
  h.eq(LP.Parse:CurrentLevelsPerHour(), nil, "no pace at max level")
  h.eq(select(1, LP.Parse:Current()), nil, "no parse")
end)

os.exit(h.report() and 0 or 1)
