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

Export.SCHEMA = 1

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
    return nil
  end

  local share = LP.db.profile.share
  local blob = {
    schema = self.SCHEMA,
    addon = LP.VERSION,
    id = self:EnsureID(),
    -- The display name is what appears on the board. Defaults to the
    -- character name; the player can set an alias instead.
    display = (share.alias ~= "" and share.alias) or name,
    realm = share.shareRealm ~= false and realm or nil,
    class = share.shareClass ~= false and (select(2, UnitClass("player"))) or nil,
    faction = share.shareFaction ~= false and (UnitFactionGroup and UnitFactionGroup("player")) or nil,
    level = (UnitLevel and UnitLevel("player")) or nil,
    questRate = LP.Rates and LP.Rates:GetQuestRate() or nil,
    questRateSource = LP.Rates and LP.Rates:QuestRateSource() or nil,
    updated = (time and time()) or 0,
    levels = levelRows(),
  }
  LP.gdb.export[key] = blob
  return blob
end

function Export:Clear()
  if LP.gdb then LP.gdb.export = nil end
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
