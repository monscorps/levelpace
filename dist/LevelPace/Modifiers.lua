-- LevelPace :: Modifiers
--
-- Tracks the things that change how much XP a given action is worth, so the
-- estimator can be honest about a projection that depends on a buff which is
-- about to run out.

local LP = _G.LevelPace
local util = LP.util
local d = LP.data

local Modifiers = {}
LP.Modifiers = Modifiers

Modifiers.heirloomMult = 1
Modifiers.heirloomItems = {}

-- Heirloom XP auras are invisible to UnitBuff/UnitAura -- passive item-equip
-- auras never get a client aura slot -- so scanning equipped items is the
-- only way to see them.
--
-- On TrinityCore these compound multiplicatively via AddPct per aura, so
-- shoulders + chest + ring is 1.10 * 1.10 * 1.05 = 1.2705, NOT 1.25.
function Modifiers:ScanHeirlooms()
  local mult = 1
  local found = {}
  if not GetInventoryItemID then return 1, found end
  for _, slot in ipairs(d.HEIRLOOM_SLOTS) do
    local ok, itemID = pcall(GetInventoryItemID, "player", slot)
    if ok and itemID then
      local pct = d.HEIRLOOM_XP[itemID]
      if pct then
        mult = mult * (1 + pct / 100)
        found[#found + 1] = { slot = slot, itemID = itemID, pct = pct }
      end
    end
  end
  return mult, found
end

function Modifiers:Refresh()
  local mult, found = self:ScanHeirlooms()
  local changed = (mult ~= self.heirloomMult)
  self.heirloomMult = mult
  self.heirloomItems = found
  if changed then LP:Fire("MODIFIERS_CHANGED") end
  return mult
end

-- Applies to BOTH kill and quest XP (spell 57353 carries Mod Kill Experience
-- Gained % and Mod Quest Experience Gained %), so it largely cancels out of
-- the grind-vs-quest comparison -- but it still moves absolute projections.
function Modifiers:HeirloomMultiplier()
  return self.heirloomMult or 1
end

function Modifiers:HeirloomPercent()
  return (self:HeirloomMultiplier() - 1) * 100
end

-- The remaining rested BONUS pool. A pool of P supplies 2P total XP in
-- exchange for P XP of base killing. Returns 0, never nil.
function Modifiers:GetRestedPool()
  if not GetXPExhaustion then return 0 end
  local ok, pool = pcall(GetXPExhaustion)
  if not ok or not pool then return 0 end
  return pool
end

function Modifiers:IsRested()
  return self:GetRestedPool() > 0
end

function Modifiers:IsXPDisabled()
  if not IsXPUserDisabled then return false end
  local ok, disabled = pcall(IsXPUserDisabled)
  return (ok and disabled) and true or false
end

-- A short human summary for the tooltip.
function Modifiers:Describe()
  local parts = {}
  local pool = self:GetRestedPool()
  if pool > 0 then
    parts[#parts + 1] = "Rested " .. util.FormatNumber(pool) .. " (kill XP only)"
  end
  local pct = self:HeirloomPercent()
  if pct > 0 then
    parts[#parts + 1] = string.format("Heirlooms +%.2f%%", pct)
  end
  if self:IsXPDisabled() then
    parts[#parts + 1] = "|cffff5555XP gain is turned off|r"
  end
  return parts
end

function Modifiers:Enable()
  self:Refresh()
  if not CreateFrame then return end
  local f = CreateFrame("Frame", "LevelPaceModifiers")
  -- PLAYER_EQUIPMENT_CHANGED does exist on 3.3.5a despite the widespread
  -- "4.0.1 only" claim (Blizzard's own 3.3.5 UI simply never calls it), but
  -- UNIT_INVENTORY_CHANGED is equally correct here and needs no per-slot
  -- bookkeeping. Both go through SafeRegisterEvent regardless, because
  -- registering an event this client does not know is a hard error.
  util.SafeRegisterEvent(f, "UNIT_INVENTORY_CHANGED")
  util.SafeRegisterEvent(f, "UPDATE_EXHAUSTION")
  -- Deliberately not filtered on unit == "player": the player's unit token
  -- becomes "vehicle" while in a vehicle, and the scan is four
  -- GetInventoryItemID calls, so filtering would risk more than it saves.
  f:SetScript("OnEvent", function()
    Modifiers:Refresh()
  end)
  self.frame = f
end

LP:On("PLAYER_READY", function() Modifiers:Enable() end)
