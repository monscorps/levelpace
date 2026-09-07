-- LevelPace :: Rates
--
-- Learns the server's XP multipliers by comparing what the client PREDICTED
-- against what the player actually RECEIVED.
--
-- Rate.XP.Kill and Rate.XP.Quest are SEPARATE config values. A server can run
-- x5 kills with x1 quests, which inverts the grind-vs-quest recommendation.
-- So both are learned independently.
--
-- The QUEST rate is read EXACTLY, not estimated, using two APIs that disagree
-- on purpose:
--
--   GetQuestLogRewardXP()  blizzlike. The client recomputes it locally from
--                          QuestXP.dbc, because SMSG_QUEST_QUERY_RESPONSE
--                          carries only the raw difficulty INDEX, never an
--                          XP number.
--   GetRewardXP()          server truth. SMSG_QUESTGIVER_OFFER_REWARD is
--                          built by Quest::BuildQuestRewards ->
--                          Player::GetQuestXPReward, which is
--                          XPReward * RATE_XP_QUEST then AddPct over the
--                          SPELL_AURA_MOD_XP_QUEST_PCT auras.
--
-- Their ratio IS Rate.XP.Quest x aura multipliers. One clean sample is the
-- answer; the median over a few just guards against a bad title match.
--
-- The XP-observation path below is kept as a fallback for servers where
-- GetRewardXP is unavailable or the reward panel was never opened.

local LP = _G.LevelPace
local util = LP.util

local Rates = {}
LP.Rates = Rates

Rates.MIN_SAMPLES = 3
Rates.WINDOW = 20

Rates.ratioSamples = {}   -- exact, from GetRewardXP / GetQuestLogRewardXP
Rates.questSamples = {}   -- statistical fallback, from observed turn-in XP
Rates.killSamples = {}

local function realmKey()
  local ok, realm = pcall(function() return GetRealmName and GetRealmName() end)
  return (ok and realm) or "Unknown"
end

function Rates:Load()
  if not LP.gdb then return end
  LP.gdb.rates = LP.gdb.rates or {}
  local key = realmKey()
  LP.gdb.rates[key] = LP.gdb.rates[key] or { quest = {}, kill = {}, ratio = {} }
  local store = LP.gdb.rates[key]
  store.ratio = store.ratio or {}
  self.questSamples = store.quest
  self.killSamples = store.kill
  self.ratioSamples = store.ratio
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

-- The exact path. `rated` is GetRewardXP() (server), `blizz` is
-- GetQuestLogRewardXP() (client) for the SAME quest.
function Rates:AddQuestRatioSample(rated, blizz, heirloomMult)
  if type(rated) ~= "number" or type(blizz) ~= "number" then return end
  if rated <= 0 or blizz <= 0 then return end
  local denom = blizz * (heirloomMult or 1)
  if denom <= 0 then return end
  util.PushBounded(self.ratioSamples, rated / denom, self.WINDOW)
  LP:Fire("RATES_CHANGED")
end

function Rates:RatioSampleCount() return #self.ratioSamples end
function Rates:QuestSampleCount() return #self.questSamples end

-- How many more samples are needed before a rate is reported, for the UI.
function Rates:QuestSamplesNeeded()
  if #self.ratioSamples >= 1 then return 0 end
  return math.max(0, self.MIN_SAMPLES - #self.questSamples)
end

-- Returns nil until it actually knows. The UI must say "learning" rather than
-- imply x1 is known -- a confidently wrong recommendation is worse than an
-- absent one.
function Rates:GetQuestRate()
  -- Exact reading wins outright: it is derived, not estimated.
  if #self.ratioSamples >= 1 then return util.Median(self.ratioSamples) end
  if #self.questSamples < self.MIN_SAMPLES then return nil end
  return util.Median(self.questSamples)
end

function Rates:QuestRateSource()
  if #self.ratioSamples >= 1 then return "exact" end
  if #self.questSamples >= self.MIN_SAMPLES then return "observed" end
  return nil
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
  for i = #self.ratioSamples, 1, -1 do self.ratioSamples[i] = nil end
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
