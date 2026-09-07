package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  local LP = h.loadCore()
  h.load("LevelPace/Ledger.lua")
  return LP
end

local function capture(LP)
  local got = {}
  LP:On("XP_EVENT", function(e) got[#got + 1] = e end)
  return got
end

h.run("plain kill", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ravenous Ghoul dies, you gain 412 experience.")
  h.eq(#got, 1, "one event")
  h.eq(got[1].source, "kill", "source")
  h.eq(got[1].mobName, "Ravenous Ghoul", "mob name")
  h.eq(got[1].total, 412, "total")
  h.eq(got[1].base, 412, "base equals total when unrested")
  h.eq(got[1].rested, 0, "no rested")
  h.eq(got[1].group, 0, "no group")
end)

h.run("mob names with punctuation and apostrophes", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Kul'Tiras Marine dies, you gain 300 experience.")
  h.eq(got[1].mobName, "Kul'Tiras Marine", "apostrophe survives")
  LP.Ledger:OnChat("Dr. Weavil dies, you gain 300 experience.")
  h.eq(got[2].mobName, "Dr. Weavil", "period survives")
end)

h.run("rested kill splits base from bonus", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies, you gain 824 experience. (+412 exp Rested bonus)")
  h.eq(got[1].total, 824, "total is the full amount")
  h.eq(got[1].rested, 412, "rested bonus extracted from the FIRST %s")
  h.eq(got[1].bonusType, "Rested", "type label from the SECOND %s")
  h.eq(got[1].base, 412, "base is total minus bonus")
end)

-- Ordering regression. Even anchored, the plain EXHAUSTION1 pattern will
-- match a _GROUP message and capture bonusType as "Rested bonus, +12 group".
h.run("group variant matched by the group pattern, not the plain one", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies, you gain 500 experience. (+86 exp Rested bonus, +12 group bonus)")
  h.eq(got[1].rested, 86, "rested is 86, not mangled")
  h.eq(got[1].bonusType, "Rested", "type is clean, not 'Rested bonus, +12 group'")
  h.eq(got[1].group, 12, "group bonus extracted")
  h.eq(got[1].base, 500 - 86 - 12, "base excludes both bonuses")
end)

h.run("plain kill with only a group bonus", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies, you gain 500 experience. (+40 group bonus)")
  h.eq(got[1].group, 40, "group")
  h.eq(got[1].rested, 0, "no rested")
  h.eq(got[1].base, 460, "base")
end)

h.run("penalty variant is not treated as a bonus", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies, you gain 200 experience. (-50 exp Raid penalty)")
  h.eq(got[1].total, 200, "total")
  h.eq(got[1].rested, 0, "a penalty is not a rested bonus")
  h.eq(got[1].penalty, 50, "penalty recorded as magnitude")
  h.eq(got[1].base, 200, "base is not reduced by the penalty -- it is already applied")
end)

-- Quest and exploration XP are TEXTUALLY IDENTICAL on 3.3.5a.
h.run("unnamed gain with no context is unknown, not quest", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("You gain 9800 experience.")
  h.eq(got[1].source, "unknown", "no context means unknown")
  h.eq(got[1].mobName, nil, "no mob")
end)

h.run("unnamed gain after a quest finish is attributed", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:NoteQuestFinished(12345, 4200)
  LP.Ledger:OnChat("You gain 21000 experience.")
  h.eq(got[1].source, "quest", "attributed")
  h.eq(got[1].questID, 12345, "carries the quest id")
  h.eq(got[1].predictedXP, 4200, "carries the client prediction for rate learning")
end)

h.run("quest attribution expires after the window", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:NoteQuestFinished(12345, 4200)
  h.advance(5)
  LP.Ledger:OnChat("You gain 21000 experience.")
  h.eq(got[1].source, "unknown", "a stale arm does not attribute")
end)

h.run("an arm is consumed once, not reused", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:NoteQuestFinished(12345, 4200)
  LP.Ledger:OnChat("You gain 21000 experience.")
  LP.Ledger:OnChat("You gain 500 experience.")
  h.eq(got[1].source, "quest", "first is the quest")
  h.eq(got[2].source, "unknown", "second is not double-attributed")
end)

h.run("exploration recognised from the system message", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:HandleSystem("Discovered Howling Fjord: 975 experience gained")
  LP.Ledger:OnChat("You gain 975 experience.")
  h.eq(got[1].source, "explore", "explore, not quest or unknown")
  h.eq(got[1].zone, "Howling Fjord", "zone captured")
end)

h.run("quest system message arms quest attribution", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:HandleSystem("Experience gained: 21000.")
  LP.Ledger:OnChat("You gain 21000 experience.")
  h.eq(got[1].source, "quest", "quest even without a known id")
end)

h.run("quest turn-in carrying an RAF bonus still parses", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:NoteQuestFinished(999, 1000)
  LP.Ledger:OnChat("You gain 3000 experience. (+2000 exp Refer-A-Friend bonus)")
  h.eq(got[1].source, "quest", "source")
  h.eq(got[1].total, 3000, "total")
  h.eq(got[1].rested, 2000, "bonus amount")
  h.eq(got[1].base, 1000, "base")
end)

h.run("non-xp chat is ignored", function()
  local LP = load(); local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies.")
  LP.Ledger:OnChat("You have gained a level!")
  LP.Ledger:OnChat("Your Skinning skill has increased to 300.")
  LP.Ledger:OnChat(nil)
  h.eq(#got, 0, "no spurious events")
end)

h.run("recent buffer is bounded", function()
  local LP = load(); capture(LP)
  for i = 1, 30 do LP.Ledger:OnChat("Ghoul dies, you gain 100 experience.") end
  h.eq(#LP.Ledger.recent, 20, "bounded to 20")
end)

h.run("identical EXHAUSTION1/2 patterns are deduped", function()
  local LP = load()
  local pats = LP.Ledger:Patterns()
  local seen = {}
  for _, p in ipairs(pats) do
    h.ok(not seen[p.pattern], "no duplicate pattern: " .. p.source)
    seen[p.pattern] = true
  end
end)

h.run("a missing global string does not break the build", function()
  local LP = h.loadCore()
  _G.COMBATLOG_XPGAIN_EXHAUSTION1_GROUP = nil
  h.load("LevelPace/Ledger.lua")
  local got = capture(LP)
  LP.Ledger:OnChat("Ghoul dies, you gain 412 experience.")
  h.eq(#got, 1, "still parses what it can")
end)

os.exit(h.report() and 0 or 1)
