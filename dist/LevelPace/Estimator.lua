-- LevelPace :: Estimator
--
-- Time-to-level and mobs-to-level.
--
-- Deliberately reads NO WoW globals. Update() takes a plain state table so the
-- whole thing is testable outside the game; Refresh() is the thin adapter that
-- gathers real state and calls it.

local LP = _G.LevelPace
local util = LP.util

local Estimator = {}
LP.Estimator = Estimator

local MIN_KILLS_FOR_RANGE = 10

Estimator.result = {}

-- state = {
--   xp, xpMax, restedPool,
--   baseRateSamples  -- array of base XP per second
--   killXPSamples    -- array of base XP per kill
--   historyRate      -- median base XP/sec from completed levels (optional)
--   observedFraction -- 0..1, how much of this level we have watched
--   largestGap, countRested
-- }
function Estimator:Update(state)
  local r = {}
  self.result = r

  local xpMax = state.xpMax or 0
  local xp = state.xp or 0

  -- At max level UnitXPMax reports 0. Everything downstream divides by it, so
  -- bail out with an explicit flag rather than producing 0s and inf.
  if xpMax <= 0 then
    r.maxLevel = true
    r.confidence = "none"
    r.percent = 0
    r.xpRemaining = 0
    return r
  end

  -- XP gain can also be switched off at an NPC, in which case no projection
  -- means anything.
  if state.xpDisabled then
    r.xpDisabled = true
    r.confidence = "none"
    r.percent = xpMax > 0 and (xp / xpMax * 100) or 0
    r.xpRemaining = math.max(0, xpMax - xp)
    return r
  end

  r.xpRemaining = math.max(0, xpMax - xp)
  r.percent = xp / xpMax * 100

  -- Blend the current level's observed rate with the player's own history.
  -- Early in a level history dominates; late in a level observation does.
  local liveRate = util.Median(state.baseRateSamples or {})
  local histRate = state.historyRate
  local f = state.observedFraction or 0
  if f < 0 then f = 0 elseif f > 1 then f = 1 end

  local baseRate
  if liveRate and histRate then
    baseRate = liveRate * f + histRate * (1 - f)
    r.rateSource = "blended"
  elseif liveRate then
    baseRate = liveRate
    r.rateSource = "current level"
  elseif histRate then
    baseRate = histRate
    r.rateSource = "past levels"
  end

  r.baseRate = baseRate
  r.baseRatePerHour = baseRate and (baseRate * 3600) or nil

  -- Kill-only rate, kept separate: this is what quests are compared against.
  r.killRate = state.killRate
  r.killRatePerHour = state.killRate and (state.killRate * 3600) or nil

  -- ---- rested-aware projection ----
  --
  -- The subtlety: a pool of P does not supply P XP, it supplies 2P XP in
  -- exchange for P XP worth of BASE killing. Formulating this as
  --   pool / (2 * rate) + (remaining - 2 * pool) / rate
  -- understates time-to-level by up to 5x when heavily rested.
  local pool = (state.countRested == false) and 0 or (state.restedPool or 0)
  local xpCoveredByRested = math.min(2 * pool, r.xpRemaining)
  local baseWhileRested = xpCoveredByRested / 2
  local baseAfterRested = r.xpRemaining - xpCoveredByRested
  local baseNeeded = baseWhileRested + baseAfterRested

  r.baseNeeded = baseNeeded
  r.restedCovered = xpCoveredByRested
  r.restedPool = pool

  if baseRate and baseRate > 0 then
    r.timeToLevel = baseNeeded / baseRate
  else
    r.timeToLevel = nil
  end

  -- ---- mobs to level ----
  --
  -- Presented as a RANGE, because you kill mixed-level mobs and a single
  -- integer would be false precision. Below the sample threshold we show
  -- nothing rather than something confidently wrong.
  local kills = state.killXPSamples or {}
  if #kills >= MIN_KILLS_FOR_RANGE and baseNeeded > 0 then
    local p25 = util.Percentile(kills, 0.25)
    local p75 = util.Percentile(kills, 0.75)
    if p25 and p25 > 0 and p75 and p75 > 0 then
      -- High XP per kill gives the LOW mob count.
      r.mobsLow = math.ceil(baseNeeded / p75)
      r.mobsHigh = math.ceil(baseNeeded / p25)
      r.xpPerKillLow, r.xpPerKillHigh = p25, p75
    end
  end
  r.killSampleCount = #kills

  -- ---- honesty annotations ----
  r.gapWarning = nil
  local threshold = state.gapThreshold or 600
  if threshold > 0 and (state.largestGap or 0) >= threshold then
    r.gapWarning = state.largestGap
  end

  if not baseRate then
    r.confidence = "none"
  elseif f >= 0.25 and r.killSampleCount >= MIN_KILLS_FOR_RANGE then
    r.confidence = "good"
  else
    r.confidence = "low"
  end

  return r
end

function Estimator:Result() return self.result end

-- Adapter: gather real state and update. Kept separate so Update stays pure.
function Estimator:Refresh()
  if not UnitXP then return self.result end
  local H, M = LP.History, LP.Modifiers
  local rec = H and H:Current()
  return self:Update({
    xp = UnitXP("player"),
    xpMax = UnitXPMax("player"),
    restedPool = M and M:GetRestedPool() or 0,
    baseRateSamples = H and H:BaseRateSamples() or {},
    killRate = H and H:LiveKillRate() or nil,
    killXPSamples = H and H:KillXPSamples() or {},
    historyRate = H and H:MedianBaseRate() or nil,
    observedFraction = H and H:ObservedFraction() or 0,
    xpDisabled = M and M:IsXPDisabled() or false,
    largestGap = rec and rec.largestGap or 0,
    gapThreshold = LP.db and LP.db.profile.gapWarnSeconds or 600,
    countRested = LP.db and LP.db.profile.countRestedInProjection ~= false,
  })
end

-- Base KILL XP per minute -- the unit the quest ranker compares against.
-- Deliberately not baseRate: see History:LiveKillRate.
function Estimator:GrindXPPerMinute()
  local r = self.result
  if not r or not r.killRate then return nil end
  return r.killRate * 60
end

LP:On("XP_EVENT", function() Estimator:Refresh() end)
LP:On("HISTORY_RESET", function() Estimator:Refresh() end)

-- Heartbeat. Without this the projection only moves when XP arrives, so the
-- display sits frozen between kills and the rate never reflects idle time.
-- One shared job on the single driver frame; the work is a handful of
-- arithmetic ops.
LP:On("PLAYER_READY", function()
  LP:Schedule(1, function()
    Estimator:Refresh()
    LP:Fire("TICK")
  end)
end)
