package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Modules/Nemesis.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  LP:SetModuleEnabled("nemesis", true)
  return LP, LP.Nemesis
end

-- Alliance player, so enemies are Horde (faction 0).
local function board(...)
  local rows = {}
  for _, r in ipairs({ ... }) do rows[#rows + 1] = r end
  h.state.faction = "Alliance"
  h.state.bgScores = rows
end

local function horde(name, extra)
  local r = { name = name, faction = 0 }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

local function ally(name)
  return { name = name, faction = 1 }
end

-- ==== roster ====

h.run("scans only enemy players", function()
  local LP, N = load()
  board(horde("Gank"), ally("Friend"), horde("Stab"))
  local enemies = N:ScanEnemies()
  h.ok(enemies.Gank, "enemy 1")
  h.ok(enemies.Stab, "enemy 2")
  h.eq(enemies.Friend, nil, "own faction excluded")
end)

h.run("a Horde player sees Alliance as the enemy", function()
  local LP, N = load()
  h.state.faction = "Horde"
  h.state.bgScores = { horde("Mate"), ally("Target") }
  local enemies = N:ScanEnemies()
  h.ok(enemies.Target, "alliance is the enemy")
  h.eq(enemies.Mate, nil, "horde is not")
end)

h.run("detects an enemy joining", function()
  local LP, N = load()
  board(horde("Gank"))
  N:PollRoster()
  board(horde("Gank"), horde("Newcomer"))
  local joined, left = N:PollRoster()
  h.eq(#joined, 1, "one joined")
  h.eq(joined[1], "Newcomer", "the new one")
  h.eq(#left, 0, "nobody left")
end)

h.run("an enemy must be missing twice before counting as left", function()
  local LP, N = load()
  board(horde("Gank"), horde("Stab"))
  N:PollRoster()
  board(horde("Gank"))
  local _, left1 = N:PollRoster()
  h.eq(#left1, 0, "one miss is not a departure -- scoreboards flicker")
  local _, left2 = N:PollRoster()
  h.eq(#left2, 1, "two consecutive misses is")
  h.eq(left2[1], "Stab", "the right player")
end)

h.run("a player who reappears between polls never counts as left", function()
  local LP, N = load()
  board(horde("Gank"), horde("Stab"))
  N:PollRoster()
  board(horde("Gank"))
  N:PollRoster()
  board(horde("Gank"), horde("Stab"))
  local joined, left = N:PollRoster()
  h.eq(#left, 0, "no departure")
  h.eq(#joined, 0, "and not a re-join either")
end)

h.run("the first poll reports everyone as joined", function()
  local LP, N = load()
  board(horde("A"), horde("B"))
  local joined = N:PollRoster()
  h.eq(#joined, 2, "both")
end)

-- ==== nemesis ====

h.run("tracks kills and deaths per enemy", function()
  local LP, N = load()
  N:RecordDeath("Gank")
  N:RecordDeath("Gank")
  N:RecordKill("Gank")
  local r = N:Record("Gank")
  h.eq(r.deaths, 2, "died twice to them")
  h.eq(r.kills, 1, "killed them once")
end)

h.run("a nemesis is someone who kills you more than you kill them", function()
  local LP, N = load()
  N:RecordDeath("Bully"); N:RecordDeath("Bully"); N:RecordDeath("Bully")
  N:RecordKill("Victim");  N:RecordKill("Victim")
  h.eq(N:IsNemesis("Bully"), true, "kills you more -- nemesis")
  h.eq(N:IsNemesis("Victim"), false, "you kill them more -- not a nemesis")
  h.eq(N:IsNemesis("Stranger"), false, "never met")
end)

h.run("top nemeses are ranked by net deaths", function()
  local LP, N = load()
  for _ = 1, 5 do N:RecordDeath("Worst") end
  for _ = 1, 3 do N:RecordDeath("Middle") end
  for _ = 1, 1 do N:RecordDeath("Mild") end
  local top = N:TopNemeses(3)
  h.eq(#top, 3, "three")
  h.eq(top[1].name, "Worst", "worst first")
  h.eq(top[3].name, "Mild", "mildest last")
end)

h.run("an enemy joining who is a nemesis raises an alert", function()
  local LP, N = load()
  for _ = 1, 3 do N:RecordDeath("Bully") end
  local alerts = {}
  LP:On("NEMESIS_SPOTTED", function(name) alerts[#alerts + 1] = name end)
  board(horde("Bully"), horde("Nobody"))
  N:PollRoster()
  h.eq(#alerts, 1, "one alert")
  h.eq(alerts[1], "Bully", "for the nemesis only")
end)

-- ==== streaks ====

h.run("tracks current and longest killstreak", function()
  local LP, N = load()
  N:RecordKill("A"); N:RecordKill("B"); N:RecordKill("C")
  h.eq(N:CurrentStreak(), 3, "three in a row")
  h.eq(N:LongestStreak(), 3, "longest so far")
  N:RecordDeath("D")
  h.eq(N:CurrentStreak(), 0, "death breaks it")
  h.eq(N:LongestStreak(), 3, "longest is remembered")
  N:RecordKill("E")
  h.eq(N:CurrentStreak(), 1, "restarts")
  h.eq(N:LongestStreak(), 3, "still the record")
end)

h.run("longest streak survives across sessions but current does not", function()
  local LP, N = load()
  N:RecordKill("A"); N:RecordKill("B")
  h.eq(LP.db.nemesis.longestStreak, 2, "longest is persisted")
  -- A streak in progress is meaningless after a logout.
  N:Init()
  h.eq(N:CurrentStreak(), 0, "current resets on load")
  h.eq(N:LongestStreak(), 2, "longest does not")
end)

-- ==== guilds ====

h.run("learns an enemy guild from a unit token", function()
  local LP, N = load()
  h.state.guilds = { target = "Gank Squad" }
  h.state.unitNames = { target = "Gank" }
  N:LearnGuild("target")
  h.eq(N:GuildOf("Gank"), "Gank Squad", "learned")
  h.eq(N:GuildOf("Unknown"), nil, "not learned")
end)

h.run("guild coverage is reported honestly", function()
  local LP, N = load()
  board(horde("A"), horde("B"), horde("C"))
  N:PollRoster()
  h.state.guilds = { target = "Gank Squad" }
  h.state.unitNames = { target = "A" }
  N:LearnGuild("target")
  local known, total = N:GuildCoverage()
  h.eq(known, 1, "one known")
  h.eq(total, 3, "of three -- never shown as complete")
end)

-- ==== flags ====

h.run("parses a flag pickup from battleground chat", function()
  local LP, N = load()
  local events = {}
  LP:On("BG_FLAG", function(e) events[#events + 1] = e end)
  N:OnBGChat("The Alliance Flag was picked up by Sneaky!")
  h.eq(#events, 1, "one event")
  h.eq(events[1].action, "taken", "pickup")
  h.eq(events[1].who, "Sneaky", "carrier named")
end)

h.run("parses captures and returns", function()
  local LP, N = load()
  local events = {}
  LP:On("BG_FLAG", function(e) events[#events + 1] = e end)
  N:OnBGChat("The Horde Flag was captured by Basher!")
  N:OnBGChat("The Alliance Flag was returned to its base by Guard!")
  h.eq(events[1].action, "captured", "capture")
  h.eq(events[2].action, "returned", "return")
  h.eq(events[2].who, "Guard", "who")
end)

h.run("ignores battleground chat that is not about flags", function()
  local LP, N = load()
  local events = {}
  LP:On("BG_FLAG", function(e) events[#events + 1] = e end)
  N:OnBGChat("The Battle for Warsong Gulch begins in 1 minute.")
  N:OnBGChat("")
  h.eq(#events, 0, "nothing fired")
end)

-- ==== lifetime ====

h.run("lifetime honorable kills come from the server, unmodified", function()
  local LP, N = load()
  h.state.lifetimeHK = 4231
  local s = N:Lifetime()
  h.eq(s.honorableKills, 4231, "server truth")
  h.eq(s.honorableKillsAreLifetime, true, "flagged as genuinely lifetime")
end)

h.run("win/loss records are labelled since-install, not lifetime", function()
  local LP, N = load()
  N:RecordResult("wsg", true)
  N:RecordResult("wsg", false)
  N:RecordResult("ab", true)
  local s = N:Lifetime()
  h.eq(s.wins, 2, "two wins")
  h.eq(s.losses, 1, "one loss")
  h.eq(s.winsAreLifetime, false, "we only see matches since install and must say so")
end)

h.run("per-battleground breakdown is kept", function()
  local LP, N = load()
  N:RecordResult("wsg", true)
  N:RecordResult("wsg", true)
  N:RecordResult("ab", false)
  local s = N:Lifetime()
  h.eq(s.byBG.wsg.wins, 2, "wsg wins")
  h.eq(s.byBG.ab.losses, 1, "ab losses")
end)

-- ==== sound ====

h.run("alerts play a sound when the event is enabled", function()
  local LP, N = load()
  LP.db.nemesis.sounds.nemesis = true
  N:Alert("nemesis", "Bully is here")
  h.ok(h.state.sounds and #h.state.sounds == 1, "sound played")
end)

h.run("alerts stay silent when that event is switched off", function()
  local LP, N = load()
  LP.db.nemesis.sounds.nemesis = false
  N:Alert("nemesis", "Bully is here")
  h.eq(#(h.state.sounds or {}), 0, "no sound")
end)

-- ==== PARTY_KILL must not count mobs ====

local function partyKill(LP, dstGUID, dstName)
  LP:DispatchCombatLog(1, "PARTY_KILL", "0xSRC", "Me", 0, dstGUID, dstName, 0)
end

h.run("killing a player counts", function()
  local LP, N = load()
  partyKill(LP, "0x0000000000ABCDEF", "Squishy")
  h.eq(N:Record("Squishy").kills, 1, "counted")
  h.eq(N:CurrentStreak(), 1, "streak advanced")
end)

h.run("killing a mob does NOT count as a PvP kill", function()
  local LP, N = load()
  -- An afternoon of grinding must not inflate a battleground killstreak.
  partyKill(LP, "0xF13000020D02DD76", "Mangy Wolf")
  partyKill(LP, "0xF130007F1F000001", "Some Elite")
  h.eq(N:CurrentStreak(), 0, "streak untouched by mobs")
  h.eq(N:Record("Mangy Wolf").kills, 0, "no record created for a mob")
end)

h.run("killing a pet or a vehicle does not count either", function()
  local LP, N = load()
  partyKill(LP, "0xF140000C6D000001", "Hunter Pet")
  partyKill(LP, "0xF150000C6D000001", "A Siege Engine")
  h.eq(N:CurrentStreak(), 0, "streak untouched")
end)

h.run("a new best streak is only announced once it is worth announcing", function()
  local LP, N = load()
  LP.db.nemesis.sounds.streak = true
  h.state.sounds = {}
  N:RecordKill("A")
  N:RecordKill("B")
  h.eq(#h.state.sounds, 0, "streaks of 1 and 2 are not news on a fresh install")
  N:RecordKill("C")
  h.eq(#h.state.sounds, 1, "3 is")
end)

h.run("an alert switched off produces neither sound nor chat line", function()
  local LP, N = load()
  LP.db.nemesis.sounds.kill = false
  h.state.sounds = {}
  local printed = 0
  LP.Print = function() printed = printed + 1 end
  N:RecordKill("Squishy")
  h.eq(#h.state.sounds, 0, "silent")
  h.eq(printed, 0, "and no chat spam -- off means off")
end)

-- ==== module wiring ====

h.run("registers as a module and stops collecting when disabled", function()
  local LP, N = load()
  local m = LP:GetModule("nemesis")
  h.ok(m, "registered")
  h.eq(m.default, true, "on by default")
  LP:SetModuleEnabled("nemesis", false)
  h.eq(LP:GetModule("nemesis").enabled, false, "disabled")
end)

os.exit(h.report() and 0 or 1)
