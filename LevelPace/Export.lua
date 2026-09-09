-- LevelPace :: Export
--
-- Writes a clean, versioned stats blob into the ACCOUNT-WIDE saved variables
-- so a companion uploader can find every character in one file.
--
-- OPT-IN. Nothing is written unless the player explicitly enables sharing.
-- The blob deliberately carries the minimum needed to rank a level: no zone
-- dwell times, no quest names, no coordinates, no group members.
--
-- Note the hard limit this lives under: SavedVariables are flushed only on
-- logout, /reload or disconnect. There is no flush API on 3.3.5a, so the
-- uploader can never be more current than the player's last clean exit.

local LP = _G.LevelPace
local util = LP.util

local Export = {}
LP.Export = Export

Export.SCHEMA = 2

-- A stable pseudonymous id, generated once and kept account-wide. It exists
-- so the server can update a character's record instead of duplicating it --
-- not to identify a person.
local function newID()
  -- NO math.randomseed. It does not exist inside WoW -- Blizzard removed it
  -- and seeds the RNG itself at startup. Calling it throws
  -- "attempt to call field 'randomseed' (a nil value)", and because this ran
  -- as the FIRST step of every export, no blob was ever written on a real
  -- client. Ever. The bus swallowed the error, so it looked like sharing was
  -- on and simply nothing happened. It stayed hidden because LuaJIT and stock
  -- Lua 5.1 -- both test environments -- DO provide randomseed; WoW is the
  -- only Lua that does not.
  --
  -- math.random is already seeded by the client. Mix in wall clock and
  -- session uptime so two characters created in the same second still get
  -- distinct keys. This id is pseudonymous and the server does not even use
  -- it for identity (char_id is derived from name@realm), so it only needs
  -- to be unique-in-practice, not cryptographic.
  local hex = "0123456789abcdef"
  local out = {}
  local rnd = math.random
  for i = 1, 24 do
    local n = rnd(1, 16)
    out[i] = string.sub(hex, n, n)
  end
  local t = math.floor((time and time() or 0) + ((GetTime and GetTime() or 0) * 1000))
  if t < 0 then t = -t end
  return table.concat(out) .. string.format("%08x", t % 0x7fffffff)
end

function Export:EnsureID()
  if not LP.gdb then return nil end
  if not LP.gdb.clientID then LP.gdb.clientID = newID() end
  return LP.gdb.clientID
end

local function charKey()
  local name = (UnitName and UnitName("player")) or "Unknown"
  local realm = (GetRealmName and GetRealmName()) or "Unknown"
  return name .. "-" .. realm, name, realm
end

-- One entry per COMPLETED level. In-progress levels are excluded: a partial
-- level has no meaningful levels-per-hour and would pollute the distribution.
local function levelRows()
  local rows = {}
  for _, r in ipairs(LP.History and LP.History:All() or {}) do
    if r.level and r.elapsed and r.elapsed > 0 then
      rows[#rows + 1] = {
        level = r.level,
        elapsed = math.floor(r.elapsed),
        kill = math.floor(r.xpBySource and r.xpBySource.kill or 0),
        quest = math.floor(r.xpBySource and r.xpBySource.quest or 0),
        explore = math.floor(r.xpBySource and r.xpBySource.explore or 0),
        unknown = math.floor(r.xpBySource and r.xpBySource.unknown or 0),
        kills = r.killCount or 0,
        quests = r.questCount or 0,
        deaths = r.deaths or 0,
        corpseRun = math.floor(r.corpseRunSeconds or 0),
        restedUsed = math.floor(r.restedConsumed or 0),
      }
    end
  end
  return rows
end

function Export:Enabled()
  return LP.db and LP.db.profile.share and LP.db.profile.share.enabled or false
end

-- Rebuilds this character's slice of the export table. Cheap; called on
-- level-up and at logout.
function Export:Write()
  if not LP.gdb then return nil end

  LP.gdb.export = LP.gdb.export or {}

  local key, name, realm = charKey()

  if not self:Enabled() then
    -- Opting out removes what was already written, rather than merely
    -- stopping new writes -- otherwise a stale blob keeps being uploaded.
    LP.gdb.export[key] = nil
    self:WriteJSON()
    return nil
  end

  local share = LP.db.profile.share

  -- Every optional field is fetched through this, so a call that errors on
  -- one client -- a private-server API that behaves differently, a module
  -- that half-loaded -- degrades that ONE field to nil instead of throwing
  -- out of the table constructor and taking the whole blob with it.
  --
  -- This is exactly the bug that stranded two real players: the whole blob
  -- was one constructor, an optional enrichment threw, and `enabled = true`
  -- persisted while `exportJSON` never got written -- sharing looked on and
  -- nothing uploaded, with no error because SHARE_CHANGED handlers are
  -- pcall'd by the bus. The core levelling data must never depend on an
  -- optional module surviving.
  local failures
  local function opt(label, fn)
    local ok, v = pcall(fn)
    if ok then return v end
    failures = (failures and (failures .. ", ") or "") .. label
    return nil
  end

  -- REQUIRED. Identity and the levelling data itself. If any of these throw,
  -- there is nothing worth uploading anyway, so this is not wrapped.
  local blob = {
    schema = self.SCHEMA,
    addon = LP.VERSION,
    -- Isolated: the server derives identity from name@realm and ignores this,
    -- so it is an enrichment, and an enrichment must never sink the blob. It
    -- already did once -- see newID.
    id = opt("id", function() return self:EnsureID() end),
    -- IDENTITY, always sent, never displayed unless asked for. The server
    -- derives char_id from name@realm, and realm cannot be optional or two
    -- players genuinely named the same lose their collision protection.
    name = name,
    realm = realm,
    showRealm = share.shareRealm ~= false,
    display = (share.alias ~= "" and share.alias) or name,
    updated = (time and time()) or 0,
    levels = opt("levels", levelRows) or {},
  }

  -- OPTIONAL enrichments, each isolated. A DK on a private server whose
  -- UnitClass or a module payload misbehaves still gets their levels on the
  -- board.
  blob.class = share.shareClass ~= false
    and opt("class", function() return (select(2, UnitClass("player"))) end) or nil
  blob.faction = share.shareFaction ~= false
    and opt("faction", function() return UnitFactionGroup and UnitFactionGroup("player") end) or nil
  blob.level = opt("level", function() return UnitLevel and UnitLevel("player") end)
  blob.questRate = opt("questRate", function() return LP.Rates and LP.Rates:GetQuestRate() end)
  blob.questRateSource = opt("questRateSource", function() return LP.Rates and LP.Rates:QuestRateSource() end)

  -- PvP and nemesis ride the sharePvP consent (they carry other people's
  -- character names). Rares are your own activity, so they ride the ordinary
  -- levelling consent.
  if share.sharePvP and LP.PvP then
    blob.pvp = opt("pvp", function() return LP.PvP:Payload() end)
  end
  if share.sharePvP and LP.Nemesis then
    blob.nemesis = opt("nemesis", function() return LP.Nemesis:Payload() end)
  end
  if LP.RareFinder then
    blob.rares = opt("rares", function() return LP.RareFinder:Payload() end)
  end

  -- Record what degraded, so a client that quietly loses an enrichment can be
  -- diagnosed from the saved file rather than from a day of guessing.
  LP.gdb.exportFailures = failures
  if failures and LP.debug then
    LP:Print("|cffff8080export: skipped " .. failures .. " (see /lp share)|r")
  end

  LP.gdb.export[key] = blob
  self:WriteJSON()
  return blob
end

-- ---------------------------------------------------------------------------
-- JSON transport
--
-- The export is ALSO written as a single JSON string, because that is what
-- makes a zero-install uploader possible. Reading the Lua table needs a Lua
-- parser; reading this needs one regex. A PowerShell script -- already on
-- every Windows machine -- can ship a player's data with nothing to install.
-- ---------------------------------------------------------------------------

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function jsonString(str)
  str = string.gsub(str, '[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
  end)
  return '"' .. str .. '"'
end

local function jsonValue(v)
  local t = type(v)
  if v == nil then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    -- No inf/nan in JSON, and Lua would emit them happily.
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.4f", v)
  end
  if t == "string" then return jsonString(v) end
  if t ~= "table" then return "null" end

  -- Array if it has a [1]; our payload never mixes the two.
  if v[1] ~= nil then
    local out = {}
    for i = 1, #v do out[#out + 1] = jsonValue(v[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do
    if type(k) == "string" then keys[#keys + 1] = k end
  end
  table.sort(keys)  -- stable output, so an unchanged export is byte-identical
  local out = {}
  for _, k in ipairs(keys) do
    out[#out + 1] = jsonString(k) .. ":" .. jsonValue(v[k])
  end
  return "{" .. table.concat(out, ",") .. "}"
end

Export.ToJSON = jsonValue

-- Rebuild the JSON transport string from every character on this account.
function Export:WriteJSON()
  if not LP.gdb then return nil end
  local list = {}
  for _, blob in pairs(LP.gdb.export or {}) do list[#list + 1] = blob end
  if #list == 0 then
    LP.gdb.exportJSON = nil
    return nil
  end
  LP.gdb.exportJSON = jsonValue(list)
  return LP.gdb.exportJSON
end

function Export:Clear()
  if LP.gdb then
    LP.gdb.export = nil
    LP.gdb.exportJSON = nil
  end
end

-- Told once per session, and only when it actually matters: sharing is off
-- AND there is finished work sitting there that would go up the moment it
-- were switched on.
--
-- This exists because of a real case. A player levelled a whole character
-- with the addon running, had the companion running too, and nothing ever
-- reached the board -- because sharing is off by default and nothing ever
-- said so. The companion could not help: with sharing off there is no blob,
-- so it has nothing to send and never even contacts the server. The only
-- place that knows is here.
--
-- Deliberately not a popup, and deliberately not repeated: someone who leaves
-- sharing off has made a choice, and nagging them is worse than them missing
-- a board they did not want to be on.
function Export:NudgeIfIdle()
  -- Once per session, across every trigger. At login it usually has nothing
  -- to say for a fresh character (no finished levels yet), so LEVEL_CHANGED
  -- below gives it a second chance the moment the first level completes --
  -- without turning every ding into a nag.
  if self.nudgedThisSession then return false end
  if self:Enabled() then return false end
  local levels = (LP.History and LP.History:All()) or {}
  local done = 0
  for i = 1, #levels do
    if levels[i].elapsed and levels[i].elapsed > 0 then done = done + 1 end
  end
  if done == 0 then return false end

  LP:Print(string.format(
    "%d completed level%s recorded, but sharing is |cffff8080off|r -- nothing is being uploaded.",
    done, done == 1 and "" or "s"))
  LP:Print("Turn it on with |cffffd100/lp share on|r (or the minimap button), then /reload.")
  self.nudgedThisSession = true
  return true
end

function Export:Summary()
  local blob = LP.gdb and LP.gdb.export and LP.gdb.export[(charKey())]
  if not blob then
    -- Say the true thing. This used to print "sharing off" whenever there
    -- was no blob, which is also what a FAILED write looks like -- so a
    -- player with sharing on and a crashing export was told they had never
    -- turned it on, and went looking for a checkbox instead of a bug.
    if self:Enabled() then
      return "sharing is ON but nothing has been written yet -- /reload, and if this persists it is a bug (" ..
             (LP.gdb.exportFailures or "no failure recorded") .. ")"
    end
    return "sharing off"
  end
  local msg = string.format("%d completed level%s ready to upload",
    #blob.levels, #blob.levels == 1 and "" or "s")
  -- If an optional enrichment was dropped on this client, say so here rather
  -- than leaving the player to wonder why a field is missing from the board.
  if LP.gdb.exportFailures then
    msg = msg .. " (this client could not read: " .. LP.gdb.exportFailures .. ")"
  end
  return msg
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

LP:On("LEVEL_CHANGED", function()
  -- The first completed level is the moment sharing-off starts costing
  -- something. Say so then, not at the next login.
  if LP.Export and LP.Export.NudgeIfIdle then
    pcall(function() LP.Export:NudgeIfIdle() end)
  end
end)

LP:On("LEVEL_CHANGED", function() Export:Write() end)
LP:On("SHARE_CHANGED", function() Export:Write() end)

function Export:Enable()
  self:Write()
  if not CreateFrame then return end
  local f = CreateFrame("Frame", "LevelPaceExport")
  util.SafeRegisterEvent(f, "PLAYER_LOGOUT")
  f:SetScript("OnEvent", function() Export:Write() end)
  self.frame = f
end

LP:On("PLAYER_READY", function() Export:Enable() end)
