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
  h.eq(n, 0, "reports how many OTHER players it has, which is none")
end)

-- Your own history is a comparison, never a parse. Reported from the game:
-- a level 6 with nobody else on the board was shown a grey "Common" for
-- pacing slower than its own one-minute levels 1-4.
h.run("your own history never produces a parse, however fast you are", function()
  local LP = load()
  _G.LevelPaceBaseline = nil
  h.state.xpMax = 100000
  completeLevels(LP, { 7200, 7200, 7200 })    -- three slow levels: 0.5 lvl/hr
  h.state.level = 75
  LP.History:Reset()
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 10000 experience.")  -- 1000 xp/s
  LP.Estimator:Refresh()
  local pct, band, lph, label, n = LP.Parse:Current()
  h.eq(pct, nil, "no percentile without other players")
  h.eq(band, nil, "no colour")
  h.ok(lph and lph > 0, "the pace itself is still known")
  h.ok(label:find("nobody else at level 75", 1, true), "says why: " .. tostring(label))
  h.eq(n, 0, "zero others")
end)

h.run("a slow pace against your own history is not grey either", function()
  local LP = load()
  _G.LevelPaceBaseline = nil
  h.state.xpMax = 100000
  completeLevels(LP, { 600, 600, 600 })       -- three fast levels: 6 lvl/hr
  h.state.level = 75
  LP.History:Reset()
  h.advance(3600)
  LP.Ledger:OnChat("Ghoul dies, you gain 100 experience.")
  LP.Estimator:Refresh()
  local pct, band = LP.Parse:Current()
  h.eq(pct, nil, "not scored")
  h.eq(band, nil, "not grey")
end)

h.run("other players at your level on the board make a real parse", function()
  local LP = load()
  h.state.xpMax = 100000
  h.state.level = 75
  LP.History:Reset()
  -- Three other players at level 75: 0.5, 1 and 2 levels per hour.
  _G.LevelPaceBaseline = { players = 3, overall = { 0.5, 1, 2 }, byLevel = { [75] = { 0.5, 1, 2 } } }
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 10000 experience.")  -- 1000 xp/s = 36 lvl/hr
  LP.Estimator:Refresh()
  local pct, band, lph, label, n = LP.Parse:Current()
  h.eq(pct, 100, "faster than all three")
  h.eq(band.key, "artifact", "gold")
  h.ok(label:find("global, level 75", 1, true), "labelled as the global level-75 comparison")
  h.eq(n, 3, "three samples")
  _G.LevelPaceBaseline = nil
end)

h.run("two players at your level is not enough for a parse", function()
  local LP = load()
  h.state.xpMax = 100000
  h.state.level = 75
  LP.History:Reset()
  _G.LevelPaceBaseline = { players = 2, overall = { 1, 2 }, byLevel = { [75] = { 1, 2 } } }
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 10000 experience.")
  LP.Estimator:Refresh()
  local pct, band, lph, label, n = LP.Parse:Current()
  h.eq(pct, nil, "below the minimum")
  h.ok(label:find("(2 of 3 needed)", 1, true), "counts the others: " .. tostring(label))
  _G.LevelPaceBaseline = nil
end)

-- ==== per-level parses for the dashboard ====

h.run("each finished level is ranked against everyone else's time at that level", function()
  local LP = load()
  h.state.xpMax = 100000
  completeLevels(LP, { 3600, 1800 })          -- level 71 in 1h (1 lvl/hr), level 72 in 30m (2 lvl/hr)
  -- On the board: level 71 has three others at 0.5, 1.5 and 4; my own 1.0 is
  -- not there yet. Level 72 has nobody.
  _G.LevelPaceBaseline = { players = 3, overall = {}, byLevel = { [71] = { 0.5, 1.5, 4 } } }
  local p = LP.Parse:LevelParses()
  h.eq(#p, 2, "two finished levels")
  h.eq(p[1].level, 72, "newest first")
  h.eq(p[1].pct, nil, "nobody else at 72")
  h.eq(p[1].of, 1, "just me")
  h.eq(p[2].level, 71, "then 71")
  h.near(p[2].lph, 1, 0.001, "one level per hour")
  h.near(p[2].pct, 33.33, 0.1, "beat 1 of 3 others (n-1 divisor, self added)")
  h.eq(p[2].band.key, "uncommon", "green")
  h.eq(p[2].of, 4, "three others plus me")

  -- Once my own row is on the board it is not counted twice.
  _G.LevelPaceBaseline.byLevel[71] = { 0.5, 1.0, 1.5, 4 }
  p = LP.Parse:LevelParses()
  h.eq(p[2].of, 4, "still four")
  h.near(p[2].pct, 33.33, 0.1, "same answer")
  _G.LevelPaceBaseline = nil
end)

-- Found by review: GetTime() is fractional in game, the export FLOORS elapsed,
-- and the board serves 3600/floor(elapsed) to 4 decimals. Ranking the raw
-- float against that never matched our own row, so it was counted twice.
h.run("a fractional elapsed still recognises its own row on the board", function()
  local LP = load()
  h.state.xpMax = 100000
  h.state.level = 71
  LP.History:Reset()
  h.advance(1)
  LP.Ledger:OnChat("Ghoul dies, you gain 1000 experience.")
  h.advance(399.6)                              -- 400.6 s in total
  LP.History:OnLevelUp(72)
  -- The board's copy of that level: 3600/floor(400.6) = 9.0000, written 4 dp.
  _G.LevelPaceBaseline = { players = 4, overall = {}, byLevel = { [71] = { 0.5, 1.5, 4, 9.0000 } } }
  local p = LP.Parse:LevelParses()
  h.eq(p[1].of, 4, "own row recognised, not appended a second time")
  h.eq(p[1].pct, 100, "beats all three others")
  h.eq(p[1].band.key, "artifact", "gold")
  _G.LevelPaceBaseline = nil
end)

h.run("one other player at a level is not enough for a per-level parse", function()
  local LP = load()
  h.state.xpMax = 100000
  completeLevels(LP, { 3600 })
  _G.LevelPaceBaseline = { players = 1, overall = {}, byLevel = { [71] = { 0.5 } } }
  local p = LP.Parse:LevelParses()
  h.eq(p[1].of, 2, "one other plus me")
  h.eq(p[1].pct, nil, "below MIN_BASELINE: no percentile")
  h.eq(p[1].band, nil, "and no colour")
  _G.LevelPaceBaseline = nil
end)

h.run("the LevelPace dashboard lists the ranked levels", function()
  local LP = load()
  h.load("LevelPace/Modules/LevelPace.lua")
  h.state.xpMax = 100000
  completeLevels(LP, { 3600 })
  _G.LevelPaceBaseline = { players = 3, overall = {}, byLevel = { [71] = { 0.5, 1.5, 4 } } }
  local rows = LP:GetModule("levelpace").Dashboard()
  local list = nil
  for _, r in ipairs(rows) do if r.kind == "list" and r.title == "Your levels, ranked" then list = r end end
  h.ok(list, "the list is there")
  h.ok(list.items[1].text:find("Level 71", 1, true), "names the level: " .. list.items[1].text)
  h.ok(list.items[1].text:find("1h 0m", 1, true), "and its time")
  h.ok(list.items[1].sub:find("33%  Uncommon  (of 4 at this level)", 1, true), "percentile, band, population: " .. list.items[1].sub)
  h.eq(list.items[1].colour.key, "uncommon", "coloured by band")
  _G.LevelPaceBaseline = nil
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
  h.eq(select(1, LP.Parse:Current()), nil, "own history alone is not a parse")
  -- A global distribution where everyone is much faster.
  LP.Parse:SetBaseline({ 100, 200, 300, 400 }, "global")
  local pct, band, _, label = LP.Parse:Current()
  h.eq(pct, 0, "middling against the world")
  h.eq(label, "global", "labelled so the UI can say what it compared against")
  LP.Parse:SetBaseline(nil)
  h.eq(select(1, LP.Parse:Current()), nil, "cleared: no other players, no parse")
end)

h.run("no score at max level", function()
  local LP = load()
  h.state.level, h.state.xp, h.state.xpMax = 80, 0, 0
  LP.Estimator:Refresh()
  h.eq(LP.Parse:CurrentLevelsPerHour(), nil, "no pace at max level")
  h.eq(select(1, LP.Parse:Current()), nil, "no parse")
end)

os.exit(h.report() and 0 or 1)
