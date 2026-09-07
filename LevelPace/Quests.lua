-- LevelPace :: Quests
--
-- The reason this addon exists: rank the quests in your log by XP per minute
-- of MEASURED effort, against your measured grind rate.
--
-- Effort is measured by watching objective counters tick ("3/10 slain" ->
-- 4/10 -> 5/10) and timing them. That naturally includes travel, respawn
-- waits, deaths and bad luck, because it measures wall-clock between real
-- progress -- which is consistent with the rest of the addon refusing to
-- sanitise anything.
--
-- Quests with no countable objective (escorts, "speak to X", "explore Y")
-- cannot be timed. They are shown with their XP and an explicit "?" rather
-- than being given an invented number.

local LP = _G.LevelPace
local util = LP.util

local Quests = {}
LP.Quests = Quests

local MIN_TICKS_FOR_MEASURED = 3
local SCAN_DEBOUNCE = 1.0

Quests.cache = {}     -- [questID] = quest entry from the last scan
Quests.progress = {}  -- [questID] = { ticks = {{t, have}}, firstT, lastT }

-- ---------------------------------------------------------------------------
-- Objective parsing
--
-- Order matters: QUEST_OBJECTS_FOUND is "%s: %d/%d", which is generic enough
-- to also match "Ravenous Ghoul slain: 3/10" with the name captured as
-- "Ravenous Ghoul slain". Specific patterns first.
-- ---------------------------------------------------------------------------

local objPatterns

function Quests:BuildPatterns()
  objPatterns = {}
  for _, g in ipairs { "QUEST_MONSTERS_KILLED", "QUEST_ITEMS_NEEDED", "QUEST_OBJECTS_FOUND" } do
    local fmt = _G[g]
    if type(fmt) == "string" then
      local pat = util.ConvertGlobalString(fmt)
      local dup = false
      for _, p in ipairs(objPatterns) do if p.pattern == pat then dup = true end end
      if not dup then objPatterns[#objPatterns + 1] = { pattern = pat, source = g } end
    end
  end
  return objPatterns
end

-- Returns name, have, need -- or nil when the objective is not countable.
function Quests:ParseObjective(text)
  if type(text) ~= "string" then return nil end
  for _, p in ipairs(objPatterns or {}) do
    local name, have, need = string.match(text, p.pattern)
    if name and have and need then
      return name, tonumber(have), tonumber(need)
    end
  end
  -- Last-ditch generic "n/m" anywhere in the line, for locales or objective
  -- kinds whose format string we do not have.
  local have, need = string.match(text, "(%d+)%s*/%s*(%d+)")
  if have and need then
    return text, tonumber(have), tonumber(need)
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------

function Quests:Scan()
  local out = {}
  if not GetNumQuestLogEntries then return out end

  -- SelectQuestLogEntry moves the USER'S visible selection. Blizzard's own
  -- WatchFrame_AbandonQuest saves and restores it; not doing so makes the
  -- quest log visibly jump every scan.
  local prevSelection = GetQuestLogSelection and GetQuestLogSelection() or nil

  local ok, err = pcall(function()
    local numEntries = GetNumQuestLogEntries()
    for i = 1, numEntries do
      local title, level, _, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
      if title and not isHeader then
        SelectQuestLogEntry(i)
        local xp = GetQuestLogRewardXP and GetQuestLogRewardXP() or 0

        local objectives = {}
        local remaining, countable = 0, false
        local n = GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i) or 0
        for j = 1, n do
          local text, objType, finished = GetQuestLogLeaderBoard(j, i)
          local name, have, need = self:ParseObjective(text)
          if name then
            countable = true
            remaining = remaining + math.max(0, (need or 0) - (have or 0))
            objectives[#objectives + 1] =
              { text = text, name = name, have = have, need = need, objType = objType, finished = finished }
          else
            objectives[#objectives + 1] =
              { text = text, objType = objType, finished = finished, countable = false }
          end
        end

        out[#out + 1] = {
          index = i,
          questID = questID,
          title = title,
          level = level,
          xp = xp or 0,
          complete = isComplete and true or false,
          objectives = objectives,
          countable = countable,
          remainingTicks = remaining,
        }
      end
    end
  end)

  if prevSelection and SelectQuestLogEntry then SelectQuestLogEntry(prevSelection) end
  if not ok and LP.debug then LP:Print("quest scan error: " .. tostring(err)) end

  -- Record progress deltas so effort can be timed.
  for _, q in ipairs(out) do
    if q.questID and q.countable then
      local done = 0
      for _, o in ipairs(q.objectives) do done = done + (o.have or 0) end
      self:NoteProgress(q.questID, done)
    end
  end

  self.cache = {}
  for _, q in ipairs(out) do
    if q.questID then self.cache[q.questID] = q end
  end
  self.list = out
  LP:Fire("QUESTS_SCANNED", out)
  return out
end

-- ---------------------------------------------------------------------------
-- Effort measurement
-- ---------------------------------------------------------------------------

function Quests:NoteProgress(questID, doneCount, now)
  now = now or (GetTime and GetTime()) or 0
  local p = self.progress[questID]
  if not p then
    self.progress[questID] = { ticks = { { t = now, have = doneCount } } }
    return
  end
  local last = p.ticks[#p.ticks]
  -- Only a genuine increase counts as a tick. A rescan with no change tells
  -- us nothing about pace.
  if doneCount > last.have then
    p.ticks[#p.ticks + 1] = { t = now, have = doneCount }
    while #p.ticks > 40 do table.remove(p.ticks, 1) end
  end
end

-- Progress units per second on this specific quest, or nil.
function Quests:TickRate(questID)
  local p = self.progress[questID]
  if not p or #p.ticks < 2 then return nil, 0 end
  local first, last = p.ticks[1], p.ticks[#p.ticks]
  local dt = last.t - first.t
  local dv = last.have - first.have
  if dt <= 0 or dv <= 0 then return nil, #p.ticks - 1 end
  return dv / dt, #p.ticks - 1
end

-- Median tick rate across every quest we have measured. Used to infer effort
-- for a quest we have barely started.
function Quests:GlobalTickRate()
  local rates = {}
  for questID in pairs(self.progress) do
    local rate, ticks = self:TickRate(questID)
    if rate and ticks >= MIN_TICKS_FOR_MEASURED then rates[#rates + 1] = rate end
  end
  return util.Median(rates)
end

-- Returns minutes, tier, reason.
--   "measured"     -- timed on this quest
--   "inferred"     -- timed from your pace on other quests
--   "unmeasurable" -- no countable objective, or nothing measured yet
function Quests:EstimateMinutes(questID)
  local q = self.cache[questID]
  if not q then return nil, "unmeasurable", "not in log" end
  if q.complete then return 0, "measured", "ready to turn in" end
  if not q.countable then
    return nil, "unmeasurable", "no countable objective"
  end
  if q.remainingTicks <= 0 then return 0, "measured", "objectives done" end

  local rate, ticks = self:TickRate(questID)
  if rate and ticks >= MIN_TICKS_FOR_MEASURED then
    return q.remainingTicks / rate / 60, "measured", nil
  end

  local global = self:GlobalTickRate()
  if global and global > 0 then
    return q.remainingTicks / global / 60, "inferred", "using your pace on other quests"
  end

  return nil, "unmeasurable", "not enough progress observed yet"
end

-- ---------------------------------------------------------------------------
-- Ranking
-- ---------------------------------------------------------------------------

-- The XP you would ACTUALLY receive: the client's prediction, times the
-- learned server quest rate, times the heirloom bonus (which the client
-- prediction does not include).
function Quests:EffectiveXP(q)
  local rate = LP.Rates and LP.Rates:GetQuestRate()
  local mult = LP.Modifiers and LP.Modifiers:HeirloomMultiplier() or 1
  local learning = (rate == nil)
  return q.xp * (rate or 1) * mult, learning
end

function Quests:Rank(grindXPPerMin)
  local ready, worth, slower = {}, {}, {}
  for _, q in ipairs(self.list or {}) do
    local effXP, learning = self:EffectiveXP(q)
    local minutes, tier, reason = self:EstimateMinutes(q.questID)
    local entry = {
      questID = q.questID, title = q.title, level = q.level,
      xp = q.xp, effectiveXP = effXP, learning = learning,
      minutes = minutes, tier = tier, reason = reason,
      complete = q.complete, remainingTicks = q.remainingTicks,
    }
    -- No fabricated rate for something we could not time.
    if minutes and minutes > 0 then
      entry.xpPerMin = effXP / minutes
    else
      entry.xpPerMin = nil
    end

    if q.complete then
      ready[#ready + 1] = entry
    elseif entry.xpPerMin and grindXPPerMin and entry.xpPerMin > grindXPPerMin then
      worth[#worth + 1] = entry
    else
      slower[#slower + 1] = entry
    end
  end

  local function byValue(a, b)
    if a.xpPerMin and b.xpPerMin then return a.xpPerMin > b.xpPerMin end
    if a.xpPerMin then return true end   -- rated beats unrated
    if b.xpPerMin then return false end
    return (a.effectiveXP or 0) > (b.effectiveXP or 0)
  end
  table.sort(ready, function(a, b) return (a.effectiveXP or 0) > (b.effectiveXP or 0) end)
  table.sort(worth, byValue)
  table.sort(slower, byValue)

  return { ready = ready, worth = worth, slower = slower, grindXPPerMin = grindXPPerMin }
end

-- The grind rate to compare against. Rested doubles kill XP but does NOT
-- apply to quest XP, so while rested the grind side is genuinely worth more.
function Quests:GrindBaseline()
  local perMin = LP.Estimator and LP.Estimator:GrindXPPerMinute()
  if not perMin then return nil, false end
  local rested = LP.Modifiers and LP.Modifiers:IsRested() or false
  return perMin * (rested and 2 or 1), rested
end

function Quests:Best()
  local baseline = self:GrindBaseline()
  local r = self:Rank(baseline)
  return r.worth[1] or r.ready[1] or r.slower[1]
end

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

function Quests:PrintRanking()
  self:Scan()
  local baseline, rested = self:GrindBaseline()
  local r = self:Rank(baseline)

  local function fmt(e)
    local xp = util.FormatNumber(e.effectiveXP)
    local mins = e.minutes and string.format("~%.0f min", e.minutes) or "?"
    local rate = e.xpPerMin and util.FormatNumber(e.xpPerMin) .. "/min" or "?"
    local mark = (e.tier == "inferred") and " |cff888888(est)|r" or ""
    return string.format("  %s  |cffffffff%s XP|r  %s  |cff44ddff%s|r%s",
      e.title, xp, mins, rate, mark)
  end

  if #r.ready > 0 then
    LP:Print("|cff40e040Ready to turn in|r")
    for _, e in ipairs(r.ready) do
      LP:Print(string.format("  %s  |cffffffff%s XP|r", e.title, util.FormatNumber(e.effectiveXP)))
    end
  end
  if #r.worth > 0 then
    LP:Print("|cff40e040Worth doing|r")
    for _, e in ipairs(r.worth) do LP:Print(fmt(e)) end
  end
  if #r.slower > 0 then
    LP:Print("|cffe0a040Slower than grinding|r")
    for _, e in ipairs(r.slower) do LP:Print(fmt(e)) end
  end
  if #r.ready == 0 and #r.worth == 0 and #r.slower == 0 then
    LP:Print("no quests in your log.")
  end

  if baseline then
    LP:Print(string.format("grinding here: |cff44ddff%s/min|r%s",
      util.FormatNumber(baseline), rested and " |cffa080ff(rested x2)|r" or ""))
  else
    LP:Print("grinding rate not measured yet -- kill a few mobs.")
  end
  if LP.Rates and not LP.Rates:GetQuestRate() then
    LP:Print("|cffe0a040server quest rate unknown -- open any quest's reward panel to read it|r")
  end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

Quests:BuildPatterns()

-- Map the currently-open questgiver window back to a quest log entry by
-- title. There is no questgiver-side quest ID on 3.3.5a, so the title is the
-- only handle.
--
-- Requires a UNIQUE match: two quests with the same title would give us the
-- wrong blizzlike XP and poison the calibration, so an ambiguous match is
-- treated as no match.
function Quests:ResolvePending()
  if not GetTitleText then return nil end
  local ok, title = pcall(GetTitleText)
  if not ok or not title or title == "" then return nil end
  local foundID, foundQ, matches = nil, nil, 0
  for questID, q in pairs(self.cache) do
    if q.title == title then
      matches = matches + 1
      foundID, foundQ = questID, q
    end
  end
  if matches ~= 1 then return nil end
  return foundID, foundQ
end

-- Read the server's quest multiplier EXACTLY, by comparing the two APIs that
-- deliberately disagree:
--
--   GetRewardXP()          server truth, already multiplied by Rate.XP.Quest
--                          and by any SPELL_AURA_MOD_XP_QUEST_PCT auras
--   GetQuestLogRewardXP()  blizzlike, recomputed client-side from QuestXP.dbc
--
-- Their ratio is the multiplier. One clean sample is the answer -- this does
-- not need a turn-in, and it does not need the XP to be observed at all.
--
-- Valid at QUEST_COMPLETE, where the quest is still in the log so the
-- blizzlike side is readable.
function Quests:Calibrate()
  local questID, q = self:ResolvePending()
  if not q or not q.xp or q.xp <= 0 then return nil end
  if not GetRewardXP then return nil end
  local ok, rated = pcall(GetRewardXP)
  if not ok or not rated or rated <= 0 then return nil end

  local mult = LP.Modifiers and LP.Modifiers:HeirloomMultiplier() or 1
  LP.Rates:AddQuestRatioSample(rated, q.xp, mult)
  return questID, q.xp, rated
end

function Quests:Enable()
  self:BuildPatterns()
  if not CreateFrame then return end

  -- Arm XP attribution at the moment of turn-in. GetQuestReward is a plain
  -- unprotected global on 3.3.5a, called from ordinary click handlers.
  --
  -- The value passed is the BLIZZLIKE xp captured at QUEST_COMPLETE, NOT
  -- GetRewardXP(). GetRewardXP is already multiplied by the server rate, so
  -- comparing it against the XP actually received would always yield x1 and
  -- the fallback learner would silently report a x5 server as blizzlike.
  if hooksecurefunc then
    hooksecurefunc("GetQuestReward", function()
      LP.Ledger:NoteQuestFinished(Quests.pendingQuestID, Quests.pendingBlizzXP)
    end)
  end

  local f = CreateFrame("Frame", "LevelPaceQuests")
  util.SafeRegisterEvent(f, "QUEST_LOG_UPDATE")
  util.SafeRegisterEvent(f, "QUEST_COMPLETE")
  util.SafeRegisterEvent(f, "QUEST_FINISHED")
  local dirty = false
  f:SetScript("OnEvent", function(_, event)
    if event == "QUEST_LOG_UPDATE" then
      dirty = true
    elseif event == "QUEST_COMPLETE" then
      -- The questgiver window is open on the quest we are about to hand in.
      -- This is the one moment both XP APIs are readable for the same quest.
      local questID, blizz = Quests:Calibrate()
      Quests.pendingQuestID = questID
      Quests.pendingBlizzXP = blizz
    elseif event == "QUEST_FINISHED" then
      Quests.pendingQuestID = nil
      Quests.pendingBlizzXP = nil
    end
  end)
  -- Debounced: a full scan touches every quest and moves the log selection,
  -- so it must not run per frame.
  LP:Schedule(SCAN_DEBOUNCE, function()
    if dirty then dirty = false; Quests:Scan() end
  end)
  self.frame = f
end

LP:On("PLAYER_READY", function() Quests:Enable() end)
