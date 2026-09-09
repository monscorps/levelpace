-- LevelPace :: Parse
--
-- Scores your current pace as a percentile and maps it to the WarcraftLogs
-- colour bands.
--
-- THE METRIC IS LEVELS PER HOUR, not XP per hour. XP/hr is not comparable
-- across levels -- a level 78 in Icecrown earns more XP per hour than a
-- level 20 can no matter how well the level 20 plays -- and it is not
-- comparable across servers either, since rates differ. The fraction of a
-- level you clear per hour normalises both away.
--
-- THE BASELINE IS SWAPPABLE. Right now it is your own completed levels, so
-- the number is honestly "compared to how you usually play". When a global
-- leaderboard exists, SetBaseline() takes its distribution instead and the
-- same gauge becomes a real parse.

local LP = _G.LevelPace
local util = LP.util

local Parse = {}
LP.Parse = Parse

-- Below this many samples a percentile is noise dressed up as precision.
Parse.MIN_BASELINE = 3

-- WarcraftLogs bands. Names use WoW item qualities, which is what the colours
-- are drawn from.
Parse.BANDS = {
  { min = 100, key = "artifact",  name = "Artifact",  r = 0.898, g = 0.800, b = 0.502 }, -- e5cc80
  { min = 99,  key = "pink",      name = "Astounding",r = 0.886, g = 0.408, b = 0.659 }, -- e268a8
  { min = 95,  key = "legendary", name = "Legendary", r = 1.000, g = 0.502, b = 0.000 }, -- ff8000
  { min = 75,  key = "epic",      name = "Epic",      r = 0.639, g = 0.208, b = 0.933 }, -- a335ee
  { min = 50,  key = "rare",      name = "Rare",      r = 0.000, g = 0.439, b = 1.000 }, -- 0070ff
  { min = 25,  key = "uncommon",  name = "Uncommon",  r = 0.118, g = 1.000, b = 0.000 }, -- 1eff00
  { min = 0,   key = "common",    name = "Common",    r = 0.400, g = 0.400, b = 0.400 }, -- 666666
}

function Parse:Band(pct)
  if type(pct) ~= "number" then return nil end
  for _, b in ipairs(self.BANDS) do
    if pct >= b.min then return b end
  end
  return self.BANDS[#self.BANDS]
end

function Parse:Colorize(pct, text)
  local b = self:Band(pct)
  if not b then return text end
  return string.format("|cff%02x%02x%02x%s|r",
    math.floor(b.r * 255 + 0.5), math.floor(b.g * 255 + 0.5),
    math.floor(b.b * 255 + 0.5), text)
end

-- ---------------------------------------------------------------------------
-- Baseline
-- ---------------------------------------------------------------------------

-- An externally supplied distribution of levels-per-hour values, e.g. from a
-- leaderboard. Overrides the personal baseline when present.
function Parse:SetBaseline(list, label)
  if type(list) == "table" and #list > 0 then
    self.baseline = list
    self.baselineLabel = label or "global"
  else
    self.baseline = nil
    self.baselineLabel = nil
  end
end

-- Your own completed levels, as levels-per-hour.
function Parse:PersonalBaseline(forLevel)
  local H = LP.History
  if not H then return {} end
  local out = {}
  for _, r in ipairs(H:All()) do
    if r.elapsed and r.elapsed > 0 then
      -- One whole level in `elapsed` seconds.
      if not forLevel or r.level == forLevel then
        out[#out + 1] = 3600 / r.elapsed
      end
    end
  end
  return out
end

-- Adopt the uploader-written global distribution, if one is present.
-- Per-level is preferred: comparing a level 71 against level 71s is far
-- fairer than against the pooled distribution, which is dominated by
-- whichever levels are cheapest.
function Parse:LoadGeneratedBaseline(forLevel)
  local b = _G.LevelPaceBaseline
  if type(b) ~= "table" then return nil end
  local byLevel = forLevel and b.byLevel and b.byLevel[forLevel]
  if type(byLevel) == "table" and #byLevel >= self.MIN_BASELINE then
    return byLevel, string.format("global, level %d (%d players)",
      forLevel, b.players or 0)
  end
  if type(b.overall) == "table" and #b.overall >= self.MIN_BASELINE then
    return b.overall, string.format("global, all levels (%d players)", b.players or 0)
  end
  return nil
end

-- Returns list, label, isGlobal. Only a GLOBAL baseline -- other players --
-- is a ranking. Your own past levels are still returned as a comparison, but
-- flagged, because a percentile against yourself is not a parse: a level 6
-- whose levels 1-4 took a minute each was shown a grey "Common" for pacing
-- slower than that, with nobody else on the board at all.
function Parse:Baseline(forLevel)
  if self.baseline then return self.baseline, self.baselineLabel, true end

  local global, glabel = self:LoadGeneratedBaseline(forLevel)
  if global then return global, glabel, true end
  -- Same-level comparison is fairer but rarely has enough samples on one
  -- character, so fall back to all levels.
  local same = self:PersonalBaseline(forLevel)
  if #same >= self.MIN_BASELINE then return same, "your level " .. tostring(forLevel), false end
  return self:PersonalBaseline(nil), "your past levels", false
end

-- How many OTHER players the global baseline holds for this level, for the
-- "nobody else yet" wording. Nil when no baseline file exists at all.
function Parse:GlobalSampleCount(forLevel)
  local b = _G.LevelPaceBaseline
  if type(b) ~= "table" then return nil end
  local byLevel = forLevel and b.byLevel and b.byLevel[forLevel]
  if type(byLevel) == "table" then return #byLevel end
  return 0
end

-- Every finished level against everyone else's time at that level: the
-- per-level parse, newest first. Numbers come from Baseline.lua, written by
-- the companion, so this fills in as the board does. Your own row is on the
-- board too once uploaded; if it is not there yet it is added, so the n-1
-- divisor always means "everyone else".
function Parse:LevelParses(limit)
  local H = LP.History
  if not H then return {} end
  local b = _G.LevelPaceBaseline
  local byLevel = type(b) == "table" and type(b.byLevel) == "table" and b.byLevel or {}
  local all = H:All()
  local out = {}
  for i = #all, 1, -1 do
    local r = all[i]
    if r.level and r.elapsed and r.elapsed >= 1 then
      -- The SAME integer the board holds: the export floors elapsed
      -- (Export.lua), the companion writes the board's figure to 4 decimals.
      -- Ranking the raw float against that never matched our own row, so it
      -- was counted twice and every percentile came out low.
      local value = 3600 / math.floor(r.elapsed)
      local list, seen = {}, false
      for _, v in ipairs(byLevel[r.level] or {}) do
        list[#list + 1] = v
        if math.abs(v - value) < 1e-3 then seen = true end
      end
      if not seen then list[#list + 1] = value end
      -- Same floor as the live gauge: under MIN_BASELINE a percentile is
      -- noise dressed up as precision, and it must not get a colour.
      local pct = (#list >= self.MIN_BASELINE) and LP.util.RankPercentile(value, list) or nil
      out[#out + 1] = {
        level = r.level, elapsed = r.elapsed, lph = value,
        pct = pct, band = pct and self:Band(pct) or nil, of = #list,
      }
      if limit and #out >= limit then break end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------

-- Fraction of a level per hour at the current measured pace.
function Parse:CurrentLevelsPerHour()
  local r = LP.Estimator and LP.Estimator:Result()
  if not r or r.maxLevel or not r.baseRate then return nil end
  local xpMax = (UnitXPMax and UnitXPMax("player")) or 0
  if xpMax <= 0 then return nil end
  return r.baseRate * 3600 / xpMax
end

-- Percentile of `value` within `list`: the share of the baseline it beats.
function Parse:PercentileOf(value, list)
  if type(value) ~= "number" or type(list) ~= "table" or #list == 0 then return nil end
  local beaten = 0
  for i = 1, #list do
    if value > list[i] then beaten = beaten + 1 end
  end
  return beaten / #list * 100
end

-- Returns percentile, band, levelsPerHour, baselineLabel, sampleCount.
-- Percentile is nil when there is no ranking: no other players at this level
-- on the board yet (fewer than MIN_BASELINE). Your own history is never
-- scored as a parse.
function Parse:Current()
  local lph = self:CurrentLevelsPerHour()
  if not lph then return nil end
  local level = (UnitLevel and UnitLevel("player")) or nil
  local list, label, global = self:Baseline(level)
  if not global or #list < self.MIN_BASELINE then
    local others = self:GlobalSampleCount(level) or 0
    return nil, nil, lph,
      string.format("nobody else at level %s on the board yet (%d of %d needed)",
        tostring(level or "?"), others, self.MIN_BASELINE),
      others
  end
  local pct = self:PercentileOf(lph, list)
  return pct, self:Band(pct), lph, label, #list
end

-- Short text for the box line, already coloured.
function Parse:Text()
  local pct, band, lph, label, n = self:Current()
  if not pct then
    if lph then return "|cff888888no parse yet|r" end
    return "|cff888888--|r"
  end
  return self:Colorize(pct, string.format("%d", math.floor(pct + 0.5)))
end
