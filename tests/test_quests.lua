package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  local LP = h.loadCore()
  h.load("LevelPace/Ledger.lua")
  h.load("LevelPace/Modifiers.lua")
  h.load("LevelPace/Rates.lua")
  h.load("LevelPace/History.lua")
  h.load("LevelPace/Estimator.lua")
  h.load("LevelPace/Quests.lua")
  LP:InitDB()
  LP.Rates:Load()
  LP.History:Init()
  return LP
end

local function quest(id, title, xp, objectives, complete)
  return { title = title, level = 71, questID = id, xp = xp,
           isComplete = complete, objectives = objectives }
end

-- ==== objective parsing ====

h.run("parses a kill objective", function()
  local LP = load()
  local name, have, need = LP.Quests:ParseObjective("Ravenous Ghoul slain: 3/10")
  h.eq(name, "Ravenous Ghoul", "name without the 'slain' suffix")
  h.eq(have, 3, "have"); h.eq(need, 10, "need")
end)

h.run("parses a collection objective", function()
  local LP = load()
  local name, have, need = LP.Quests:ParseObjective("Scourge Core: 5/8")
  h.eq(name, "Scourge Core", "name"); h.eq(have, 5, "have"); h.eq(need, 8, "need")
end)

h.run("an uncountable objective returns nil", function()
  local LP = load()
  h.eq(LP.Quests:ParseObjective("Speak with Elder Kekek"), nil, "no counter")
  h.eq(LP.Quests:ParseObjective("Escort the prisoner to safety"), nil, "escort")
  h.eq(LP.Quests:ParseObjective(nil), nil, "nil is safe")
end)

-- ==== scanning ====

h.run("scan reads title, questID and reward xp", function()
  local LP = load()
  h.state.questLog = {
    quest(101, "Kill Ghouls", 12600, { { text = "Ghoul slain: 0/10" } }),
  }
  local out = LP.Quests:Scan()
  h.eq(#out, 1, "one quest")
  h.eq(out[1].questID, 101, "questID from position 9 of GetQuestLogTitle")
  h.eq(out[1].title, "Kill Ghouls", "title")
  h.eq(out[1].xp, 12600, "reward xp from GetQuestLogRewardXP")
  h.eq(out[1].remainingTicks, 10, "ten to go")
  h.eq(out[1].countable, true, "countable")
end)

h.run("scan skips header rows", function()
  local LP = load()
  h.state.questLog = {
    { title = "Howling Fjord", isHeader = true },
    quest(101, "Kill Ghouls", 100, { { text = "Ghoul slain: 0/10" } }),
  }
  h.eq(#LP.Quests:Scan(), 1, "header not treated as a quest")
end)

-- SelectQuestLogEntry moves the USER'S visible selection.
h.run("scan restores the quest log selection", function()
  local LP = load()
  h.state.questLog = {
    quest(101, "A", 100, { { text = "X: 0/5" } }),
    quest(102, "B", 200, { { text = "Y: 0/5" } }),
    quest(103, "C", 300, { { text = "Z: 0/5" } }),
  }
  SelectQuestLogEntry(2)
  LP.Quests:Scan()
  h.eq(GetQuestLogSelection(), 2, "the user's selection is put back")
end)

h.run("a quest with no countable objective is marked uncountable", function()
  local LP = load()
  h.state.questLog = {
    quest(201, "Speak to Kekek", 2100, { { text = "Speak with Elder Kekek" } }),
  }
  local out = LP.Quests:Scan()
  h.eq(out[1].countable, false, "not countable")
end)

-- ==== effort measurement ====

h.run("three ticks give a measured estimate", function()
  local LP = load()
  h.state.questLog = { quest(101, "Kill Ghouls", 1000, { { text = "Ghoul slain: 0/10" } }) }
  LP.Quests:Scan()
  -- one kill every 20s
  for i = 1, 3 do
    h.advance(20)
    h.state.questLog[1].objectives[1].text = "Ghoul slain: " .. i .. "/10"
    LP.Quests:Scan()
  end
  local minutes, tier = LP.Quests:EstimateMinutes(101)
  h.eq(tier, "measured", "measured from this quest's own ticks")
  -- 3 kills in 60s = 0.05/s; 7 remaining -> 140s -> 2.33 min
  h.near(minutes, 140 / 60, 0.05, "seven more at twenty seconds each")
end)

h.run("one tick falls back to inferred using other quests", function()
  local LP = load()
  h.state.questLog = {
    quest(101, "A", 1000, { { text = "Ghoul slain: 0/10" } }),
    quest(102, "B", 1000, { { text = "Wolf slain: 0/10" } }),
  }
  LP.Quests:Scan()
  -- quest 101 gets a solid measured rate
  for i = 1, 3 do
    h.advance(20)
    h.state.questLog[1].objectives[1].text = "Ghoul slain: " .. i .. "/10"
    LP.Quests:Scan()
  end
  -- quest 102 gets a single tick, not enough on its own
  h.advance(20)
  h.state.questLog[2].objectives[1].text = "Wolf slain: 1/10"
  LP.Quests:Scan()
  local minutes, tier = LP.Quests:EstimateMinutes(102)
  h.eq(tier, "inferred", "inferred from your pace elsewhere")
  h.ok(minutes and minutes > 0, "still produces a number")
end)

-- The honesty requirement: never invent a rate for something we cannot time.
h.run("an uncountable quest is unmeasurable with NO fabricated number", function()
  local LP = load()
  h.state.questLog = { quest(201, "Speak to Kekek", 2100, { { text = "Speak with Elder Kekek" } }) }
  LP.Quests:Scan()
  local minutes, tier, reason = LP.Quests:EstimateMinutes(201)
  h.eq(minutes, nil, "no minutes")
  h.eq(tier, "unmeasurable", "tier")
  h.eq(reason, "no countable objective", "reason given")
end)

h.run("a countable quest with no observed progress is unmeasurable", function()
  local LP = load()
  h.state.questLog = { quest(101, "Kill Ghouls", 1000, { { text = "Ghoul slain: 0/10" } }) }
  LP.Quests:Scan()
  local minutes, tier = LP.Quests:EstimateMinutes(101)
  h.eq(minutes, nil, "cannot time what we have not watched")
  h.eq(tier, "unmeasurable", "tier")
end)

h.run("a complete quest needs no more effort", function()
  local LP = load()
  h.state.questLog = { quest(301, "Report to Yaala", 9800, {}, true) }
  LP.Quests:Scan()
  local minutes, tier = LP.Quests:EstimateMinutes(301)
  h.eq(minutes, 0, "zero remaining")
  h.eq(tier, "measured", "known")
end)

-- ==== effective XP ====

h.run("effective XP applies the learned server rate", function()
  local LP = load()
  h.state.questLog = { quest(101, "A", 4200, { { text = "X: 0/5" } }) }
  LP.Quests:Scan()
  for _ = 1, 5 do LP.Rates:AddQuestSample(4200, 21000, 1) end
  local eff, learning = LP.Quests:EffectiveXP(LP.Quests.cache[101])
  h.near(eff, 21000, 1, "4200 predicted becomes 21000 on a x5 server")
  h.eq(learning, false, "rate is known")
end)

h.run("effective XP flags that it is still learning", function()
  local LP = load()
  h.state.questLog = { quest(101, "A", 4200, { { text = "X: 0/5" } }) }
  LP.Quests:Scan()
  local eff, learning = LP.Quests:EffectiveXP(LP.Quests.cache[101])
  h.eq(learning, true, "flagged")
  h.near(eff, 4200, 1, "falls back to the raw client value")
end)

h.run("effective XP applies the heirloom bonus the client omits", function()
  local LP = load()
  h.state.gear = { [3] = 42949, [5] = 48677 }   -- two +10% heirlooms
  LP.Modifiers:Refresh()
  h.state.questLog = { quest(101, "A", 1000, { { text = "X: 0/5" } }) }
  LP.Quests:Scan()
  for _ = 1, 5 do LP.Rates:AddQuestSample(1000, 1000, 1) end
  local eff = LP.Quests:EffectiveXP(LP.Quests.cache[101])
  h.near(eff, 1210, 1, "1.10 * 1.10 compounding")
end)

-- ==== ranking ====

h.run("ranking splits ready, worth and slower", function()
  local LP = load()
  h.state.questLog = {
    quest(301, "Report to Yaala", 9800, {}, true),
    quest(101, "Fast quest", 12600, { { text = "Ghoul slain: 0/10" } }),
    quest(201, "Speak to Kekek", 2100, { { text = "Speak with Elder Kekek" } }),
  }
  LP.Quests:Scan()
  for i = 1, 3 do
    h.advance(10)
    h.state.questLog[2].objectives[1].text = "Ghoul slain: " .. i .. "/10"
    LP.Quests:Scan()
  end
  local r = LP.Quests:Rank(100)   -- grinding at 100 xp/min
  h.eq(#r.ready, 1, "one ready to turn in")
  h.eq(r.ready[1].questID, 301, "the complete one")
  h.eq(#r.worth, 1, "one worth doing")
  h.eq(r.worth[1].questID, 101, "the fast one")
  h.eq(#r.slower, 1, "the untimeable one is not promoted")
  h.eq(r.slower[1].questID, 201, "speak-to quest")
  h.eq(r.slower[1].xpPerMin, nil, "and it gets NO fabricated rate")
end)

h.run("a slow quest ranks below grinding", function()
  local LP = load()
  h.state.questLog = { quest(101, "Slow quest", 100, { { text = "Ghoul slain: 0/100" } }) }
  LP.Quests:Scan()
  for i = 1, 3 do
    h.advance(60)
    h.state.questLog[1].objectives[1].text = "Ghoul slain: " .. i .. "/100"
    LP.Quests:Scan()
  end
  local r = LP.Quests:Rank(1000000)
  h.eq(#r.worth, 0, "nothing beats a huge grind rate")
  h.eq(#r.slower, 1, "it lands in slower")
end)

h.run("worth bucket is sorted best first", function()
  local LP = load()
  h.state.questLog = {
    quest(101, "Low", 1000, { { text = "A slain: 0/10" } }),
    quest(102, "High", 50000, { { text = "B slain: 0/10" } }),
  }
  LP.Quests:Scan()
  for i = 1, 3 do
    h.advance(10)
    h.state.questLog[1].objectives[1].text = "A slain: " .. i .. "/10"
    h.state.questLog[2].objectives[1].text = "B slain: " .. i .. "/10"
    LP.Quests:Scan()
  end
  local r = LP.Quests:Rank(1)
  h.eq(r.worth[1].questID, 102, "the 50k quest ranks first")
end)

h.run("empty log ranks cleanly", function()
  local LP = load()
  h.state.questLog = {}
  LP.Quests:Scan()
  local r = LP.Quests:Rank(100)
  h.eq(#r.ready, 0, "none"); h.eq(#r.worth, 0, "none"); h.eq(#r.slower, 0, "none")
end)

-- Rested doubles kill XP but does NOT apply to quest XP, so the grind
-- baseline must reflect that or quests look better than they are.
h.run("grind baseline doubles while rested", function()
  local LP = load()
  LP.Estimator:Update({ xp = 0, xpMax = 100000, baseRateSamples = { 10 }, observedFraction = 1 })
  h.state.rested = nil
  local plain = LP.Quests:GrindBaseline()
  h.near(plain, 600, 1, "10/s is 600/min")
  h.state.rested = 50000
  local rested, isRested = LP.Quests:GrindBaseline()
  h.near(rested, 1200, 1, "doubled while the pool lasts")
  h.eq(isRested, true, "flagged so the UI can say why")
end)

h.run("grind baseline is nil before any rate is measured", function()
  local LP = load()
  LP.Estimator:Update({ xp = 0, xpMax = 100000, baseRateSamples = {}, observedFraction = 0 })
  h.eq(LP.Quests:GrindBaseline(), nil, "unknown, not zero")
end)


-- ==== exact rate calibration ====

h.run("Calibrate reads the server rate from the two disagreeing APIs", function()
  local LP = load()
  h.state.questLog = { quest(101, "Kill Ghouls", 4200, { { text = "Ghoul slain: 10/10" } }, true) }
  LP.Quests:Scan()
  h.state.questGiverTitle = "Kill Ghouls"
  h.state.rewardXP = 21000            -- server value: 4200 x5
  local questID, blizz, rated = LP.Quests:Calibrate()
  h.eq(questID, 101, "matched the quest by title")
  h.eq(blizz, 4200, "blizzlike value from the log")
  h.eq(rated, 21000, "server value from GetRewardXP")
  h.near(LP.Rates:GetQuestRate(), 5.0, 0.001, "x5 learned from ONE reward panel")
end)

h.run("an ambiguous title match refuses to calibrate", function()
  local LP = load()
  h.state.questLog = {
    quest(101, "Kill Ghouls", 4200, { { text = "A: 0/1" } }),
    quest(102, "Kill Ghouls", 9999, { { text = "B: 0/1" } }),
  }
  LP.Quests:Scan()
  h.state.questGiverTitle = "Kill Ghouls"
  h.state.rewardXP = 21000
  h.eq(LP.Quests:Calibrate(), nil, "two quests share the title -- refuse rather than guess")
  h.eq(LP.Rates:GetQuestRate(), nil, "no poisoned sample")
end)

h.run("an unmatched title does not calibrate", function()
  local LP = load()
  h.state.questLog = { quest(101, "Kill Ghouls", 4200, { { text = "A: 0/1" } }) }
  LP.Quests:Scan()
  h.state.questGiverTitle = "Some Other Quest"
  h.state.rewardXP = 21000
  h.eq(LP.Quests:Calibrate(), nil, "no match")
  h.eq(LP.Rates:GetQuestRate(), nil, "no sample")
end)

-- REGRESSION: feeding GetRewardXP() into the observation learner compares the
-- server value against itself and always yields x1 -- a x5 server would be
-- reported as blizzlike.
h.run("the fallback learner is fed the BLIZZLIKE xp, never GetRewardXP", function()
  local LP = load()
  h.state.questLog = { quest(101, "Kill Ghouls", 4200, { { text = "A: 1/1" } }, true) }
  LP.Quests:Scan()
  h.state.questGiverTitle = "Kill Ghouls"
  h.state.rewardXP = 21000
  LP.Quests:Calibrate()
  LP.Quests.pendingBlizzXP = 4200
  -- simulate the turn-in: the ledger is armed with the blizzlike value
  LP.Ledger:NoteQuestFinished(101, LP.Quests.pendingBlizzXP)
  LP.Ledger:OnChat("You gain 21000 experience.")
  local samples = LP.Rates.questSamples
  h.eq(#samples, 1, "one fallback sample")
  h.near(samples[1], 5.0, 0.001, "21000 / 4200 = x5, NOT 21000 / 21000 = x1")
end)

os.exit(h.report() and 0 or 1)
