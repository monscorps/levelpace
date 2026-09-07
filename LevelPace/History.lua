-- LevelPace :: History
--
-- Per-level records. This is the corpus that lets the addon lean on how YOU
-- actually level rather than a clean-room average.
--
-- Design stance: no sanitising. Deaths count. Corpse runs count. The walk
-- between camps counts. A number that quietly deletes your downtime is not
-- measuring your levelling. The only filter is a manual reset.

local LP = _G.LevelPace
local util = LP.util
local d = LP.data

local History = {}
LP.History = History

local BASE_RATE_WINDOW = 60   -- rolling base-XP samples for the current level
local KILL_XP_WINDOW = 120    -- per-kill base XP, for the mobs-to-level range

local function newRecord(level, now)
  return {
    level = level,
    startedAt = now,
    endedAt = false,
    elapsed = 0,
    xpBySource = { kill = 0, quest = 0, explore = 0, unknown = 0 },
    killCount = 0,
    questCount = 0,
    deaths = 0,
    corpseRunSeconds = 0,
    restedConsumed = 0,
    baseXP = 0,
    largestGap = 0,
    lastEventAt = now,
    zones = {},
  }
end

function History:Init()
  local now = GetTime and GetTime() or 0
  local level = (UnitLevel and UnitLevel("player")) or 1
  if not LP.db then return end
  LP.db.history = LP.db.history or {}
  -- A stored record is resumed only if it is for the level we are actually
  -- on; otherwise the player levelled while the addon was off.
  if not LP.db.current or LP.db.current.level ~= level then
    LP.db.current = newRecord(level, now)
  else
    -- GetTime() restarts at zero every session, so absolute stamps from a
    -- previous session are meaningless. Rebase them onto this session.
    LP.db.current.startedAt = now - (LP.db.current.elapsed or 0)
    LP.db.current.lastEventAt = now
  end
  self.record = LP.db.current
  self.baseRateSamples = {}
  self.killXPSamples = {}
  return self.record
end

function History:Current()
  if not self.record then self:Init() end
  return self.record
end

function History:Get(level)
  if not LP.db or not LP.db.history then return nil end
  for _, r in ipairs(LP.db.history) do
    if r.level == level then return r end
  end
  return nil
end

function History:All()
  return (LP.db and LP.db.history) or {}
end

-- ---------------------------------------------------------------------------
-- Accumulation
-- ---------------------------------------------------------------------------

function History:AddEvent(e)
  local r = self:Current()
  if not r then return end
  local now = e.t or (GetTime and GetTime()) or 0

  -- The gap is RECORDED, not filtered. If you tabbed out for two hours the
  -- projection stays honest and the UI says why it looks odd.
  local gap = now - (r.lastEventAt or now)
  if gap > (r.largestGap or 0) then r.largestGap = gap end
  r.lastEventAt = now

  r.elapsed = now - r.startedAt

  local bucket = e.source or "unknown"
  if r.xpBySource[bucket] == nil then bucket = "unknown" end
  r.xpBySource[bucket] = r.xpBySource[bucket] + (e.total or 0)

  r.baseXP = r.baseXP + (e.base or 0)
  r.restedConsumed = r.restedConsumed + (e.rested or 0)

  if e.source == "kill" then
    r.killCount = r.killCount + 1
    util.PushBounded(self.killXPSamples, e.base or 0, KILL_XP_WINDOW)
  elseif e.source == "quest" then
    r.questCount = r.questCount + 1
  end

  -- Base XP per second over the level so far. Uses wall-clock elapsed, which
  -- is the whole point: it includes the running and the dying.
  if r.elapsed > 0 then
    util.PushBounded(self.baseRateSamples, r.baseXP / r.elapsed, BASE_RATE_WINDOW)
  end

  local zone = GetZoneText and GetZoneText() or "?"
  r.zones[zone] = (r.zones[zone] or 0) + gap
end

function History:OnLevelUp(newLevel)
  local now = GetTime and GetTime() or 0
  local r = self:Current()
  if r then
    r.endedAt = now
    r.elapsed = now - r.startedAt
    LP.db.history = LP.db.history or {}
    table.insert(LP.db.history, r)
    -- One record per level, 79 max per character. No pruning needed.
  end
  LP.db.current = newRecord(newLevel, now)
  self.record = LP.db.current
  self.baseRateSamples = {}
  self.killXPSamples = {}
  LP:Fire("LEVEL_CHANGED", newLevel)
end

function History:OnDeath()
  local r = self:Current()
  if not r then return end
  r.deaths = r.deaths + 1
  self.diedAt = GetTime and GetTime() or 0
end

function History:OnResurrect()
  local r = self:Current()
  if not r or not self.diedAt then return end
  local now = GetTime and GetTime() or 0
  r.corpseRunSeconds = r.corpseRunSeconds + (now - self.diedAt)
  self.diedAt = nil
end

-- Reset is the ONLY filter in the addon. It clears the current level's
-- tracking without touching completed levels.
function History:Reset()
  local now = GetTime and GetTime() or 0
  local level = (UnitLevel and UnitLevel("player")) or (self.record and self.record.level) or 1
  LP.db.current = newRecord(level, now)
  self.record = LP.db.current
  self.baseRateSamples = {}
  self.killXPSamples = {}
  LP:Fire("HISTORY_RESET")
end

-- ---------------------------------------------------------------------------
-- Learned pace
-- ---------------------------------------------------------------------------

-- Median base XP/sec across COMPLETED levels. This is what the estimator
-- leans on early in a level, before the current level has enough data.
function History:MedianBaseRate()
  local rates = {}
  for _, r in ipairs(self:All()) do
    if r.elapsed and r.elapsed > 0 and r.baseXP and r.baseXP > 0 then
      rates[#rates + 1] = r.baseXP / r.elapsed
    end
  end
  return util.Median(rates)
end

function History:BaseRateSamples() return self.baseRateSamples or {} end
function History:KillXPSamples() return self.killXPSamples or {} end

-- What fraction of the current level has been observed. Used to weight the
-- blend between the current level's own rate and the learned history.
function History:ObservedFraction()
  local r = self:Current()
  if not r then return 0 end
  local xpMax = (UnitXPMax and UnitXPMax("player")) or 0
  if xpMax <= 0 then return 0 end  -- max level
  local observed = (r.xpBySource.kill or 0) + (r.xpBySource.quest or 0)
    + (r.xpBySource.explore or 0) + (r.xpBySource.unknown or 0)
  local f = observed / xpMax
  if f > 1 then f = 1 end
  return f
end

-- Summary of how a completed level actually went, for the tooltip.
function History:Summarise(r)
  if not r then return nil end
  local total = 0
  for _, v in pairs(r.xpBySource) do total = total + v end
  return {
    level = r.level,
    elapsed = r.elapsed,
    total = total,
    questShare = total > 0 and (r.xpBySource.quest / total) or 0,
    killShare = total > 0 and (r.xpBySource.kill / total) or 0,
    deaths = r.deaths,
    corpseRunSeconds = r.corpseRunSeconds,
    killCount = r.killCount,
    questCount = r.questCount,
  }
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

LP:On("XP_EVENT", function(e) History:AddEvent(e) end)

function History:Enable()
  self:Init()
  if not CreateFrame then return end
  local f = CreateFrame("Frame", "LevelPaceHistory")
  util.SafeRegisterEvent(f, "PLAYER_LEVEL_UP")
  util.SafeRegisterEvent(f, "PLAYER_DEAD")
  util.SafeRegisterEvent(f, "PLAYER_UNGHOST")
  util.SafeRegisterEvent(f, "PLAYER_ALIVE")
  f:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LEVEL_UP" then
      History:OnLevelUp(arg1)
    elseif event == "PLAYER_DEAD" then
      History:OnDeath()
    else
      History:OnResurrect()
    end
  end)
  self.frame = f
end

LP:On("PLAYER_READY", function() History:Enable() end)
