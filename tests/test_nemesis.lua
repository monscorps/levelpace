package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Data/Icons.lua")
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

-- ==== live team ranking ====

local function team(rows)
  h.state.faction = "Alliance"
  h.state.playerName = "Me"
  local out = {}
  for _, r in ipairs(rows) do
    -- Field names match GetBattlefieldScore's returns, not our own shorthand.
    out[#out + 1] = { name = r[1], faction = 1, damageDone = r[2],
                      healingDone = r[3], killingBlows = r[4] or 0 }
  end
  -- An enemy present in the scoreboard must never enter the team population.
  out[#out + 1] = { name = "EnemyAce", faction = 0,
                    damageDone = 999999, healingDone = 999999 }
  h.state.bgScores = out
end

h.run("ranks your damage against your own team only", function()
  local LP, N = load()
  team({ { "Me", 500, 0 }, { "Mate1", 100, 0 }, { "Mate2", 300, 0 } })
  local r = N:TeamRanking()
  h.eq(r.teamSize, 3, "enemy excluded from the team")
  h.eq(r.damage.value, 500, "my damage")
  h.eq(r.damage.place, 1, "top of the team")
  h.eq(r.damage.pct, 100, "100th percentile with n-1")
  h.eq(r.damage.of, 3, "measured against 3")
end)

h.run("the n-1 divisor is used, so the top of two is 100 not 50", function()
  local LP, N = load()
  team({ { "Me", 500, 0 }, { "Mate1", 100, 0 } })
  h.eq(N:TeamRanking().damage.pct, 100, "top of two is 100")
end)

h.run("a band is attached to the ranking", function()
  local LP, N = load()
  team({ { "Me", 500, 0 }, { "Mate1", 100, 0 }, { "Mate2", 300, 0 } })
  local b = N:TeamRanking().damage.band
  h.ok(b, "band present")
  h.eq(b.id, "gold", "top of the team is a perfect parse")
end)

h.run("bottom of the team is grey, not an error", function()
  local LP, N = load()
  team({ { "Me", 10, 0 }, { "Mate1", 100, 0 }, { "Mate2", 300, 0 } })
  local d = N:TeamRanking().damage
  h.eq(d.pct, 0, "nobody below me")
  h.eq(d.place, 3, "third")
  h.eq(d.band.id, "grey", "grey band")
end)

h.run("healing is ranked only among teammates who actually healed", function()
  local LP, N = load()
  -- Three DPS at zero healing and two healers. Ranking a rogue's zero against
  -- fifteen other zeroes is a number that looks like information and is not.
  team({ { "Me", 100, 4000 }, { "Healer", 50, 8000 },
         { "Dps1", 900, 0 }, { "Dps2", 800, 0 } })
  local hl = N:TeamRanking().healing
  h.eq(hl.of, 2, "only the two who healed")
  h.eq(hl.participating, true, "I am one of them")
  h.eq(hl.pct, 0, "the lower of two healers")
end)

h.run("a player who healed nothing is not ranked as a bad healer", function()
  local LP, N = load()
  team({ { "Me", 900, 0 }, { "Healer", 50, 8000 }, { "Healer2", 60, 4000 } })
  local hl = N:TeamRanking().healing
  h.eq(hl.participating, false, "not in the healing population")
  h.eq(hl.pct, nil, "no percentile -- and so no misleading band")
  h.eq(hl.band, nil, "no band")
end)

h.run("outside a battleground there is no ranking", function()
  local LP, N = load()
  h.state.bgScores = {}
  h.eq(N:TeamRanking(), nil, "nil rather than a fake zero")
end)

h.run("a solo scoreboard gives no percentile", function()
  local LP, N = load()
  team({ { "Me", 500, 0 } })
  local d = N:TeamRanking().damage
  h.eq(d.pct, nil, "a population of one has nothing to compare against")
  h.eq(d.band, nil, "and therefore no band")
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

-- ==== bands and icons ====

h.run("bands cover the whole range in the right order", function()
  local LP = load()
  local d = LP.data
  h.eq(#d.BANDS, 7, "five item qualities plus WCL's pink and gold")
  h.eq(d.BandFor(0).id,   "grey",   "bottom")
  h.eq(d.BandFor(24).id,  "grey",   "just below uncommon")
  h.eq(d.BandFor(25).id,  "green",  "uncommon starts at 25")
  h.eq(d.BandFor(60).id,  "blue",   "rare")
  h.eq(d.BandFor(80).id,  "purple", "epic")
  h.eq(d.BandFor(96).id,  "orange", "legendary")
  h.eq(d.BandFor(99).id,  "pink",   "the WCL pink")
  h.eq(d.BandFor(100).id, "gold",   "a perfect parse")
  h.eq(d.BandFor(nil), nil, "no percentile means no band, never a default")
end)

h.run("every achievement has a real icon, not the question mark", function()
  local LP = load()
  h.load("LevelPace/PvP.lua")
  -- A new achievement added without an icon would silently ship the
  -- question-mark texture, which looks like a bug to the player and is
  -- invisible to everyone else.
  for _, a in ipairs(LP.PvP.ACHIEVEMENTS) do
    h.ok(LP.data.AchievementIcon(a.id) ~= LP.data.ICON_FALLBACK,
         a.id .. " has a mapped icon")
  end
end)

h.run("an unknown achievement id degrades to the fallback rather than nil", function()
  local LP = load()
  h.eq(LP.data.AchievementIcon("does-not-exist"), LP.data.ICON_FALLBACK,
       "SetTexture(nil) would draw nothing at all")
end)

-- ==== bugs found by the 3.3.5 API audit ====

h.run("/lp nemesis does not crash once an achievement is earned", function()
  local LP, N = load()
  h.load("LevelPace/PvP.lua")
  -- Force an earned achievement into the PvP store the way CheckAchievements does.
  LP.db.pvp = LP.db.pvp or {}
  if LP.PvP and LP.PvP.EarnedAchievements then
    LP.PvP.EarnedAchievements = function() return { { id = "firstblood", name = "First Blood", desc = "x", earned = 1 } } end
  end
  local ok, err = pcall(function() N:PrintSummary() end)
  h.eq(ok, true, "PrintSummary survives with achievements: " .. tostring(err))
end)

h.run("a death is attributed to the last player who hit you", function()
  local LP, N = load()
  h.state.playerGUID = "0x0000000000000001"
  LP:SetModuleEnabled("nemesis", false); LP:SetModuleEnabled("nemesis", true)
  -- A mob hits us: not a player, must not become the attacker.
  LP:DispatchCombatLog(1, "SWING_DAMAGE", "0xF13000020D02DD76", "Mangy Wolf", 0, "0x0000000000000001", "Me", 0)
  -- Then a player hits us.
  LP:DispatchCombatLog(2, "SPELL_DAMAGE", "0x0000000000000099", "Ganklord", 0, "0x0000000000000001", "Me", 0)
  -- Damage aimed at someone ELSE must not count.
  LP:DispatchCombatLog(3, "SPELL_DAMAGE", "0x0000000000000042", "Bystander", 0, "0x0000000000000777", "NotMe", 0)
  h.eq(N.lastAttacker, "Ganklord", "last PLAYER to hit ME")
  LP.eventFrame.scripts.OnEvent(LP.eventFrame, "PLAYER_DEAD")
  h.eq(N:Record("Ganklord").deaths, 1, "death attributed")
  h.eq(N.lastAttacker, nil, "consumed after the death")
end)

-- ==== the result must come from the game, not only from tests ====
--
-- RecordResult had no caller outside this file. A player who won a match saw
-- "0W 0L since install" forever. The winner is read the way Blizzard's own
-- scoreboard reads it (WorldStateFrame.lua:513): GetBattlefieldWinner() is
-- nil until there is a victor, then 0 for Horde and 1 for Alliance.

local function bgEvent(LP, ev)
  LP.eventFrame.scripts.OnEvent(LP.eventFrame, ev)
end

h.run("a finished match records a win for the winning faction, exactly once", function()
  h.state.bgWinner = nil
  local LP, N = load()
  h.state.zone = "Warsong Gulch"
  team({ { "Me", 500, 12000 }, { "Mate1", 100, 0 }, { "Mate2", 300, 8000 } })
  bgEvent(LP, "PLAYER_ENTERING_BATTLEGROUND")
  bgEvent(LP, "UPDATE_BATTLEFIELD_SCORE")
  local s = N:Lifetime()
  h.eq(s.wins + s.losses, 0, "nothing recorded while the match is running")

  h.state.bgWinner = 1                      -- Alliance wins; we are Alliance
  bgEvent(LP, "UPDATE_BATTLEFIELD_SCORE")
  bgEvent(LP, "UPDATE_BATTLEFIELD_SCORE")   -- the board keeps refreshing after the win
  bgEvent(LP, "UPDATE_BATTLEFIELD_SCORE")
  s = N:Lifetime()
  h.eq(s.wins, 1, "one win, not three")
  h.eq(s.losses, 0, "no loss")
  h.eq(s.byBG["Warsong Gulch"].wins, 1, "keyed by the battleground's name")
end)

h.run("the other faction's win is our loss", function()
  h.state.bgWinner = nil
  local LP, N = load()
  h.state.faction = "Horde"
  h.state.zone = "Arathi Basin"
  h.state.bgScores = { { name = "Me", faction = 0, damageDone = 10 } }
  bgEvent(LP, "PLAYER_ENTERING_BATTLEGROUND")
  h.state.bgWinner = 1
  bgEvent(LP, "UPDATE_BATTLEFIELD_SCORE")
  local s = N:Lifetime()
  h.eq(s.losses, 1, "Alliance won, we are Horde")
  h.eq(s.wins, 0, "not a win")
  h.state.faction = "Alliance"
end)

h.run("a match already over when we arrive is not counted", function()
  -- /reload on the final scoreboard, or joining late: we did not watch it.
  h.state.bgWinner = 1
  local LP, N = load()
  team({ { "Me", 500, 0 } })
  bgEvent(LP, "UPDATE_BATTLEFIELD_SCORE")
  local s = N:Lifetime()
  h.eq(s.wins + s.losses, 0, "not ours to count")
  h.state.bgWinner = nil
end)

h.run("the final standing survives leaving the battleground", function()
  h.state.bgWinner = nil
  local LP, N = load()
  h.state.zone = "Warsong Gulch"
  team({ { "Me", 500, 12000 }, { "Mate1", 100, 0 }, { "Mate2", 300, 8000 } })
  bgEvent(LP, "PLAYER_ENTERING_BATTLEGROUND")
  h.state.bgWinner = 1
  bgEvent(LP, "UPDATE_BATTLEFIELD_SCORE")

  -- Leave: the scoreboard is gone, and so is the live ranking.
  h.state.bgScores = {}
  h.eq(N:TeamRanking(), nil, "no live standing after leaving")

  local rows = N:Dashboard()
  local header, healing = nil, nil
  for _, r in ipairs(rows) do
    if r.kind == "header" and r.text:find("^Last battleground") then header = r end
    if r.kind == "meter" and r.label == "Healing" then healing = r end
  end
  h.ok(header, "a 'Last battleground' section replaces the live one")
  h.eq(header.text, "Last battleground: Warsong Gulch -- won", "names the match and the result")
  h.ok(healing, "the healing meter is still there")
  h.eq(healing.value, "12,000", "my healing")
  h.eq(healing.pct, 100, "top healer of two, n-1 percentile")
  h.eq(healing.note, "1 of 2 healers", "measured against healers only")
  h.ok(healing.band, "band recomputed for display")

  local saved = LP.db.nemesis.lastMatch
  h.eq(saved.ranking.healing.band, nil, "no colour tables in saved variables")
  h.eq(saved.won, true, "result saved")
  h.state.bgWinner = nil
end)

os.exit(h.report() and 0 or 1)
