package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Data/Rares.lua")
  h.load("LevelPace/Modules/RareFinder.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  -- Enabling the module is what wires its handlers onto the event router;
  -- Init() alone leaves it registered but deaf.
  LP:SetModuleEnabled("rarefinder", true)
  return LP, LP.RareFinder
end

-- 3.3.5a creature GUID for a given entry, with a distinct spawn counter.
local function guid(entry, spawn)
  return string.format("0xF130%06X%06X", entry, spawn or 1)
end

local function cleu(LP, subevent, dstGUID, dstName)
  LP:DispatchCombatLog(1, subevent, "0xSRC", "Me", 0, dstGUID, dstName or "X", 0)
end

-- ==== identification ====

h.run("identifies a catalogue rare", function()
  local _, RF = load()
  local r = RF:Identify(32491)
  h.ok(r, "found")
  h.eq(r.name, "Time-Lost Proto Drake", "name")
  h.eq(r.rank, 2, "rare elite")
  h.eq(r.learned, false, "from the catalogue, not learned")
end)

h.run("does not identify a normal mob", function()
  local _, RF = load()
  h.eq(RF:Identify(525), nil, "Mangy Wolf is not a rare")
  h.eq(RF:Identify(0), nil, "zero")
  h.eq(RF:Identify(nil), nil, "nil")
end)

h.run("learns a custom server rare and then identifies it", function()
  local _, RF = load()
  h.eq(RF:Identify(90001), nil, "unknown before learning")
  RF:Learn(90001, "Custom Horror", 4)
  local r = RF:Identify(90001)
  h.ok(r, "known after learning")
  h.eq(r.name, "Custom Horror", "name")
  h.eq(r.learned, true, "flagged as learned")
end)

h.run("Learn refuses ranks that are not rare or rare elite", function()
  local _, RF = load()
  RF:Learn(90002, "Just A Mob", 0)
  RF:Learn(90003, "An Elite", 1)
  RF:Learn(90004, "A Boss", 3)
  h.eq(RF:Identify(90002), nil, "normal rejected")
  h.eq(RF:Identify(90003), nil, "elite rejected")
  h.eq(RF:Identify(90004), nil, "worldboss rejected")
  RF:Learn(90005, "A Rare", 4)
  h.ok(RF:Identify(90005), "rare accepted")
end)

h.run("the catalogue always wins over a learned entry", function()
  local _, RF = load()
  RF:Learn(32491, "Impostor", 4)
  h.eq(RF:Identify(32491).name, "Time-Lost Proto Drake", "catalogue name kept")
  h.eq(RF:Identify(32491).learned, false, "not marked learned")
end)

-- ==== detection ====

h.run("PARTY_KILL on a rare records the kill as mine", function()
  local LP, RF = load()
  cleu(LP, "PARTY_KILL", guid(32491), "Time-Lost Proto Drake")
  local kills = RF:Kills()
  h.eq(#kills, 1, "one kill")
  h.eq(kills[1].npc, 32491, "entry")
  h.eq(kills[1].mine, true, "credited to me")
end)

h.run("UNIT_DIED on a rare records a witnessed kill", function()
  local LP, RF = load()
  cleu(LP, "UNIT_DIED", guid(32517), "Loque'nahak")
  local kills = RF:Kills()
  h.eq(#kills, 1, "one kill")
  h.eq(kills[1].mine, false, "not mine")
end)

h.run("PARTY_KILL then UNIT_DIED for one mob is a single kill", function()
  local LP, RF = load()
  local g = guid(32491, 77)
  cleu(LP, "PARTY_KILL", g, "Time-Lost Proto Drake")
  cleu(LP, "UNIT_DIED", g, "Time-Lost Proto Drake")
  h.eq(#RF:Kills(), 1, "deduplicated by GUID")
  h.eq(RF:Kills()[1].mine, true, "still credited to me")
end)

h.run("the same rare killed twice from different spawns counts twice", function()
  local LP, RF = load()
  cleu(LP, "PARTY_KILL", guid(32491, 1), "Time-Lost Proto Drake")
  cleu(LP, "PARTY_KILL", guid(32491, 2), "Time-Lost Proto Drake")
  h.eq(#RF:Kills(), 2, "two distinct spawns, two kills")
end)

h.run("normal mobs and non-creatures are ignored", function()
  local LP, RF = load()
  cleu(LP, "UNIT_DIED", guid(525), "Mangy Wolf")
  cleu(LP, "UNIT_DIED", "0xF140000C6D000001", "Somebody's Pet")
  cleu(LP, "UNIT_DIED", "0x0000000000ABCDEF", "A Player")
  cleu(LP, "UNIT_DIED", nil, "nothing")
  h.eq(#RF:Kills(), 0, "nothing recorded")
end)

h.run("subevents we do not care about are ignored", function()
  local LP, RF = load()
  cleu(LP, "SPELL_DAMAGE", guid(32491), "Time-Lost Proto Drake")
  h.eq(#RF:Kills(), 0, "damage is not a kill")
end)

h.run("a learned rare is detected on kill", function()
  local LP, RF = load()
  RF:Learn(90001, "Custom Horror", 4)
  cleu(LP, "PARTY_KILL", guid(90001), "Custom Horror")
  h.eq(#RF:Kills(), 1, "learned rares count")
  h.eq(RF:Kills()[1].learned, true, "flagged so the server can treat it differently")
end)

-- ==== storage ====

h.run("kills persist to the saved variables", function()
  local LP, RF = load()
  cleu(LP, "PARTY_KILL", guid(32491), "Time-Lost Proto Drake")
  h.ok(LP.db.rare, "namespace exists")
  h.eq(#LP.db.rare.kills, 1, "written through to the DB")
end)

h.run("the kill log is bounded", function()
  local LP, RF = load()
  for i = 1, RF.MAX_KILLS + 25 do
    cleu(LP, "PARTY_KILL", guid(32491, i), "Time-Lost Proto Drake")
  end
  h.eq(#RF:Kills(), RF.MAX_KILLS, "capped at MAX_KILLS")
end)

h.run("kill timestamps use wall clock, not session time", function()
  local LP, RF = load()
  cleu(LP, "PARTY_KILL", guid(32491), "Time-Lost Proto Drake")
  -- GetTime() restarts at zero every session, so a persisted GetTime() value
  -- reads as future-dated next login. This already caused a real bug.
  h.ok(RF:Kills()[1].t > 1000000000, "looks like a unix timestamp, not GetTime()")
end)

-- ==== stats ====

h.run("stats count totals, mine, and uniques", function()
  local LP, RF = load()
  cleu(LP, "PARTY_KILL", guid(32491, 1), "Time-Lost Proto Drake")
  cleu(LP, "PARTY_KILL", guid(32491, 2), "Time-Lost Proto Drake")
  cleu(LP, "UNIT_DIED",  guid(32517, 1), "Loque'nahak")
  local s = RF:Stats()
  h.eq(s.total, 3, "three kills")
  h.eq(s.mine, 2, "two mine")
  h.eq(s.unique, 2, "two distinct rares")
end)

h.run("stats on an empty log are zero, not nil", function()
  local _, RF = load()
  local s = RF:Stats()
  h.eq(s.total, 0, "total")
  h.eq(s.mine, 0, "mine")
  h.eq(s.unique, 0, "unique")
end)

-- ==== module wiring ====

h.run("registers as a module and can be disabled", function()
  local LP, RF = load()
  local m = LP:GetModule("rarefinder")
  h.ok(m, "registered")
  h.eq(m.default, true, "on by default")
  LP:SetModuleEnabled("rarefinder", true)
  cleu(LP, "PARTY_KILL", guid(32491, 1), "Time-Lost Proto Drake")
  h.eq(#RF:Kills(), 1, "collecting while enabled")
  LP:SetModuleEnabled("rarefinder", false)
  cleu(LP, "PARTY_KILL", guid(32491, 2), "Time-Lost Proto Drake")
  h.eq(#RF:Kills(), 1, "silent while disabled")
end)

os.exit(h.report() and 0 or 1)
