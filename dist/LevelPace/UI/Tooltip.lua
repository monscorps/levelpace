-- LevelPace :: UI/Tooltip
-- The hover detail: where the numbers come from and how much to trust them.

local LP = _G.LevelPace
local util = LP.util

local Tooltip = {}
LP.Tooltip = Tooltip

local WHITE = { 1, 1, 1 }
local GREY  = { 0.65, 0.65, 0.70 }
local GOOD  = { 0.40, 0.90, 0.40 }
local WARN  = { 0.95, 0.85, 0.35 }
local BAD   = { 0.95, 0.45, 0.40 }

local function pair(label, value, c)
  c = c or WHITE
  GameTooltip:AddDoubleLine(label, value, GREY[1], GREY[2], GREY[3], c[1], c[2], c[3])
end

function Tooltip:Show(owner)
  if not GameTooltip then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()

  local r = LP.Estimator and LP.Estimator:Result() or {}
  local H = LP.History
  local rec = H and H:Current()

  GameTooltip:AddLine("LevelPace", 0.27, 0.87, 1)

  -- ---- projection ----
  pair("Time to level", util.FormatTime(r.timeToLevel),
    r.confidence == "good" and GOOD or (r.confidence == "none" and BAD or WARN))
  if r.baseRatePerHour then
    pair("Base XP/hr", util.FormatNumber(r.baseRatePerHour))
  end
  if r.rateSource then
    pair("Rate from", r.rateSource, GREY)
  end
  if r.mobsLow then
    pair("Mobs to level", string.format("%d-%d", r.mobsLow, r.mobsHigh))
    pair("XP per kill", string.format("%s-%s",
      util.FormatNumber(r.xpPerKillLow), util.FormatNumber(r.xpPerKillHigh)), GREY)
  elseif r.killSampleCount then
    pair("Mobs to level", string.format("need 10 kills (%d)", r.killSampleCount), GREY)
  end

  -- ---- modifiers ----
  local mods = LP.Modifiers and LP.Modifiers:Describe() or {}
  if #mods > 0 then
    GameTooltip:AddLine(" ")
    for _, m in ipairs(mods) do GameTooltip:AddLine(m, GREY[1], GREY[2], GREY[3]) end
  end
  if r.restedCovered and r.restedCovered > 0 then
    pair("Rested covers", util.FormatNumber(r.restedCovered) .. " XP of this level", GREY)
  end

  -- ---- this level so far ----
  if rec then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("This level", 1, 1, 1)
    pair("Elapsed", util.FormatTime(H:Elapsed()))
    local total = 0
    for _, v in pairs(rec.xpBySource) do total = total + v end
    if total > 0 then
      pair("From kills", string.format("%s (%.0f%%)",
        util.FormatNumber(rec.xpBySource.kill), rec.xpBySource.kill / total * 100))
      pair("From quests", string.format("%s (%.0f%%)",
        util.FormatNumber(rec.xpBySource.quest), rec.xpBySource.quest / total * 100))
    end
    pair("Kills", tostring(rec.killCount))
    pair("Quests", tostring(rec.questCount))
    if rec.deaths > 0 then
      pair("Deaths", string.format("%d (%s running back)",
        rec.deaths, util.FormatTime(rec.corpseRunSeconds)), BAD)
    end
  end

  -- ---- learned server rates ----
  if LP.Rates then
    GameTooltip:AddLine(" ")
    local q = LP.Rates:GetQuestRate()
    if q then
      local src = LP.Rates:QuestRateSource()
      pair("Server quest rate", string.format("x%.2f%s", q,
        src == "exact" and "" or " (est)"), GOOD)
    else
      pair("Server quest rate", "open a quest reward panel", WARN)
    end
    local k = LP.Rates:GetKillRate()
    if k then pair("Server kill rate", string.format("x%.2f", k), GOOD) end
  end

  -- ---- previous levels ----
  local all = H and H:All() or {}
  if #all > 0 then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Recent levels", 1, 1, 1)
    local from = math.max(1, #all - 4)
    for i = #all, from, -1 do
      local s = H:Summarise(all[i])
      if s then
        pair(string.format("Level %d", s.level), string.format("%s  %.0f%% quests",
          util.FormatTime(s.elapsed), s.questShare * 100), GREY)
      end
    end
  end

  -- ---- honesty ----
  if r.gapWarning then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("Includes a %s gap with no XP.",
      util.FormatTime(r.gapWarning)), BAD[1], BAD[2], BAD[3])
    GameTooltip:AddLine("Nothing is filtered out -- /lp reset to start clean.",
      GREY[1], GREY[2], GREY[3])
  end

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(LP.db.profile.locked and "Locked -- /lp unlock to move"
    or "Drag to move  |  /lp for options", GREY[1], GREY[2], GREY[3])

  GameTooltip:Show()
end

function Tooltip:Hide()
  if GameTooltip then GameTooltip:Hide() end
end
