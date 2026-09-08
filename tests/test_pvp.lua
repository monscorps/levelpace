package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function tocFiles()
  local f = {}
  for line in io.lines("LevelPace/LevelPace.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then
      f[#f + 1] = "LevelPace/" .. line:gsub("\\", "/")
    end
  end
  return f
end

local function boot()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.state.level, h.state.xpMax = 19, 100000
  h.state.playerGUID = "0xME"
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")
  return LP
end

-- 3.3.5a flags
local F_PLAYER = 0x00000400 + 0x00000100   -- TYPE_PLAYER | CONTROL_PLAYER
local F_NPC    = 0x00000800 + 0x00000200   -- TYPE_NPC | CONTROL_NPC
local F_PET    = 0x00001000 + 0x00000100   -- TYPE_PET | CONTROL_PLAYER

-- ==== kill counters ====

h.run("lifetime kills reads only the FIRST return", function()
  local LP = boot()
  h.state.lifetimeHK = 1234
  h.state.highestRank = 7     -- would be mistaken for kills by a 3-value read
  h.eq(LP.PvP:LifetimeKills(), 1234, "hk, not rank")
end)

h.run("today and yesterday counters", function()
  local LP = boot()
  h.state.todayHK, h.state.yesterdayHK = 12, 40
  h.eq(LP.PvP:TodayKills(), 12, "today")
  h.eq(LP.PvP:YesterdayKills(), 40, "yesterday")
end)

-- ==== the weekly window ====

h.run("week start lands on the configured reset weekday", function()
  local LP = boot()
  -- 2026-09-08 is a Tuesday. Reset weekday 4 = Wednesday, so the current
  -- week began the PREVIOUS Wednesday.
  local now = 1757318400   -- 2026-09-08 08:00 UTC-ish
  local start = LP.PvP:WeekStart(now, 4, 0)
  h.ok(start <= now, "start is in the past")
  h.ok(now - start < 7 * 86400, "and within the last seven days")
  local t = os.date("*t", start)
  h.eq(t.wday, 4, "lands on a Wednesday")
end)

h.run("a different reset day gives a different week", function()
  local LP = boot()
  local now = 1757318400
  h.ok(LP.PvP:WeekStart(now, 4, 0) ~= LP.PvP:WeekStart(now, 1, 0),
       "Wednesday reset and Sunday reset are not the same window")
end)

-- NOTE on ordering: boot() fires PLAYER_READY, which anchors the week
-- immediately -- exactly as it does in game, where GetPVPLifetimeStats is
-- already populated at login. So the kill count has to be set BEFORE boot(),
-- or the anchor lands on zero and every existing kill counts as "this week".

-- The first run cannot know how many existing kills happened this week.
h.run("first run starts weekly at zero, not a whole career", function()
  h.state.lifetimeHK = 5000
  local LP = boot()
  h.eq(LP.PvP:WeeklyKills(), 0, "5000 lifetime kills do not become this week's")
end)

h.run("weekly counts kills since the anchor", function()
  h.state.lifetimeHK = 5000
  local LP = boot()
  h.state.lifetimeHK = 5042
  LP.PvP:UpdateWeek()
  h.eq(LP.PvP:WeeklyKills(), 42, "42 kills since the anchor")
end)

h.run("lifetime going backwards re-anchors instead of going negative", function()
  h.state.lifetimeHK = 5000
  local LP = boot()
  h.state.lifetimeHK = 10          -- transfer, rollback, or another character
  LP.PvP:UpdateWeek()
  h.eq(LP.PvP:WeeklyKills(), 0, "never negative")
end)

-- ==== item level ====

h.run("item level averages the equipped slots", function()
  local LP = boot()
  h.state.items = {}
  for _, s in ipairs({ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }) do
    h.state.items[s] = { ilvl = 200, quality = 3 }
  end
  local avg, counted, heirlooms, missing = LP.PvP:ScanItemLevel()
  h.eq(avg, 200, "average")
  h.eq(counted, 17, "all slots counted")
  h.eq(heirlooms, 0, "no heirlooms")
  h.eq(missing, 0, "nothing missing")
end)

-- The trap that matters most for a TWINK board specifically.
h.run("heirlooms are excluded, not averaged in as item level 1", function()
  local LP = boot()
  h.state.items = {
    [1] = { ilvl = 200, quality = 3 },
    [5] = { ilvl = 1, quality = 7 },      -- heirloom chest reports ilvl 1
    [3] = { ilvl = 1, quality = 7 },      -- heirloom shoulders
  }
  local avg, counted, heirlooms = LP.PvP:ScanItemLevel()
  h.eq(avg, 200, "the real item is the average, not (200+1+1)/3 = 67")
  h.eq(counted, 1, "one real item counted")
  h.eq(heirlooms, 2, "two heirlooms reported separately")
end)

-- No GET_ITEM_INFO_RECEIVED on 3.3.5a, so a cold cache must not publish.
h.run("a cold item cache yields nil, never a wrong average", function()
  local LP = boot()
  h.state.items = {
    [1] = { ilvl = 200, quality = 3 },
    [5] = { ilvl = false, quality = 3 },   -- not cached yet
  }
  local avg, counted, _, missing = LP.PvP:ScanItemLevel()
  h.eq(avg, nil, "no number while a slot is unknown")
  h.eq(missing, 1, "and it says how many are missing")
  h.eq(counted, 1, "counted so far")
end)

h.run("naked character reports nil, not zero", function()
  local LP = boot()
  h.state.items = {}
  h.eq(LP.PvP:ScanItemLevel(), nil, "nothing equipped is not an item level of 0")
end)

h.run("shirt, tabard and ammo are excluded", function()
  local LP = boot()
  h.state.items = {
    [1] = { ilvl = 200, quality = 3 },
    [4] = { ilvl = 1, quality = 1 },    -- shirt
    [19] = { ilvl = 1, quality = 1 },   -- tabard
    [0] = { ilvl = 1, quality = 1 },    -- ammo
  }
  local avg, counted = LP.PvP:ScanItemLevel()
  h.eq(avg, 200, "shirt/tabard/ammo do not drag the average down")
  h.eq(counted, 1, "only the real slot counted")
end)

-- ==== nemesis ====

h.run("a player killing you is recorded", function()
  local LP = boot()
  LP.PvP:NoteDamage("0xENEMY", "Gankzor", F_PLAYER, 100)
  LP.PvP:NoteDeath(101)
  local top = LP.PvP:TopNemesis(3)
  h.eq(#top, 1, "one nemesis")
  h.eq(top[1].name, "Gankzor", "named")
  h.eq(top[1].count, 1, "counted once")
  h.eq(LP.PvP:Store().deaths, 1, "a PvP death")
end)

h.run("an NPC killing you is not a PvP death", function()
  local LP = boot()
  LP.PvP:NoteDamage("0xMOB", "Ravenous Ghoul", F_NPC, 100)
  LP.PvP:NoteDeath(101)
  h.eq(#LP.PvP:TopNemesis(3), 0, "mobs are not nemeses")
  h.eq(LP.PvP:Store().deaths, 0, "and not a PvP death")
end)

h.run("a pet is not treated as a player", function()
  local LP = boot()
  LP.PvP:NoteDamage("0xPET", "Felguard", F_PET, 100)
  LP.PvP:NoteDeath(101)
  h.eq(#LP.PvP:TopNemesis(3), 0, "CONTROL_PLAYER alone is not enough")
end)

h.run("dying long after the last player damage is not attributed", function()
  local LP = boot()
  LP.PvP:NoteDamage("0xENEMY", "Gankzor", F_PLAYER, 100)
  LP.PvP:NoteDeath(200)            -- 100s later: fell off a cliff
  h.eq(#LP.PvP:TopNemesis(3), 0, "no blame outside the window")
  h.eq(LP.PvP:Store().deaths, 0, "and not counted as a PvP death")
end)

h.run("repeat killers rise to the top", function()
  local LP = boot()
  for i = 1, 5 do
    LP.PvP:NoteDamage("0xA", "Gankzor", F_PLAYER, i * 100)
    LP.PvP:NoteDeath(i * 100 + 1)
  end
  for i = 1, 2 do
    LP.PvP:NoteDamage("0xB", "Shadowstep", F_PLAYER, 1000 + i * 100)
    LP.PvP:NoteDeath(1000 + i * 100 + 1)
  end
  local top = LP.PvP:TopNemesis(3)
  h.eq(top[1].name, "Gankzor", "most kills first")
  h.eq(top[1].count, 5, "five")
  h.eq(top[2].name, "Shadowstep", "then the next")
  h.eq(LP.PvP:Store().deaths, 7, "seven PvP deaths")
end)

h.run("nemesis is keyed on GUID, so a renamed attacker is one entry", function()
  local LP = boot()
  LP.PvP:NoteDamage("0xA", nil, F_PLAYER, 100)      -- name not cached yet
  LP.PvP:NoteDeath(101)
  LP.PvP:NoteDamage("0xA", "Gankzor", F_PLAYER, 200)
  LP.PvP:NoteDeath(201)
  local top = LP.PvP:TopNemesis(3)
  h.eq(#top, 1, "one attacker, not two")
  h.eq(top[1].count, 2, "both deaths counted")
  h.eq(top[1].name, "Gankzor", "and the name filled in when it arrived")
end)

h.run("a death is attributed once, not to every later death", function()
  local LP = boot()
  LP.PvP:NoteDamage("0xA", "Gankzor", F_PLAYER, 100)
  LP.PvP:NoteDeath(101)
  LP.PvP:NoteDeath(102)          -- second death, no new damage
  h.eq(LP.PvP:TopNemesis(3)[1].count, 1, "the attacker is not blamed twice")
end)

-- ==== payload ====

h.run("payload carries the fields the board needs", function()
  h.state.lifetimeHK = 2400
  local LP = boot()
  h.state.lifetimeHK = 2580
  LP.PvP:UpdateWeek()
  h.state.items = { [1] = { ilvl = 40, quality = 3 } }
  LP.PvP:RefreshItemLevel()
  LP.PvP:NoteDamage("0xA", "Gankzor", F_PLAYER, 100)
  LP.PvP:NoteDeath(101)

  local p = LP.PvP:Payload()
  h.eq(p.weeklyKills, 180, "weekly")
  h.eq(p.lifetimeKills, 2580, "lifetime")
  h.eq(p.deaths, 1, "deaths")
  h.eq(p.itemLevel, 40, "item level")
  h.eq(p.bracket, 19, "level 19 is the 19 bracket")
  h.eq(#p.nemesis, 1, "nemesis list")
  h.eq(p.nemesis[1].name, "Gankzor", "named")
  -- The board must be able to say these are guesses.
  h.eq(p.approx.nemesis, true, "nemesis flagged approximate")
  h.eq(p.approx.weeklyKills, true, "weekly flagged approximate")
end)

h.run("brackets", function()
  local LP = boot()
  for lvl, want in pairs({ [19] = 19, [24] = 29, [39] = 39, [70] = 79, [80] = 80 }) do
    h.state.level = lvl
    h.eq(LP.PvP:Bracket(), want, "level " .. lvl)
  end
end)

-- ==== consent ====

h.run("PvP data is NOT exported without its own opt-in", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  LP.db.profile.share.sharePvP = false
  h.state.lifetimeHK = 100
  LP.PvP:UpdateWeek()
  LP.Export:Write()
  local blob = LP.gdb.export[next(LP.gdb.export)]
  h.eq(blob.pvp, nil, "levelling stats shared, PvP withheld")
end)

h.run("PvP data is exported once separately opted in", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  LP.db.profile.share.sharePvP = true
  h.state.lifetimeHK = 100
  LP.PvP:UpdateWeek()
  LP.Export:Write()
  local blob = LP.gdb.export[next(LP.gdb.export)]
  h.ok(blob.pvp, "pvp block present")
  h.eq(blob.pvp.lifetimeKills, 100, "with data")
end)

os.exit(h.report() and 0 or 1)
