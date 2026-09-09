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
  -- No os.time and no uuid library here; time() plus math.random is enough
  -- for a collision-free-in-practice key.
  math.randomseed((time and time() or 0) + math.floor((GetTime and GetTime() or 0) * 1000))
  local hex = "0123456789abcdef"
  local out = {}
  for i = 1, 32 do
    local n = math.random(1, 16)
    out[i] = string.sub(hex, n, n)
  end
  return table.concat(out)
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
  local blob = {
    schema = self.SCHEMA,
    addon = LP.VERSION,
    id = self:EnsureID(),
    -- The display name is what appears on the board. Defaults to the
    -- character name; the player can set an alias instead.
    -- IDENTITY, always sent, never displayed unless asked for.
    --
    -- The server derives char_id from name@realm and will not accept one
    -- chosen by the client. Realm is part of that key so two players genuinely
    -- named Thrall on different realms do not collide -- which means realm
    -- cannot be optional, or those players lose both their identity and their
    -- collision protection.
    --
    -- The privacy toggle still works: it now controls whether the realm is
    -- SHOWN on the board, not whether it is sent. That distinction is stated
    -- in the option's tooltip rather than left for someone to discover.
    name = name,
    realm = realm,
    showRealm = share.shareRealm ~= false,

    -- PRESENTATION only. Never an identity input.
    display = (share.alias ~= "" and share.alias) or name,
    class = share.shareClass ~= false and (select(2, UnitClass("player"))) or nil,
    faction = share.shareFaction ~= false and (UnitFactionGroup and UnitFactionGroup("player")) or nil,
    level = (UnitLevel and UnitLevel("player")) or nil,
    questRate = LP.Rates and LP.Rates:GetQuestRate() or nil,
    questRateSource = LP.Rates and LP.Rates:QuestRateSource() or nil,
    updated = (time and time()) or 0,
    levels = levelRows(),
    -- PvP block, only when the player opted into the twink board as well.
    -- Nemesis names are OTHER people's character names, so this is a second,
    -- separate consent rather than something that rides along with levelling
    -- stats.
    pvp = (share.sharePvP and LP.PvP) and LP.PvP:Payload() or nil,

    -- Nemesis rides the same consent as the rest of the PvP payload: it
    -- contains other people's character names, who never agreed to anything.
    nemesis = (share.sharePvP and LP.Nemesis) and LP.Nemesis:Payload() or nil,

    -- Rare kills are only ever your own character's activity, so they share
    -- the ordinary levelling consent.
    rares = LP.RareFinder and LP.RareFinder:Payload() or nil,
  }
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
  return true
end

function Export:Summary()
  local blob = LP.gdb and LP.gdb.export and LP.gdb.export[(charKey())]
  if not blob then return "sharing off" end
  return string.format("%d completed level%s ready to upload",
    #blob.levels, #blob.levels == 1 and "" or "s")
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

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
