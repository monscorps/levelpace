package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  local LP = h.loadCore()
  h.load("LevelPace/Ledger.lua")
  h.load("LevelPace/Modifiers.lua")
  h.load("LevelPace/Rates.lua")
  LP:InitDB()
  LP.Rates:Load()
  return LP
end

h.run("quest rate is nil below the sample threshold", function()
  local LP = load()
  LP.Rates:AddQuestSample(4200, 21000, 1)
  LP.Rates:AddQuestSample(3000, 15000, 1)
  h.eq(LP.Rates:GetQuestRate(), nil, "2 samples is not enough -- say 'learning', not a wrong number")
  h.eq(LP.Rates:QuestSampleCount(), 2, "counted")
end)

h.run("quest rate converges to the server multiplier", function()
  local LP = load()
  for _ = 1, 5 do LP.Rates:AddQuestSample(4200, 21000, 1) end
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.001, "x5 server")
end)

h.run("a blizzlike x1 server reads as 1", function()
  local LP = load()
  for _ = 1, 5 do LP.Rates:AddQuestSample(4200, 4200, 1) end
  h.near(LP.Rates:GetQuestRate(), 1.0, 0.001, "x1")
end)

-- Heirlooms boost quest XP too, so they must be divided out or the learned
-- SERVER rate is inflated by the player's gear.
h.run("quest rate divides out the heirloom bonus", function()
  local LP = load()
  for _ = 1, 5 do LP.Rates:AddQuestSample(4200, 4200 * 5 * 1.2705, 1.2705) end
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.01, "gear does not inflate the server rate")
end)

h.run("median resists a single mis-attributed sample", function()
  local LP = load()
  for _ = 1, 5 do LP.Rates:AddQuestSample(4200, 21000, 1) end
  LP.Rates:AddQuestSample(4200, 999999, 1)
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.001, "median is unmoved by one outlier")
end)

h.run("window is bounded", function()
  local LP = load()
  for _ = 1, 25 do LP.Rates:AddQuestSample(1000, 1000, 1) end
  h.ok(LP.Rates:QuestSampleCount() <= LP.Rates.WINDOW, "bounded to the window")
end)

h.run("garbage samples are rejected, not stored", function()
  local LP = load()
  LP.Rates:AddQuestSample(0, 5000, 1)
  LP.Rates:AddQuestSample(4200, 0, 1)
  LP.Rates:AddQuestSample(nil, 5000, 1)
  LP.Rates:AddQuestSample(4200, nil, 1)
  h.eq(LP.Rates:QuestSampleCount(), 0, "nothing stored")
end)

h.run("reset clears both", function()
  local LP = load()
  for _ = 1, 5 do LP.Rates:AddQuestSample(1000, 5000, 1) end
  LP.Rates:Reset()
  h.eq(LP.Rates:QuestSampleCount(), 0, "cleared")
  h.eq(LP.Rates:GetQuestRate(), nil, "back to unknown")
end)

-- A quest XP_EVENT carrying a client prediction should feed the learner
-- automatically.
h.run("XP_EVENT with a prediction feeds the quest learner", function()
  local LP = load()
  for _ = 1, 4 do
    LP.Ledger:NoteQuestFinished(1, 4200)
    LP.Ledger:OnChat("You gain 21000 experience.")
    h.advance(0.1)
  end
  h.eq(LP.Rates:QuestSampleCount(), 4, "four samples learned from real events")
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.001, "x5 learned end to end")
end)

h.run("an unattributed gain does not feed the learner", function()
  local LP = load()
  LP.Ledger:OnChat("You gain 21000 experience.")
  h.eq(LP.Rates:QuestSampleCount(), 0, "unknown source is not a quest sample")
end)

-- RAF and rested bonuses ride on top of the server rate; comparing TOTAL
-- would inflate what we learn.
h.run("learner compares base, not total", function()
  local LP = load()
  for _ = 1, 4 do
    LP.Ledger:NoteQuestFinished(1, 1000)
    LP.Ledger:OnChat("You gain 3000 experience. (+2000 exp Refer-A-Friend bonus)")
    h.advance(0.1)
  end
  h.near(LP.Rates:GetQuestRate(), 1.0, 0.001, "base 1000 vs predicted 1000 is x1, not x3")
end)


-- ==== the exact path ====
-- GetRewardXP() is server truth (rate x auras applied); GetQuestLogRewardXP()
-- is blizzlike. Their ratio IS the multiplier -- no turn-in needed.

h.run("one ratio sample gives the rate exactly", function()
  local LP = load()
  LP.Rates:AddQuestRatioSample(21000, 4200, 1)
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.001, "x5 from a single sample")
  h.eq(LP.Rates:QuestRateSource(), "exact", "labelled exact")
  h.eq(LP.Rates:QuestSamplesNeeded(), 0, "nothing more needed")
end)

h.run("ratio divides out heirlooms to leave the server rate", function()
  local LP = load()
  -- GetRewardXP already includes the heirloom aura, so it must be removed.
  LP.Rates:AddQuestRatioSample(4200 * 5 * 1.2705, 4200, 1.2705)
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.01, "gear does not inflate the server rate")
end)

h.run("exact reading beats the statistical fallback", function()
  local LP = load()
  for _ = 1, 5 do LP.Rates:AddQuestSample(1000, 3000, 1) end  -- fallback says x3
  h.near(LP.Rates:GetQuestRate(), 3.0, 0.001, "fallback in use")
  LP.Rates:AddQuestRatioSample(5000, 1000, 1)                 -- exact says x5
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.001, "exact wins outright")
  h.eq(LP.Rates:QuestRateSource(), "exact", "source switches")
end)

h.run("garbage ratio samples are rejected", function()
  local LP = load()
  LP.Rates:AddQuestRatioSample(0, 4200, 1)
  LP.Rates:AddQuestRatioSample(21000, 0, 1)
  LP.Rates:AddQuestRatioSample(nil, 4200, 1)
  h.eq(LP.Rates:RatioSampleCount(), 0, "nothing stored")
  h.eq(LP.Rates:GetQuestRate(), nil, "still unknown")
end)

h.run("reset clears the exact samples too", function()
  local LP = load()
  LP.Rates:AddQuestRatioSample(21000, 4200, 1)
  LP.Rates:Reset()
  h.eq(LP.Rates:RatioSampleCount(), 0, "cleared")
  h.eq(LP.Rates:GetQuestRate(), nil, "back to unknown")
end)

os.exit(h.report() and 0 or 1)
