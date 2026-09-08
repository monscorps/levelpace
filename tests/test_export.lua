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

os.exit(h.report() and 0 or 1)
