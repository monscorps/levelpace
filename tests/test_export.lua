package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function tocFiles()
  local f = {}
  for line in io.lines("LevelPace/LevelPace.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then f[#f+1] = "LevelPace/" .. line:gsub("\\","/") end
  end
  return f
end
local function boot()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.state.level, h.state.xpMax = 71, 100000
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")
  return LP
end

h.run("JSON encodes the basic types", function()
  local J = boot().Export.ToJSON
  h.eq(J(nil), "null", "nil")
  h.eq(J(true), "true", "true")
  h.eq(J(42), "42", "integer stays integral")
  h.eq(J(1.5), "1.5000", "float")
  h.eq(J("hi"), '"hi"', "string")
  h.eq(J({1,2,3}), "[1,2,3]", "array")
  h.eq(J({b=1, a=2}), '{"a":2,"b":1}', "object with sorted keys")
end)

h.run("JSON escapes what would break a parser", function()
  local J = boot().Export.ToJSON
  h.eq(J('say "hi"'), '"say \\"hi\\""', "quotes")
  h.eq(J("back\\slash"), '"back\\\\slash"', "backslash")
  h.eq(J("line\nbreak"), '"line\\nbreak"', "newline")
  h.eq(J("tab\there"), '"tab\\there"', "tab")
end)

h.run("infinity and NaN become null, never invalid JSON", function()
  local J = boot().Export.ToJSON
  h.eq(J(math.huge), "null", "inf")
  h.eq(J(-math.huge), "null", "-inf")
  h.eq(J(0/0), "null", "nan")
end)

h.run("nothing is exported while sharing is off", function()
  local LP = boot()
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 500 experience.")
  LP.History:OnLevelUp(72)
  LP.Export:Write()
  h.eq(LP.gdb.exportJSON, nil, "no JSON written")
  h.eq(next(LP.gdb.export or {}), nil, "no table written either")
end)

h.run("enabling sharing produces a JSON payload", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 500 experience.")
  h.advance(50)
  LP.History:OnLevelUp(72)
  LP.Export:Write()
  local js = LP.gdb.exportJSON
  h.ok(js and #js > 0, "JSON written")
  h.ok(js:find('"display":"Tester"', 1, true), "carries the display name")
  h.ok(js:find('"level":71', 1, true), "carries the completed level")
  h.ok(js:sub(1,1) == "[", "top level is an array of characters")
end)

-- The JSON must be extractable with a regex, not a Lua parser -- that is the
-- entire point of it existing.
h.run("payload round-trips through a real JSON parser", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 500 experience.")
  h.advance(50)
  LP.History:OnLevelUp(72)
  LP.Export:Write()
  local f = io.open("/tmp/lp_export_test.json", "w")
  f:write(LP.gdb.exportJSON); f:close()
  local ok = os.execute("python3 -c \"import json;d=json.load(open('/tmp/lp_export_test.json'));assert isinstance(d,list) and d[0]['levels'][0]['level']==71\" 2>/dev/null")
  h.ok(ok == 0 or ok == true, "python json.load accepts it and the data is right")
end)

h.run("opting out clears what was already written", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 500 experience.")
  LP.History:OnLevelUp(72)
  LP.Export:Write()
  h.ok(LP.gdb.exportJSON, "written")
  LP.db.profile.share.enabled = false
  LP.Export:Write()
  h.eq(LP.gdb.exportJSON, nil, "and removed on opt-out, not merely stale")
end)

-- ==== schema 2 identity fields ====

h.run("name and realm are always sent, whatever the privacy setting", function()
  local LP = boot()
  h.state.playerName = "Thrall"
  LP.db.profile.share.enabled = true

  LP.db.profile.share.shareRealm = true
  local blob = LP.Export:Write()
  h.eq(blob.name, "Thrall", "name present")
  h.ok(blob.realm, "realm present")
  h.eq(blob.showRealm, true, "shown")

  -- The toggle controls DISPLAY, not transmission: the server needs realm to
  -- tell two same-named characters apart, and without it their identity key
  -- is underivable and their collision protection disappears.
  LP.db.profile.share.shareRealm = false
  blob = LP.Export:Write()
  h.eq(blob.name, "Thrall", "name still sent")
  h.ok(blob.realm, "realm STILL sent")
  h.eq(blob.showRealm, false, "but flagged not to display")
end)

h.run("display is presentation only and never replaces name", function()
  local LP = boot()
  h.state.playerName = "Thrall"
  LP.db.profile.share.enabled = true
  LP.db.profile.share.alias = "Warchief"
  local blob = LP.Export:Write()
  h.eq(blob.display, "Warchief", "alias is the display name")
  h.eq(blob.name, "Thrall", "identity is untouched by the alias")
end)

h.run("the blob declares schema 2", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  h.eq(LP.Export:Write().schema, 2, "schema bumped for the identity fields")
end)

-- ==== the silent dead-end ====
--
-- A player levelled an entire character with the addon and the companion both
-- running, and nothing ever reached the board: sharing is off by default and
-- nothing said so. The companion cannot help -- with sharing off there is no
-- blob, so it has nothing to send and never even contacts the server. This is
-- the only place that knows.

h.run("says something when there is finished work and sharing is off", function()
  local LP = boot()
  LP.db.profile.share.enabled = false
  LP.db.history = { { level = 70, elapsed = 5400 }, { level = 71, elapsed = 6000 } }
  local said = {}
  LP.Print = function(_, msg) said[#said + 1] = tostring(msg) end
  h.eq(LP.Export:NudgeIfIdle(), true, "nudged")
  h.ok(#said >= 1, "printed something")
  h.ok(string.find(said[1], "2 completed"), "names how much is waiting")
  h.ok(string.find(said[2] or "", "share on"), "gives the exact command")
end)

h.run("stays quiet when sharing is already on", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  LP.db.history = { { level = 70, elapsed = 5400 } }
  local said = 0
  LP.Print = function() said = said + 1 end
  h.eq(LP.Export:NudgeIfIdle(), false, "no nudge")
  h.eq(said, 0, "silent")
end)

h.run("stays quiet for a brand new character with nothing to share", function()
  local LP = boot()
  LP.db.profile.share.enabled = false
  LP.db.history = {}
  local said = 0
  LP.Print = function() said = said + 1 end
  -- Someone who has not finished a level yet is not missing out on anything,
  -- and telling them about a switch they do not need is just noise.
  h.eq(LP.Export:NudgeIfIdle(), false, "no nudge")
  h.eq(said, 0, "silent")
end)

h.run("ignores a level with no recorded time", function()
  local LP = boot()
  LP.db.profile.share.enabled = false
  LP.db.history = { { level = 70, elapsed = 0 }, { level = 71 } }
  h.eq(LP.Export:NudgeIfIdle(), false, "nothing complete, nothing to say")
end)

-- ==== sharing follows the account, not the character ====

h.run("sharing survives onto a brand-new character", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  LP.db.profile.share.sharePvP = true

  -- A new alt: the character file is fresh, the account file persists. This
  -- is exactly a player rolling a level 1 after ticking sharing on their
  -- main -- the case that used to reset silently to off.
  _G.LevelPaceCharDB = nil
  LP:InitDB()
  h.eq(LP.db.profile.share.enabled, true, "still on for the alt")
  h.eq(LP.db.profile.share.sharePvP, true, "pvp choice carries too")
end)

h.run("turning sharing off on an alt turns it off everywhere", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  _G.LevelPaceCharDB = nil
  LP:InitDB()
  LP.db.profile.share.enabled = false
  _G.LevelPaceCharDB = nil
  LP:InitDB()
  h.eq(LP.db.profile.share.enabled, false, "one switch, one meaning")
end)

h.run("an existing character's old choice migrates to the account", function()
  local LP = boot()
  -- Simulate a pre-change character file that carried its own share table,
  -- with no account-level share yet.
  _G.LevelPaceDB.share = nil
  _G.LevelPaceCharDB.profile.share = { enabled = true, alias = "", shareRealm = true,
    shareClass = true, shareFaction = true, sharePvP = false }
  LP:InitDB()
  h.eq(LP.gdb.share.enabled, true, "donated to the account")
  h.eq(LP.db.profile.share, LP.gdb.share, "and re-linked to one table")
end)

h.run("the nudge fires when the first level completes, and only once", function()
  local LP = boot()
  LP.db.profile.share.enabled = false
  LP.db.history = {}
  local said = 0
  LP.Print = function() said = said + 1 end

  LP:Fire("LEVEL_CHANGED", 2)
  h.eq(said, 0, "nothing finished yet, nothing to say")

  LP.db.history = { { level = 1, elapsed = 240 } }
  LP:Fire("LEVEL_CHANGED", 2)
  h.ok(said >= 1, "spoke up at the first completed level")

  local after = said
  LP:Fire("LEVEL_CHANGED", 3)
  LP:Fire("LEVEL_CHANGED", 4)
  h.eq(said, after, "and never again this session -- a ding is not a nag slot")
end)

-- ==== a crashing optional field must not sink the whole blob ====
--
-- Two real players on the same private server got 'sharing on but no blob'.
-- The blob was one table constructor; an optional call (a module payload, or
-- UnitClass on an odd client) threw, and the entire export was lost -- while
-- enabled=true persisted, so it looked on and uploaded nothing, silently,
-- because SHARE_CHANGED handlers are pcall'd by the bus.

h.run("levels still upload when an optional enrichment throws", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  LP.db.history = { { level = 7, elapsed = 300, xpBySource = { kill = 800 } } }

  -- Break two optional paths the way a private-server client might.
  LP.RareFinder.Payload = function() error("boom") end
  _G.UnitClass = function() error("boom") end

  LP.Export:Write()
  h.ok(LP.gdb.exportJSON ~= nil, "the blob was written anyway")
  h.ok(LP.gdb.exportJSON:find('"levels"'), "levels survived")
  h.ok(LP.gdb.exportFailures ~= nil, "what failed was recorded")
  h.ok(LP.gdb.exportFailures:find("rares"), "rares named")
  h.ok(LP.gdb.exportFailures:find("class"), "class named")
end)

h.run("a clean client records no failures", function()
  local LP = boot()
  LP.db.profile.share.enabled = true
  LP.db.history = { { level = 7, elapsed = 300 } }
  LP.Export:Write()
  h.eq(LP.gdb.exportFailures, nil, "nothing degraded")
end)

os.exit(h.report() and 0 or 1)
