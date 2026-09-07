package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load() return h.loadCore() end

h.run("xp table anchors match AzerothCore player_xp_for_level", function()
  local t = load().data.XP_FOR_LEVEL
  h.eq(t[1], 400, "level 1")
  h.eq(t[59], 172000, "level 59")
  h.eq(t[60], 290000, "level 60 -- the 68.6% cliff")
  h.eq(t[69], 717000, "level 69")
  h.eq(t[70], 1523800, "level 70 -- the 112.5% cliff")
  h.eq(t[79], 1670800, "level 79")
  h.eq(t[80], nil, "no level 80 entry -- 80 is the cap")
  h.eq(#t, 79, "exactly 79 entries")
end)

-- These three totals are the transcription check. If a single value in the
-- table is mistyped, at least one of them fails.
h.run("documented totals", function()
  local d = load().data
  local function total(to)
    local s = 0
    for i = 1, to do s = s + d.XP_FOR_LEVEL[i] end
    return s
  end
  h.eq(total(59), 3379400, "1 -> 60")
  h.eq(total(69), 8101400, "1 -> 70")
  h.eq(total(79), 24067200, "1 -> 80")
end)

h.run("GrayLevel matches TrinityCore", function()
  local g = load().data.GrayLevel
  h.eq(g(5), 0, "<=5 is 0")
  h.eq(g(30), 30 - 5 - 3, "<=39 band")
  h.eq(g(50), 50 - 1 - 10, "<=59 band")
  h.eq(g(70), 61, ">=60 band is pl-9")
  h.eq(g(80), 71, "level 80")
end)

h.run("ZeroDifference thresholds", function()
  local z = load().data.ZeroDifference
  h.eq(z(7), 5, "pl<8");  h.eq(z(9), 6, "pl<10");  h.eq(z(11), 7, "pl<12")
  h.eq(z(15), 8, "pl<16"); h.eq(z(19), 9, "pl<20"); h.eq(z(29), 11, "pl<30")
  h.eq(z(39), 12, "pl<40"); h.eq(z(44), 13, "pl<45"); h.eq(z(49), 14, "pl<50")
  h.eq(z(54), 15, "pl<55"); h.eq(z(59), 16, "pl<60"); h.eq(z(70), 17, "else")
end)

h.run("BaseGain uses PLAYER level, and the map's content constant", function()
  local d = load().data
  h.eq(d.BaseGain(10, 10, d.CONTENT.AZEROTH), 95, "5*10+45")
  h.eq(d.BaseGain(60, 60, d.CONTENT.AZEROTH), 345, "5*60+45, Azeroth")
  h.eq(d.BaseGain(70, 70, d.CONTENT.NORTHREND), 930, "5*70+580, Northrend")
  -- Same player and mob level, different zone tier -> very different XP.
  h.ok(d.BaseGain(60, 60, d.CONTENT.OUTLAND) > d.BaseGain(60, 60, d.CONTENT.AZEROTH),
       "Outland pays more than Azeroth for the same levels")
end)

h.run("higher mobs give +5%/level capped at +4", function()
  local d = load().data
  local base  = d.BaseGain(60, 60, d.CONTENT.AZEROTH)
  local plus4 = d.BaseGain(60, 64, d.CONTENT.AZEROTH)
  local plus7 = d.BaseGain(60, 67, d.CONTENT.AZEROTH)
  h.ok(plus4 > base, "+4 beats equal level")
  h.eq(plus7, plus4, "beyond +4 is capped")
end)

-- The gray cutoff is a cliff, not a fade.
h.run("gray cliff at level 70 in Northrend", function()
  local d = load().data
  h.eq(d.BaseGain(70, 61, d.CONTENT.NORTHREND), 0, "level 61 is gray to a level 70")
  h.eq(d.BaseGain(70, 62, d.CONTENT.NORTHREND), 492, "level 62 gives 492")
end)

h.run("heirloom table", function()
  local d = load().data
  h.eq(d.HEIRLOOM_XP[42949], 10, "a +10% shoulder")
  h.eq(d.HEIRLOOM_XP[48677], 10, "a +10% chest")
  h.eq(d.HEIRLOOM_XP[50255], 5, "Dread Pirate Ring is +5%")
  h.eq(d.HEIRLOOM_XP[42991], nil, "Swift Hand of Justice grants NO xp")
  h.eq(d.HEIRLOOM_XP[42992], nil, "Discerning Eye of the Beast grants NO xp")
  local n = 0
  for _ in pairs(d.HEIRLOOM_XP) do n = n + 1 end
  h.eq(n, 20, "exactly 20 obtainable XP heirlooms on 3.3.5a")
end)

h.run("XPBetween sums whole levels", function()
  local d = load().data
  h.eq(d.XPBetween(1, 2), 400, "one level")
  h.eq(d.XPBetween(1, 4), 400 + 900 + 1400, "three levels")
  h.eq(d.XPBetween(5, 5), 0, "no levels")
end)

-- UnitXP resets on level-up, so a naive newXP - oldXP is always wrong.
h.run("XPDelta across level-ups", function()
  local d = load().data
  h.eq(d.XPDelta(10, 100, 7600, 10, 500), 400, "same level is a plain delta")
  -- level 10 at 7000/7600, gain crosses into level 11 at 200.
  h.eq(d.XPDelta(10, 7000, 7600, 11, 200), 600 + 200, "one level-up")
  -- two level-ups: finish 10, cross all of 11 (8700), land at 50 in 12.
  h.eq(d.XPDelta(10, 7000, 7600, 12, 50), 600 + 8700 + 50, "two level-ups")
end)

os.exit(h.report() and 0 or 1)
