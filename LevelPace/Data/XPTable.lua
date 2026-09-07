-- LevelPace :: Data/XPTable
-- The 3.3.5a XP curve, the XP-heirloom item list, and a faithful Lua port of
-- TrinityCore's kill-XP formula.

local LP = _G.LevelPace
LP.data = {}
local d = LP.data

-- Base-XP constant, selected by the CONTENT TIER OF THE MAP -- not by player
-- level. GetContentLevelsForMapAndZone: mapid<2 or expansion 0 -> 45,
-- expansion 1 (Outland) -> 235, expansion 2 (Northrend) -> 580.
d.CONTENT = { AZEROTH = 45, OUTLAND = 235, NORTHREND = 580 }

-- XP required to advance FROM this level to the next.
-- Verbatim from AzerothCore data/sql/base/db_world/player_xp_for_level.sql
-- (byte-identical in CMaNGOS-WotLK). Totals: 1->60 = 3,379,400,
-- 1->70 = 8,101,400, 1->80 = 24,067,200. The test asserts all three.
d.XP_FOR_LEVEL = {
  400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
  8700, 9800, 11000, 12300, 13600, 15000, 16400, 17800, 19300, 20800,
  22400, 24000, 25500, 27200, 28900, 30500, 32200, 33900, 36300, 38800,
  41600, 44600, 48000, 51400, 55000, 58700, 62400, 66200, 70200, 74300,
  78500, 82800, 87100, 91600, 96300, 101000, 105800, 110700, 115700, 120900,
  126100, 131500, 137000, 142500, 148200, 154000, 159900, 165800, 172000, 290000,
  317000, 349000, 386000, 428000, 475000, 527000, 585000, 648000, 717000, 1523800,
  1539600, 1555700, 1571800, 1587900, 1604200, 1620700, 1637400, 1653900, 1670800,
}

d.MAX_LEVEL = 80

-- 3.3.5a XP heirlooms: item ID -> percent bonus.
--
-- These auras are NOT visible through UnitBuff/UnitAura. TrinityCore's
-- Aura::CanBeSentToClient() excludes passive item-equip auras, so they never
-- get a client aura slot. Equipped-item scanning is the only detection path.
--
-- No WotLK heirloom weapon or trinket grants XP -- Swift Hand of Justice
-- (42991) and Discerning Eye of the Beast (42992) deliberately absent.
d.HEIRLOOM_XP = {}
for _, id in ipairs {
  42949, 42950, 42951, 42952, 42984, 42985,
  44099, 44100, 44101, 44102, 44103, 44105, 44107,
} do
  d.HEIRLOOM_XP[id] = 10 -- shoulders
end
for _, id in ipairs { 48677, 48683, 48685, 48687, 48689, 48691 } do
  d.HEIRLOOM_XP[id] = 10 -- chests
end
d.HEIRLOOM_XP[50255] = 5 -- Dread Pirate Ring (unique-equipped)

-- Slots worth scanning for XP heirlooms.
d.HEIRLOOM_SLOTS = { 3, 5, 11, 12 } -- shoulder, chest, finger1, finger2

-- Trinity::XP::GetGrayLevel
function d.GrayLevel(pl)
  if pl <= 5 then return 0 end
  if pl <= 39 then return pl - 5 - math.floor(pl / 10) end
  if pl <= 59 then return pl - 1 - math.floor(pl / 5) end
  return pl - 9
end

-- Trinity::XP::GetZeroDifference
function d.ZeroDifference(pl)
  if pl < 8 then return 5 end
  if pl < 10 then return 6 end
  if pl < 12 then return 7 end
  if pl < 16 then return 8 end
  if pl < 20 then return 9 end
  if pl < 30 then return 11 end
  if pl < 40 then return 12 end
  if pl < 45 then return 13 end
  if pl < 50 then return 14 end
  if pl < 55 then return 15 end
  if pl < 60 then return 16 end
  return 17
end

-- Trinity::XP::BaseGain, 3.3.5 branch.
--
-- Two things people get wrong here:
--   1. The base term uses PLAYER level. "5 * mobLevel + 45" is wrong.
--   2. All C++ integer division truncates, so every division needs a floor
--      or the numbers drift from what the server actually awards.
function d.BaseGain(plLevel, mobLevel, nBaseExp)
  nBaseExp = nBaseExp or d.CONTENT.AZEROTH
  local B = plLevel * 5 + nBaseExp
  if mobLevel >= plLevel then
    local diff = mobLevel - plLevel
    if diff > 4 then diff = 4 end -- +5%/level, capped at +4 levels
    return math.floor((math.floor(B * (20 + diff) / 10) + 1) / 2)
  end
  local gray = d.GrayLevel(plLevel)
  if mobLevel > gray then
    local ZD = d.ZeroDifference(plLevel)
    return math.floor(B * (ZD + mobLevel - plLevel) / ZD)
  end
  return 0 -- gray: no XP at all. This is a cliff, not a fade.
end

-- XP needed to travel from one level to another. UnitXPMax only knows the
-- CURRENT level, so multi-level deltas need this table.
function d.XPBetween(fromLevel, toLevel)
  local sum = 0
  for lvl = fromLevel, toLevel - 1 do
    sum = sum + (d.XP_FOR_LEVEL[lvl] or 0)
  end
  return sum
end

-- Total XP crossed by a gain that spanned one or more level-ups.
-- UnitXP resets on level-up, so a naive newXP - oldXP is always wrong.
function d.XPDelta(oldLevel, oldXP, oldMax, newLevel, newXP)
  if newLevel == oldLevel then return newXP - oldXP end
  return (oldMax - oldXP) + d.XPBetween(oldLevel + 1, newLevel) + newXP
end
