-- LevelPace :: Rates
--
-- Learns the server's XP multipliers by comparing what the client PREDICTED
-- against what the player actually RECEIVED.
--
-- This is not a nicety. GetQuestLogRewardXP() returns the value the client
-- computes from its own QuestXP.dbc; the server applies Rate.XP.Quest
-- server-side at turn-in and never transmits it. On a x5 server the quest log
-- says 4,200 and you receive 21,000.
--
-- Rate.XP.Kill and Rate.XP.Quest are SEPARATE config values. A server can run
-- x5 kills with x1 quests, which inverts the grind-vs-quest recommendation.
-- So both are learned independently.

local LP = _G.LevelPace
local util = LP.util

local Rates = {}
LP.Rates = Rates

Rates.MIN_SAMPLES = 3
Rates.WINDOW = 20

Rates.questSamples = {}
Rates.killSamples = {}

local function realmKey()
  local ok, realm = pcall(function() return GetRealmName and GetRealmName() end)
  return (ok and realm) or "Unknown"
end

function Rates:Load()
  if not LP.gdb then return end
  LP.gdb.rates = LP.gdb.rates or {}
  local key = realmKey()
  LP.gdb.rates[key] = LP.gdb.rates[key] or { quest = {}, kill = {} }
  local store = LP.gdb.rates[key]
  self.questSamples = store.quest
  self.killSamples = store.kill
end

-- ---------------------------------------------------------------------------
-- Quest rate
-- ---------------------------------------------------------------------------

-- predicted: GetQuestLogRewardXP() captured BEFORE the quest left the log
-- actual:    XP actually received at turn-in
-- heirloomMult: divided out so gear does not inflate the learned server rate
function Rates:AddQuestSample(predicted, actual, heirloomMult)
  if type(predicted) ~= "number" or type(actual) ~= "number" then return end
  if predicted <= 0 or actual <= 0 then return end
  local denom = predicted * (heirloomMult or 1)
  if denom <= 0 then return end
  util.PushBounded(self.questSamples, actual / denom, self.WINDOW)
  LP:Fire("RATES_CHANGED")
end

function Rates:QuestSampleCount() return #self.questSamples end

-- Returns nil below the sample threshold. The UI must say "learning" rather
-- than imply that x1 is known -- a confidently wrong recommendation is worse
-- than an absent one.
function Rates:GetQuestRate()
  if #self.questSamples < self.MIN_SAMPLES then return nil end
  return util.Median(self.questSamples)
end

-- ---------------------------------------------------------------------------
-- Kill rate
--
-- Needs the mob's level, which the chat message does not carry -- we only get
-- it when the killed mob was our target at death. Many kills yield no sample,
-- which is fine: a handful is enough.
-- ---------------------------------------------------------------------------

function Rates:AddKillSample(observedBase, expectedBase)
  if type(observedBase) ~= "number" or type(expectedBase) ~= "number" then return end
  if observedBase <= 0 or expectedBase <= 0 then return end
  util.PushBounded(self.killSamples, observedBase / expectedBase, self.WINDOW)
  LP:Fire("RATES_CHANGED")
end

function Rates:KillSampleCount() return #self.killSamples end

function Rates:GetKillRate()
  if #self.killSamples < self.MIN_SAMPLES then return nil end
  return util.Median(self.killSamples)
end

function Rates:Reset()
  for i = #self.questSamples, 1, -1 do self.questSamples[i] = nil end
  for i = #self.killSamples, 1, -1 do self.killSamples[i] = nil end
  LP:Fire("RATES_CHANGED")
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

LP:On("DB_READY", function() Rates:Load() end)

LP:On("XP_EVENT", function(e)
  if e.source ~= "quest" then return end
  if not e.predictedXP then return end -- turn-in we could not pre-read
  local mult = LP.Modifiers and LP.Modifiers:HeirloomMultiplier() or 1
  -- Compare BASE, not total: an RAF bonus rides on top and would inflate the
  -- learned server rate.
  Rates:AddQuestSample(e.predictedXP, e.base, mult)
end)
