-- LevelPace :: Ledger
--
-- The only module in the addon allowed to parse text. Everything downstream
-- consumes the normalised XP_EVENT this emits, which is what makes the rest
-- of the addon testable outside the game.
--
-- Emitted event shape:
--   { t, source, mobName, total, base, rested, group, penalty,
--     questID, predictedXP }
-- where source is "kill" | "quest" | "explore" | "unknown".

local LP = _G.LevelPace
local util = LP.util

local Ledger = {}
LP.Ledger = Ledger

-- How long an armed quest/explore context stays valid. The system message and
-- the XP message arrive in the same server packet burst, so this is generous.
local ATTRIBUTION_WINDOW = 2.0

local RECENT_MAX = 20
Ledger.recent = {}

-- ---------------------------------------------------------------------------
-- Pattern table
--
-- Built once at load from the live _G globals, so other locales work without
-- any change. Order is MOST SPECIFIC FIRST and that is load-bearing: even
-- anchored, the plain EXHAUSTION1 pattern will match a _GROUP message and
-- capture bonusType as "Rested bonus, +12 group".
-- ---------------------------------------------------------------------------

local patterns = {}

local function add(globalName, fields, kind)
  local fmt = _G[globalName]
  if type(fmt) ~= "string" then return end -- absent on this client/locale
  local pat = util.ConvertGlobalString(fmt)
  if not pat then return end
  -- EXHAUSTION1 and EXHAUSTION2 are identical text on 3.3.5a; likewise 4/5.
  -- Trying the same pattern twice is harmless but wasteful, so dedupe.
  for i = 1, #patterns do
    if patterns[i].pattern == pat then return end
  end
  patterns[#patterns + 1] = { pattern = pat, fields = fields, kind = kind, source = globalName }
end

function Ledger:BuildPatterns()
  patterns = {}

  -- 1. named kill, rested/RAF bonus, WITH group bonus
  add("COMBATLOG_XPGAIN_EXHAUSTION1_GROUP", { "mobName", "total", "bonusAmount", "bonusType", "group" }, "kill")
  add("COMBATLOG_XPGAIN_EXHAUSTION2_GROUP", { "mobName", "total", "bonusAmount", "bonusType", "group" }, "kill")
  -- 2. named kill, penalty, WITH group bonus
  add("COMBATLOG_XPGAIN_EXHAUSTION4_GROUP", { "mobName", "total", "penaltyAmount", "penaltyType", "group" }, "kill")
  add("COMBATLOG_XPGAIN_EXHAUSTION5_GROUP", { "mobName", "total", "penaltyAmount", "penaltyType", "group" }, "kill")
  -- 3. named kill, no bonus, WITH group bonus
  add("COMBATLOG_XPGAIN_FIRSTPERSON_GROUP", { "mobName", "total", "group" }, "kill")
  -- 3b. RAID variants. Same shapes with a trailing "-%d raid penalty".
  --
  -- These MUST come before the plain EXHAUSTION* entries: EXHAUSTION1_RAID
  -- ends in "penalty)" just like EXHAUSTION4, so the plain penalty pattern
  -- would swallow it and capture bonusType as "Rested bonus, -12 raid".
  --
  -- The raid penalty is captured but NOT subtracted -- the reported total is
  -- already net of it, so treating it like a group bonus would double-count.
  add("COMBATLOG_XPGAIN_EXHAUSTION1_RAID", { "mobName", "total", "bonusAmount", "bonusType", "raidPenalty" }, "kill")
  add("COMBATLOG_XPGAIN_EXHAUSTION2_RAID", { "mobName", "total", "bonusAmount", "bonusType", "raidPenalty" }, "kill")
  add("COMBATLOG_XPGAIN_EXHAUSTION4_RAID", { "mobName", "total", "penaltyAmount", "penaltyType", "raidPenalty" }, "kill")
  add("COMBATLOG_XPGAIN_EXHAUSTION5_RAID", { "mobName", "total", "penaltyAmount", "penaltyType", "raidPenalty" }, "kill")
  add("COMBATLOG_XPGAIN_FIRSTPERSON_RAID", { "mobName", "total", "raidPenalty" }, "kill")
  -- 4. named kill, rested/RAF bonus
  add("COMBATLOG_XPGAIN_EXHAUSTION1", { "mobName", "total", "bonusAmount", "bonusType" }, "kill")
  add("COMBATLOG_XPGAIN_EXHAUSTION2", { "mobName", "total", "bonusAmount", "bonusType" }, "kill")
  -- 5. named kill, penalty
  add("COMBATLOG_XPGAIN_EXHAUSTION4", { "mobName", "total", "penaltyAmount", "penaltyType" }, "kill")
  add("COMBATLOG_XPGAIN_EXHAUSTION5", { "mobName", "total", "penaltyAmount", "penaltyType" }, "kill")
  -- 6. unnamed WITH bonus (quest turn-ins with an RAF bonus land here)
  add("COMBATLOG_XPGAIN_QUEST", { "total", "bonusAmount", "bonusType" }, "unnamed")
  -- 7. plain named kill
  add("COMBATLOG_XPGAIN_FIRSTPERSON", { "mobName", "total" }, "kill")
  -- 8. unnamed with a group bonus or raid penalty
  add("COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP", { "total", "group" }, "unnamed")
  add("COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID", { "total", "raidPenalty" }, "unnamed")
  -- 9. plain unnamed -- quest AND exploration both look like this
  add("COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED", { "total" }, "unnamed")

  self.patternCount = #patterns
  return patterns
end

function Ledger:Patterns() return patterns end

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

-- Returns a raw parse table, or nil when the message is not an XP gain.
function Ledger:Parse(msg)
  if type(msg) ~= "string" then return nil end
  for i = 1, #patterns do
    local p = patterns[i]
    local c = { string.match(msg, p.pattern) }
    if c[1] ~= nil then
      local out = { kind = p.kind, matched = p.source }
      for j = 1, #p.fields do
        local name = p.fields[j]
        if name == "mobName" or name == "bonusType" or name == "penaltyType" then
          out[name] = c[j]
        else
          out[name] = util.ToNumber(c[j])
        end
      end
      return out
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Source attribution
--
-- Quest and exploration XP are TEXTUALLY IDENTICAL on 3.3.5a -- both render
-- as "You gain %d experience." because the server calls GiveXP(XP, nullptr)
-- for each. We disambiguate from context armed by CHAT_MSG_SYSTEM and the
-- quest events.
-- ---------------------------------------------------------------------------

local armedQuest, armedExplore, lastConsumedAt

function Ledger:NoteQuestFinished(questID, predictedXP)
  armedQuest = { questID = questID, predictedXP = predictedXP, at = GetTime() }
end

function Ledger:NoteExplore(zoneName)
  armedExplore = { zone = zoneName, at = GetTime() }
end

local function takeArmed()
  local now = GetTime()
  if armedQuest and (now - armedQuest.at) <= ATTRIBUTION_WINDOW then
    local a = armedQuest
    armedQuest = nil
    lastConsumedAt = now
    return "quest", a
  end
  if armedExplore and (now - armedExplore.at) <= ATTRIBUTION_WINDOW then
    local a = armedExplore
    armedExplore = nil
    lastConsumedAt = now
    return "explore", a
  end
  -- Expired arms are dropped so they cannot mis-attribute a later gain.
  if armedQuest and (now - armedQuest.at) > ATTRIBUTION_WINDOW then armedQuest = nil end
  if armedExplore and (now - armedExplore.at) > ATTRIBUTION_WINDOW then armedExplore = nil end
  return "unknown", nil
end

-- ---------------------------------------------------------------------------
-- Chat handlers
-- ---------------------------------------------------------------------------

function Ledger:OnChat(msg)
  local raw = self:Parse(msg)
  if not raw then return nil end

  local total = raw.total or 0
  local rested, group = 0, raw.group or 0

  -- The first %s of "(%s exp %s bonus)" is the AMOUNT, the second is the TYPE
  -- label ("Rested", "Refer-A-Friend"). It is NOT a multiplier.
  if raw.bonusAmount then rested = raw.bonusAmount end

  local e = {
    t = GetTime(),
    total = total,
    rested = rested,
    group = group,
    penalty = raw.penaltyAmount or 0,
    -- Recorded for the tooltip only. The total is already net of it.
    raidPenalty = raw.raidPenalty or 0,
    bonusType = raw.bonusType,
    mobName = raw.mobName,
  }

  if raw.kind == "kill" then
    e.source = "kill"
  else
    local src, armed = takeArmed()
    e.source = src
    if armed then
      e.questID = armed.questID
      e.predictedXP = armed.predictedXP
      e.zone = armed.zone
    end
  end

  -- Base is what the mob was actually worth before bonuses. Everything
  -- downstream projects from base, never from total, because rested runs out.
  e.base = total - rested - group
  if e.base < 0 then e.base = 0 end

  util.PushBounded(self.recent, e, RECENT_MAX)
  LP:Fire("XP_EVENT", e)
  return e
end

-- CHAT_MSG_SYSTEM carries the lines that disambiguate an unnamed gain.
local sysQuestComplete, sysQuestXP, sysExplore

function Ledger:BuildSystemPatterns()
  sysQuestComplete = util.ConvertGlobalString(_G.ERR_QUEST_COMPLETE_S or "")
  sysQuestXP       = util.ConvertGlobalString(_G.ERR_QUEST_REWARD_EXP_I or "")
  sysExplore       = util.ConvertGlobalString(_G.ERR_ZONE_EXPLORED_XP or "")
end

function Ledger:HandleSystem(msg)
  if type(msg) ~= "string" then return end
  if sysExplore then
    local zone = string.match(msg, sysExplore)
    if zone then self:NoteExplore(zone); return "explore" end
  end
  if sysQuestXP and string.match(msg, sysQuestXP) then
    -- Quest XP confirmed, but we may not know which quest. Arm without an ID
    -- so at least the source is right; Quests.lua arms the ID separately.
    --
    -- Do NOT re-arm if an arm was just consumed: this system line usually
    -- ARRIVES AFTER the XP message it describes, and a fresh arm would then
    -- steal the next unnamed gain -- typically a zone discovery -- and label
    -- it quest XP.
    local now = GetTime()
    local justConsumed = lastConsumedAt and (now - lastConsumedAt) <= ATTRIBUTION_WINDOW
    if not armedQuest and not justConsumed then self:NoteQuestFinished(nil, nil) end
    return "quest"
  end
  if sysQuestComplete and string.match(msg, sysQuestComplete) then
    return "quest-complete"
  end
end

function Ledger:DumpRecent()
  if #self.recent == 0 then LP:Print("no XP events recorded yet.") return end
  LP:Print("last " .. #self.recent .. " XP events:")
  for i = 1, #self.recent do
    local e = self.recent[i]
    LP:Print(string.format("  %s %s total=%d base=%d rested=%d group=%d",
      e.source, e.mobName or "-", e.total, e.base, e.rested, e.group))
  end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function Ledger:Enable()
  self:BuildPatterns()
  self:BuildSystemPatterns()
  if not CreateFrame then return end
  local f = CreateFrame("Frame", "LevelPaceLedger")
  util.SafeRegisterEvent(f, "CHAT_MSG_COMBAT_XP_GAIN")
  util.SafeRegisterEvent(f, "CHAT_MSG_SYSTEM")
  -- CHAT_MSG_* carries 12 args on 3.3.5a; arg1 is the message.
  f:SetScript("OnEvent", function(_, event, arg1)
    if event == "CHAT_MSG_COMBAT_XP_GAIN" then
      Ledger:OnChat(arg1)
    elseif event == "CHAT_MSG_SYSTEM" then
      Ledger:HandleSystem(arg1)
    end
  end)
  self.frame = f
end

-- Patterns are needed by tests immediately, not only after Enable().
Ledger:BuildPatterns()
Ledger:BuildSystemPatterns()

LP:On("PLAYER_READY", function() Ledger:Enable() end)
