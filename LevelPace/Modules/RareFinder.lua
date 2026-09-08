-- LevelPace :: Modules/RareFinder
--
-- Logs rare and rare-elite kills: what died, when, and whether you got the
-- killing blow. Because UNIT_DIED fires for anything dying in combat-log
-- range, this also sees rares other people kill near you -- which is what
-- makes a shared log worth reading.
--
-- Identification is by creature entry decoded from the GUID, checked against
-- the 420-entry catalogue in Data/Rares.lua. Private servers add their own
-- rares, so anything the player targets that UnitClassification calls rare is
-- learned at runtime and kept separately, flagged, so the server can weight it
-- differently from a catalogue hit.

local LP = _G.LevelPace
LP.RareFinder = LP.RareFinder or {}
local RF = LP.RareFinder

local util = LP.util

RF.MAX_KILLS = 500

-- Two GUID sightings of one corpse within this window are one kill. PARTY_KILL
-- and UNIT_DIED both fire for a mob you killed; the order is not guaranteed.
local DEDUPE_SECONDS = 10

-- UnitClassification values worth recording. 1 = elite and 3 = worldboss are
-- deliberately excluded: an elite is not rare, and a raid boss is not a find.
local RARE_RANKS = { [2] = true, [4] = true }

local function db()
  if not LP.db then return nil end
  LP.db.rare = LP.db.rare or { kills = {}, learned = {} }
  LP.db.rare.kills = LP.db.rare.kills or {}
  LP.db.rare.learned = LP.db.rare.learned or {}
  return LP.db.rare
end

-- Session-local, never persisted: keyed by GUID, holding GetTime() values.
-- GetTime() restarts at zero every session, so persisting these would make
-- every stored entry read as future-dated on the next login.
local recentGUIDs = {}

function RF:Init()
  recentGUIDs = {}
  db()
end

-- ---------------------------------------------------------------------------
-- Identification
-- ---------------------------------------------------------------------------

function RF:Identify(npcID)
  if type(npcID) ~= "number" or npcID <= 0 then return nil end

  local cat = LP.data and LP.data.RARES and LP.data.RARES[npcID]
  if cat then
    return { name = cat.name, rank = cat.rank, learned = false }
  end

  local d = db()
  local got = d and d.learned[npcID]
  if got then
    return { name = got.name, rank = got.rank, learned = true }
  end
  return nil
end

function RF:Learn(npcID, name, rank)
  if type(npcID) ~= "number" or npcID <= 0 then return false end
  if not RARE_RANKS[rank] then return false end
  -- The catalogue is authoritative; a server renaming a Blizzlike rare should
  -- not let the client overwrite what everyone else calls it.
  if LP.data and LP.data.RARES and LP.data.RARES[npcID] then return false end
  local d = db()
  if not d then return false end
  d.learned[npcID] = { name = name or ("Unknown " .. npcID), rank = rank }
  return true
end

-- Called on target/mouseover changes: the only way to discover a rare the
-- catalogue does not know about, since 3.3.5a has no nameplate unit tokens.
function RF:Inspect(unit)
  if not UnitClassification or not UnitGUID then return end
  local cls = UnitClassification(unit)
  local rank = (cls == "rare" and 4) or (cls == "rareelite" and 2) or nil
  if not rank then return end
  local npcID = util.CreatureID(UnitGUID(unit))
  if not npcID then return end
  if UnitName then self:Learn(npcID, UnitName(unit), rank) end
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

function RF:Kills()
  local d = db()
  return (d and d.kills) or {}
end

function RF:RecordKill(npcID, info, mine)
  local d = db()
  if not d then return nil end
  local row = {
    npc = npcID,
    name = info.name,
    rank = info.rank,
    learned = info.learned,
    mine = mine and true or false,
    -- Wall clock, not GetTime(): this is persisted and compared across
    -- sessions, and GetTime() restarts at zero every login.
    t = (time and time()) or 0,
  }
  util.PushBounded(d.kills, row, RF.MAX_KILLS)
  LP:Fire("RARE_KILL", row)
  return row
end

function RF:OnCombatLog(_, subevent, _, _, _, dstGUID, _, _)
  local mine = (subevent == "PARTY_KILL")
  if not mine and subevent ~= "UNIT_DIED" then return end

  local npcID = util.CreatureID(dstGUID)
  if not npcID then return end

  local info = self:Identify(npcID)
  if not info then return end

  -- One corpse, one kill. PARTY_KILL and UNIT_DIED both fire for a mob you
  -- killed yourself, in an order the client does not promise.
  local now = (GetTime and GetTime()) or 0
  local seen = recentGUIDs[dstGUID]
  if seen and (now - seen) >= 0 and (now - seen) < DEDUPE_SECONDS then
    -- Already logged. If this is the PARTY_KILL half arriving second, upgrade
    -- the credit rather than adding a row.
    if mine then
      local kills = self:Kills()
      local last = kills[#kills]
      if last and last.npc == npcID then last.mine = true end
    end
    return
  end
  recentGUIDs[dstGUID] = now

  return self:RecordKill(npcID, info, mine)
end

-- ---------------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------------

function RF:Stats()
  local kills = self:Kills()
  local seen, unique, mine = {}, 0, 0
  for i = 1, #kills do
    local k = kills[i]
    if k.mine then mine = mine + 1 end
    if not seen[k.npc] then seen[k.npc] = true; unique = unique + 1 end
  end
  return { total = #kills, mine = mine, unique = unique }
end

-- Most-killed rares, highest first.
function RF:TopRares(n)
  local counts, order = {}, {}
  local kills = self:Kills()
  for i = 1, #kills do
    local k = kills[i]
    if not counts[k.npc] then
      counts[k.npc] = { npc = k.npc, name = k.name, n = 0 }
      order[#order + 1] = counts[k.npc]
    end
    counts[k.npc].n = counts[k.npc].n + 1
  end
  table.sort(order, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return (a.name or "") < (b.name or "")
  end)
  while #order > (n or 5) do table.remove(order) end
  return order
end

function RF:PrintSummary()
  local s = self:Stats()
  if s.total == 0 then
    LP:Print("no rare kills logged yet. Kill one, or stand near someone who does.")
    return
  end
  LP:Print(string.format("rares: %d kill(s), %d yours, %d unique",
                         s.total, s.mine, s.unique))
  local top = self:TopRares(5)
  for i = 1, #top do
    LP:Print(string.format("  %d. %s x%d", i, top[i].name or "?", top[i].n))
  end
  local kills = self:Kills()
  local last = kills[#kills]
  if last and date then
    LP:Print("  last: " .. (last.name or "?") .. " on " ..
             tostring(date("%d %b %H:%M", last.t)))
  end
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

LP:RegisterModule({
  id = "rarefinder",
  title = "Rare Finder",
  desc = "Logs rare kills -- yours and any you witness.",
  default = true,

  OnEnable = function()
    RF:Init()
    -- Collection goes on the WoW-event router, NOT the internal bus: the bus
    -- has no unsubscribe path, so a bus handler would keep running after the
    -- module is switched off.
    LP:OnCombatLog("rarefinder", { "UNIT_DIED", "PARTY_KILL" }, function(...)
      RF:OnCombatLog(...)
    end)
    LP:RegisterEvent("PLAYER_TARGET_CHANGED", "rarefinder", function()
      RF:Inspect("target")
    end)
    LP:RegisterEvent("UPDATE_MOUSEOVER_UNIT", "rarefinder", function()
      RF:Inspect("mouseover")
    end)
  end,

  OnDisable = function()
    -- The router drops every handler tagged "rarefinder"; nothing else to do.
  end,
})
