-- LevelPace :: PvP
--
-- Collection for the twink board: weekly kills, item level, lifetime kills,
-- deaths and nemeses.
--
-- READ THIS BEFORE TRUSTING ANY NUMBER IN HERE. Three of the five are not
-- directly available on 3.3.5a and have to be reconstructed:
--
--   weekly kills  GetPVPThisWeekStats() was REMOVED in patch 2.0.1 and the
--                 underlying player fields do not exist in the 3.3.5
--                 descriptor. Rebuilt from GetPVPLifetimeStats() deltas
--                 against an anchor we keep ourselves. Kills earned while
--                 the addon was off still land in the total, but cannot be
--                 attributed to a day.
--
--   item level    GetAverageItemLevel() is a 4.0.1 addition. Computed per
--                 slot from GetItemInfo, which returns nil on a cache miss
--                 and has no completion event on this client (
--                 GET_ITEM_INFO_RECEIVED is 4.0.3), so it must be polled.
--                 Heirlooms report item level 1, not their scaled value --
--                 ruinous for a twink average, so they are excluded and
--                 counted separately.
--
--   nemesis       There is NO API that names your killer. PARTY_KILL is
--                 unicast to the KILLER'S group only, so the victim never
--                 sees it. This attributes the death to whatever player last
--                 damaged you, which is a good guess and sometimes simply
--                 wrong: falls and drownings have no player source, a
--                 five-attacker gank credits whoever landed the last hit,
--                 and a DoT can tick from someone already dead.
--
-- Deaths counted here are PvP deaths only -- ones we could attribute to a
-- player. PvE deaths are tracked by History, separately.

local LP = _G.LevelPace
local util = LP.util

local PvP = {}
LP.PvP = PvP

-- Combat-log object flags, 3.3.5a values (Constants.lua).
local TYPE_PLAYER    = 0x00000400
local CONTROL_PLAYER = 0x00000100

-- A death is attributed to whoever damaged us within this window. Long
-- enough to survive a killing blow landing a moment after the last tick,
-- short enough that an unrelated earlier fight is not blamed.
local ATTRIBUTION_WINDOW = 10

-- GetItemInfo has no completion event on 3.3.5a, so the scan retries.
local ITEM_RETRY_INTERVAL = 0.5
local ITEM_RETRY_MAX = 20   -- ~10s, then publish what we have with a count

-- Equipped slots that count toward an average item level.
-- Excluded deliberately: AMMO (0), BODY/shirt (4) and TABARD (19) carry no
-- meaningful item level. RANGED (18) IS included -- on 3.3.5a it holds bows,
-- guns, wands, thrown and relics, all of which have real item levels.
local ILVL_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }
local SLOT_OFFHAND = 17

local HEIRLOOM_QUALITY = 7

-- ---------------------------------------------------------------------------
-- Kill counters
-- ---------------------------------------------------------------------------

function PvP:LifetimeKills()
  if not GetPVPLifetimeStats then return nil end
  -- Exactly TWO returns on 3.3.5a: hk, highestRank. The vanilla three-value
  -- form (hk, dk, rank) lost its dishonorable-kill slot in 2.0.1, so reading
  -- a third value here would silently take the rank as a kill count.
  local ok, hk = pcall(GetPVPLifetimeStats)
  if not ok or type(hk) ~= "number" then return nil end
  return hk
end

function PvP:TodayKills()
  if not GetPVPSessionStats then return nil end
  -- Despite the name this is TODAY (server day), not the login session. It
  -- is a server-side uint16 that rolls over at server midnight.
  local ok, hk = pcall(GetPVPSessionStats)
  if not ok or type(hk) ~= "number" then return nil end
  return hk
end

function PvP:YesterdayKills()
  if not GetPVPYesterdayStats then return nil end
  local ok, hk = pcall(GetPVPYesterdayStats)
  if not ok or type(hk) ~= "number" then return nil end
  return hk
end

-- ---------------------------------------------------------------------------
-- The weekly window
--
-- The server's reset weekday is not exposed to the client at all -- there is
-- no API for it, and every realm can change it -- so it is a setting, with
-- TrinityCore's Wednesday default. GetServerTime() is a 6.2.0 addition, so
-- the boundary is computed from the CLIENT clock, which is why this is
-- approximate and says so.
-- ---------------------------------------------------------------------------

-- Start of the current PvP week, as a client-clock unix timestamp.
function PvP:WeekStart(now, resetWeekday, resetHour)
  now = now or (time and time()) or 0
  resetWeekday = resetWeekday or 4          -- 1=Sun .. 7=Sat; 4 = Wednesday
  resetHour = resetHour or 0
  if now <= 0 or not date then return 0 end

  -- type check, not a truthiness check: date() returns a STRING for every
  -- format except "*t", and a string sails straight past `if not t`, so the
  -- guard would pass and t.wday would then be nil arithmetic.
  local ok, t = pcall(date, "*t", now)
  if not ok or type(t) ~= "table" or type(t.wday) ~= "number" then return 0 end

  -- Seconds since the most recent reset weekday at resetHour.
  local daysSince = (t.wday - resetWeekday) % 7
  local secsToday = t.hour * 3600 + t.min * 60 + t.sec
  local secsSinceReset = daysSince * 86400 + secsToday - resetHour * 3600
  if secsSinceReset < 0 then secsSinceReset = secsSinceReset + 7 * 86400 end
  return now - secsSinceReset
end

function PvP:Store()
  if not LP.db then return nil end
  LP.db.pvp = LP.db.pvp or {
    weekStart = 0,
    anchorLifetime = nil,   -- lifetime HK at the start of this week
    lifetime = 0,
    deaths = 0,
    nemesis = {},           -- [guid] = { name, count, last }
    itemLevel = nil,
    slotsCounted = 0,
    heirlooms = 0,
    missingSlots = 0,
  }
  return LP.db.pvp
end

-- Roll the weekly anchor forward when the week has turned over.
function PvP:UpdateWeek(now)
  local s = self:Store()
  if not s then return end
  local cfg = LP.db.profile.pvp or {}
  local start = self:WeekStart(now, cfg.resetWeekday, cfg.resetHour)
  local lifetime = self:LifetimeKills()

  if lifetime == nil then return end
  s.lifetime = lifetime

  if s.weekStart ~= start or s.anchorLifetime == nil then
    -- New week (or first ever run). Anchor here.
    --
    -- On the very first run we have no idea how many of the player's
    -- existing lifetime kills happened this week, so weekly starts at zero
    -- rather than crediting a career's worth to the current week.
    s.weekStart = start
    s.anchorLifetime = lifetime
  elseif lifetime < s.anchorLifetime then
    -- Lifetime went backwards: a character transfer, a server rollback, or a
    -- different character on the same account. Re-anchor rather than emit a
    -- negative weekly count.
    s.anchorLifetime = lifetime
  end
end

function PvP:WeeklyKills()
  local s = self:Store()
  if not s or s.anchorLifetime == nil or not s.lifetime then return nil end
  local n = s.lifetime - s.anchorLifetime
  if n < 0 then return 0 end
  return n
end

-- ---------------------------------------------------------------------------
-- Item level
-- ---------------------------------------------------------------------------

-- Returns average, slotsCounted, heirloomCount, missingCount.
-- `average` is nil while any slot is still uncached, so a half-loaded scan
-- never gets published as a real number.
function PvP:ScanItemLevel()
  if not GetInventoryItemLink or not GetItemInfo then return nil, 0, 0, 0 end

  local total, counted, heirlooms, missing = 0, 0, 0, 0
  local mainhandTwoHand = false
  local present = {}

  for _, slot in ipairs(ILVL_SLOTS) do
    local ok, link = pcall(GetInventoryItemLink, "player", slot)
    if ok and link then
      present[slot] = true
      local ok2, _, _, quality, ilvl, _, _, _, _, equipLoc = pcall(GetItemInfo, link)
      if not ok2 or ilvl == nil then
        -- Not in the client's item cache yet. The GetItemInfo call above is
        -- itself the request; the answer arrives later, and on 3.3.5a there
        -- is no event to tell us, so the caller polls.
        missing = missing + 1
      elseif quality == HEIRLOOM_QUALITY then
        -- Heirlooms report their BASE item level of 1, not the level-scaled
        -- value. Averaging that in drags a real set down to nonsense, which
        -- matters most for exactly the twinks this board is about.
        heirlooms = heirlooms + 1
        if equipLoc == "INVTYPE_2HWEAPON" and slot == 16 then mainhandTwoHand = true end
      else
        total = total + ilvl
        counted = counted + 1
        if equipLoc == "INVTYPE_2HWEAPON" and slot == 16 then mainhandTwoHand = true end
      end
    end
  end

  -- A two-hander leaves the off-hand legitimately empty. Blizzard's own later
  -- implementation drops the slot from the divisor rather than scoring it
  -- zero; counted only ever includes slots that held something, so nothing
  -- extra is needed here beyond not treating the gap as a miss.
  local _ = mainhandTwoHand and present[SLOT_OFFHAND]

  if missing > 0 then return nil, counted, heirlooms, missing end
  if counted == 0 then return nil, 0, heirlooms, 0 end
  return total / counted, counted, heirlooms, 0
end

function PvP:RefreshItemLevel()
  local s = self:Store()
  if not s then return end
  local avg, counted, heirlooms, missing = self:ScanItemLevel()
  s.slotsCounted = counted
  s.heirlooms = heirlooms
  s.missingSlots = missing
  if avg then
    s.itemLevel = avg
    self.itemRetries = 0
    return avg
  end
  -- Still cold. Retry on a ticker, and give up eventually rather than
  -- spinning forever on an item the server will never send.
  self.itemRetries = (self.itemRetries or 0) + 1
  if self.itemRetries <= ITEM_RETRY_MAX then
    self.itemPending = true
  else
    self.itemPending = false
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Nemesis
--
-- No API names your killer, so this is a heuristic: remember the last player
-- who damaged us, and blame them when we die. Honest about being a guess.
-- ---------------------------------------------------------------------------

local function isPlayer(flags)
  if type(flags) ~= "number" or not bit then return false end
  -- BOTH bits. TYPE_PLAYER alone also matches a mind-controlled player;
  -- CONTROL_PLAYER alone matches pets, guardians and totems.
  return bit.band(flags, TYPE_PLAYER) ~= 0
     and bit.band(flags, CONTROL_PLAYER) ~= 0
end

function PvP:NoteDamage(srcGUID, srcName, srcFlags, now)
  if not srcGUID or not isPlayer(srcFlags) then return end
  if srcGUID == self.playerGUID then return end   -- our own damage to ourselves
  self.lastAttacker = { guid = srcGUID, name = srcName, t = now }
end

function PvP:NoteDeath(now)
  local s = self:Store()
  if not s then return nil end
  local a = self.lastAttacker
  if not a or (now - a.t) > ATTRIBUTION_WINDOW then
    -- Died with no recent player damage: a mob, a fall, drowning, lava. Not
    -- a PvP death, so it does not go in this tally at all.
    return nil
  end

  s.deaths = (s.deaths or 0) + 1
  s.nemesis = s.nemesis or {}
  -- Keyed on GUID, not name: sourceName arrives nil when the attacker is not
  -- in the client's object cache (stealth openers, long range), and names are
  -- not unique across realms. The name is a refreshable label.
  local e = s.nemesis[a.guid]
  if e then
    e.count = e.count + 1
    e.last = now
    if a.name then e.name = a.name end
  else
    s.nemesis[a.guid] = { name = a.name or "Unknown", count = 1, last = now }
  end
  self.lastAttacker = nil
  LP:Fire("PVP_DEATH", a.name)
  return a.name
end

-- Top N nemeses, most kills first.
function PvP:TopNemesis(n)
  local s = self:Store()
  if not s or not s.nemesis then return {} end
  local list = {}
  for guid, e in pairs(s.nemesis) do
    list[#list + 1] = { guid = guid, name = e.name, count = e.count, last = e.last }
  end
  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return (a.name or "") < (b.name or "")
  end)
  local out = {}
  for i = 1, math.min(n or 3, #list) do out[i] = list[i] end
  return out
end

-- ---------------------------------------------------------------------------
-- Export payload
-- ---------------------------------------------------------------------------

function PvP:Payload()
  local s = self:Store()
  if not s then return nil end
  local nem = {}
  for _, e in ipairs(self:TopNemesis(3)) do
    nem[#nem + 1] = { name = e.name, count = e.count }
  end
  return {
    bracket = self:Bracket(),
    itemLevel = s.itemLevel,
    slotsCounted = s.slotsCounted,
    heirlooms = s.heirlooms,
    weeklyKills = self:WeeklyKills(),
    weekStart = s.weekStart,
    lifetimeKills = s.lifetime,
    deaths = s.deaths,
    nemesis = nem,
    -- So the board can label these honestly rather than implying precision.
    approx = { nemesis = true, weeklyKills = true, itemLevelExcludesHeirlooms = true },
  }
end

-- Twink brackets are the classic PvP level bands.
function PvP:Bracket()
  local lvl = (UnitLevel and UnitLevel("player")) or 0
  if lvl <= 0 then return nil end
  if lvl >= 80 then return 80 end
  return math.floor(lvl / 10) * 10 + 9
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function PvP:Enable()
  if not LP.db then return end
  LP.db.profile.pvp = util.CopyDefaults(LP.db.profile.pvp or {}, {
    enabled = true,
    resetWeekday = 4,   -- Wednesday, TrinityCore's default
    resetHour = 0,
  })
  self:Store()
  self.playerGUID = UnitGUID and UnitGUID("player") or nil
  self:UpdateWeek()
  self:RefreshItemLevel()

  if not CreateFrame then return end
  local f = CreateFrame("Frame", "LevelPacePvP")
  util.SafeRegisterEvent(f, "COMBAT_LOG_EVENT_UNFILTERED")
  util.SafeRegisterEvent(f, "PLAYER_DEAD")
  util.SafeRegisterEvent(f, "PLAYER_PVP_KILLS_CHANGED")
  util.SafeRegisterEvent(f, "UNIT_INVENTORY_CHANGED")
  util.SafeRegisterEvent(f, "PLAYER_LEVEL_UP")

  -- COMBAT_LOG_EVENT_UNFILTERED fires constantly, so this handler must bail
  -- out in a couple of comparisons for the overwhelming majority of events.
  -- 3.3.5a passes EIGHT base args: no hideCaster (4.1.0) and no raid flags
  -- (4.2.0). Reading a modern 11-arg layout here would misparse everything.
  f:SetScript("OnEvent", function(_, event, timestamp, subevent,
                                  srcGUID, srcName, srcFlags,
                                  dstGUID, dstName, dstFlags)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
      if dstGUID ~= PvP.playerGUID then return end
      local now = GetTime and GetTime() or 0
      if subevent == "UNIT_DIED" then
        -- UNIT_DIED puts the dying unit in the DEST slot with an empty
        -- source, so it never tells us who did it.
        PvP:NoteDeath(now)
      elseif string.find(subevent, "_DAMAGE", 1, true) then
        PvP:NoteDamage(srcGUID, srcName, srcFlags, now)
      end
    elseif event == "PLAYER_DEAD" then
      PvP:NoteDeath(GetTime and GetTime() or 0)
    elseif event == "PLAYER_PVP_KILLS_CHANGED" then
      PvP:UpdateWeek()
    else
      PvP:RefreshItemLevel()
    end
  end)
  self.frame = f

  -- Item cache poll. GetItemInfo has no completion event on this client.
  LP:Schedule(ITEM_RETRY_INTERVAL, function()
    if PvP.itemPending then PvP:RefreshItemLevel() end
  end)

  -- Weekly rollover check; cheap, and the boundary can pass mid-session.
  LP:Schedule(60, function() PvP:UpdateWeek() end)
end

LP:On("PLAYER_READY", function() PvP:Enable() end)
