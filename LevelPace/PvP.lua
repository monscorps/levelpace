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
    nemesis = {},           -- [guid] = { name, count, last }  they killed me
    victims = {},           -- [guid] = { name, count, last }  I killed them
    streak = 0,             -- consecutive kills without dying
    bestStreak = 0,
    kills = 0,              -- kills we actually SAW, distinct from lifetime HK
    achievements = {},      -- [id] = unix seconds earned
    itemLevel = nil,
    slotsCounted = 0,
    heirlooms = 0,
    missingSlots = 0,
  }
  local s = LP.db.pvp
  -- Fields added after a player's first install.
  s.victims = s.victims or {}
  s.achievements = s.achievements or {}
  -- Written by an earlier version; meaningless across sessions (see
  -- KillsWithin) so drop it rather than let it accumulate.
  s.recentKills = nil
  s.streak = s.streak or 0
  s.bestStreak = s.bestStreak or 0
  s.kills = s.kills or 0
  return s
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
  -- The streak ends here. Remember who ended it, so killing them next earns
  -- Revenge rather than just being another kill.
  s.streak = 0
  self.pendingRevenge = a.guid
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
  -- Dying can earn something too (Humbled, Even Score going the wrong way).
  self:CheckAchievements(now)
  return a.name
end

-- ---------------------------------------------------------------------------
-- Your own kills, and streaks
--
-- Unlike deaths, this half is EXACT. PARTY_KILL fires for the killer, so when
-- the source is us and the victim is a player, that is a real kill with a
-- real name -- no heuristic. (It never reaches the victim, which is precisely
-- why the nemesis side has to guess.)
-- ---------------------------------------------------------------------------

local BURST_WINDOW = 60   -- seconds, for the "several kills quickly" awards

function PvP:NoteKill(dstGUID, dstName, dstFlags, now)
  if not dstGUID or not isPlayer(dstFlags) then return end
  if dstGUID == self.playerGUID then return end
  local s = self:Store()
  if not s then return end

  s.kills = (s.kills or 0) + 1
  s.streak = (s.streak or 0) + 1
  if s.streak > (s.bestStreak or 0) then s.bestStreak = s.streak end

  local v = s.victims[dstGUID]
  if v then
    v.count = v.count + 1
    v.last = now
    if dstName then v.name = dstName end
  else
    s.victims[dstGUID] = { name = dstName or "Unknown", count = 1, last = now }
  end

  self.recentKills = self.recentKills or {}
  util.PushBounded(self.recentKills, now, 40)

  self.lastKill = { guid = dstGUID, name = dstName, t = now }
  LP:Fire("PVP_KILL", dstName, s.streak)
  self:CheckAchievements(now)
end

-- Kills inside the last `window` seconds.
--
-- Deliberately NOT persisted. These are GetTime() values, and GetTime()
-- restarts at zero every session -- so a stored timestamp from last night is
-- larger than this session's clock, `now - t` comes out negative, and every
-- old kill counts as "just now". That is an instant false Bloodbath on every
-- login. Burst detection only means anything within one session anyway.
function PvP:KillsWithin(window, now)
  now = now or (GetTime and GetTime()) or 0
  local n = 0
  for _, t in ipairs(self.recentKills or {}) do
    local age = now - t
    -- Belt and braces: reject future timestamps as well as old ones.
    if age >= 0 and age <= window then n = n + 1 end
  end
  return n
end

-- ---------------------------------------------------------------------------
-- Achievements
--
-- Deliberately built only from things we can actually observe. Nothing here
-- depends on the reconstructed weekly counter, and nothing claims to know
-- something the client cannot see.
--
-- Each entry: id, name, blurb, and check(store, self, now) -> boolean.
-- ---------------------------------------------------------------------------

PvP.ACHIEVEMENTS = {
  { id = "firstblood", name = "First Blood",
    blurb = "Kill another player.",
    check = function(s) return (s.kills or 0) >= 1 end },

  { id = "tencount", name = "Ten Count",
    blurb = "Kill 10 players.",
    check = function(s) return (s.kills or 0) >= 10 end },

  { id = "century", name = "Century",
    blurb = "Kill 100 players.",
    check = function(s) return (s.kills or 0) >= 100 end },

  { id = "streak5", name = "On A Roll",
    blurb = "5 kills without dying.",
    check = function(s) return (s.bestStreak or 0) >= 5 end },

  { id = "streak10", name = "Untouchable",
    blurb = "10 kills without dying.",
    check = function(s) return (s.bestStreak or 0) >= 10 end },

  { id = "streak25", name = "Unstoppable",
    blurb = "25 kills without dying. Someone is having a bad evening.",
    check = function(s) return (s.bestStreak or 0) >= 25 end },

  { id = "bloodbath", name = "Bloodbath",
    blurb = "5 kills inside a minute.",
    check = function(s, self, now) return self:KillsWithin(BURST_WINDOW, now) >= 5 end },

  { id = "revenge", name = "Revenge",
    blurb = "Kill the player who killed you last.",
    check = function(s, self)
      local k = self.lastKill
      local avenged = self.pendingRevenge
      return k and avenged and k.guid == avenged
    end },

  { id = "nemesisdown", name = "Nemesis Down",
    blurb = "Kill someone who has killed you at least three times.",
    check = function(s, self)
      local k = self.lastKill
      if not k then return false end
      local n = s.nemesis[k.guid]
      return n and n.count >= 3
    end },

  { id = "evenscore", name = "Even Score",
    blurb = "Draw level with a nemesis who had killed you 5+ times.",
    check = function(s)
      for guid, n in pairs(s.nemesis) do
        if n.count >= 5 then
          local v = s.victims[guid]
          if v and v.count >= n.count then return true end
        end
      end
      return false
    end },

  { id = "archrival", name = "Arch-Rival",
    blurb = "Trade at least 10 kills each way with the same player.",
    check = function(s)
      for guid, n in pairs(s.nemesis) do
        local v = s.victims[guid]
        if n.count >= 10 and v and v.count >= 10 then return true end
      end
      return false
    end },

  { id = "humbled", name = "Humbled",
    blurb = "Die to the same player 10 times. It happens.",
    check = function(s)
      for _, n in pairs(s.nemesis) do
        if n.count >= 10 then return true end
      end
      return false
    end },

  { id = "wellrounded", name = "Well Rounded",
    blurb = "Kill 10 different players.",
    check = function(s)
      local n = 0
      for _ in pairs(s.victims) do n = n + 1 end
      return n >= 10
    end },

  { id = "geared", name = "Kitted Out",
    blurb = "Reach item level 40 while under level 20.",
    check = function(s)
      local lvl = (UnitLevel and UnitLevel("player")) or 99
      return lvl < 20 and (s.itemLevel or 0) >= 40
    end },
}

-- `gameNow` is a GetTime() value -- the same clock the kill timestamps use.
-- The stamp RECORDED against an earned achievement is wall-clock time(), so
-- it still means something after a relog. Mixing the two was what let a
-- 25-minute spread count as a one-minute burst.
function PvP:CheckAchievements(gameNow)
  local s = self:Store()
  if not s then return end
  gameNow = gameNow or (GetTime and GetTime()) or 0
  local stamp = (time and time()) or 0
  for _, a in ipairs(self.ACHIEVEMENTS) do
    if not s.achievements[a.id] then
      local ok, got = pcall(a.check, s, self, gameNow)
      if ok and got then
        s.achievements[a.id] = stamp
        LP:Print(string.format("|cffe5cc80Achievement:|r |cffffd100%s|r -- %s",
          a.name, a.blurb))
        LP:Fire("PVP_ACHIEVEMENT", a.id, a.name)
      end
    end
  end
end

function PvP:EarnedAchievements()
  local s = self:Store()
  if not s then return {} end
  local out = {}
  for _, a in ipairs(self.ACHIEVEMENTS) do
    out[#out + 1] = {
      id = a.id, name = a.name, blurb = a.blurb,
      earned = s.achievements[a.id],
    }
  end
  return out
end

function PvP:AchievementCount()
  local s = self:Store()
  if not s then return 0, #self.ACHIEVEMENTS end
  local n = 0
  for _ in pairs(s.achievements or {}) do n = n + 1 end
  return n, #self.ACHIEVEMENTS
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
  local earned = {}
  for id, at in pairs(s.achievements or {}) do earned[#earned + 1] = id end
  table.sort(earned)

  return {
    bracket = self:Bracket(),
    itemLevel = s.itemLevel,
    slotsCounted = s.slotsCounted,
    heirlooms = s.heirlooms,
    weeklyKills = self:WeeklyKills(),
    weekStart = s.weekStart,
    lifetimeKills = s.lifetime,
    deaths = s.deaths,
    -- Observed kills, as distinct from the server's lifetime honorable-kill
    -- counter: this is what we actually watched happen, and it is what the
    -- streaks and achievements are built from.
    kills = s.kills,
    streak = s.streak,
    bestStreak = s.bestStreak,
    achievements = earned,
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
      -- Our own kills come through PARTY_KILL with us as the SOURCE. This is
      -- the exact half: a real victim name, no guessing.
      if subevent == "PARTY_KILL" and srcGUID == PvP.playerGUID then
        PvP:NoteKill(dstGUID, dstName, dstFlags, GetTime and GetTime() or 0)
        return
      end
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
