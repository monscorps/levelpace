-- LevelPace :: UI/Box
-- The slim numbers box, with selectable layouts and per-element theming.

local LP = _G.LevelPace
local util = LP.util

local Box = {}
LP.Box = Box

local BACKDROP = {
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 8, edgeSize = 8,
  insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

local function col(c) return c.r, c.g, c.b, c.a end

-- Order matters: this is the display order in stacked and full layouts.
Box.LINES = {
  { key = "level",       label = "Level" },
  { key = "xpPerHour",   label = "XP/hr" },
  { key = "timeToLevel", label = "To level" },
  { key = "mobsToLevel", label = "Mobs" },
  { key = "rested",      label = "Rested" },
  { key = "topQuest",    label = "Best quest" },
}

function Box:Create()
  if self.frame or not CreateFrame then return self.frame end
  local p = LP.db.profile.box

  local f = CreateFrame("Frame", "LevelPaceBox", UIParent)
  f:SetWidth(240)
  f:SetHeight(100)
  f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetBackdrop(BACKDROP)

  f:SetScript("OnDragStart", function(s)
    if LP.db.profile.locked then return end
    s:StartMoving()
  end)
  f:SetScript("OnDragStop", function(s)
    s:StopMovingOrSizing()
    Box:SavePosition()
  end)
  f:SetScript("OnEnter", function(s) if LP.Tooltip then LP.Tooltip:Show(s) end end)
  f:SetScript("OnLeave", function() if LP.Tooltip then LP.Tooltip:Hide() end end)

  self.frame = f
  self.rows = {}
  for i, spec in ipairs(self.LINES) do
    local row = {}
    row.label = f:CreateFontString("LevelPaceBoxLabel" .. i, "OVERLAY")
    row.value = f:CreateFontString("LevelPaceBoxValue" .. i, "OVERLAY")
    row.label:SetJustifyH("LEFT")
    row.value:SetJustifyH("RIGHT")
    row.spec = spec
    self.rows[i] = row
  end

  self:ApplyStyle()
  self:Update()
  return f
end

function Box:SavePosition()
  local p = LP.db.profile.box
  -- See Bar:SavePosition -- the relative frame is userdata and is discarded.
  local point, _, relPoint, x, y = self.frame:GetPoint()
  p.point, p.relPoint, p.x, p.y = point, relPoint, x, y
end

function Box:ApplyStyle()
  if not self.frame then return end
  local p = LP.db.profile.box
  local f = self.frame

  f:SetBackdropColor(col(p.colors.bg))
  f:SetBackdropBorderColor(col(p.colors.border))
  f:SetScale(p.scale)

  for _, row in ipairs(self.rows) do
    row.label:SetFont(p.font, p.fontSize, p.outline)
    row.value:SetFont(p.font, p.fontSize, p.outline)
    row.label:SetTextColor(col(p.colors.label))
    row.value:SetTextColor(col(p.colors.value))
  end
  self:Relayout()
end

function Box:Relayout()
  if not self.frame then return end
  local p = LP.db.profile.box
  local f = self.frame
  local pad, gap = 8, p.spacing
  local lineH = p.fontSize + 4

  local visible = {}
  for _, row in ipairs(self.rows) do
    row.label:Hide(); row.value:Hide()
    if p.lines[row.spec.key] then visible[#visible + 1] = row end
  end

  if p.layout == "compact" then
    -- Everything on one line, values only, separated by a dot.
    local width = 0
    local first = visible[1]
    if first then
      first.label:SetPoint("LEFT", f, "LEFT", pad, 0)
      first.label:Show()
      width = 260
    end
    f:SetWidth(width > 0 and width or 120)
    f:SetHeight(lineH + pad)
    return
  end

  local y = -pad
  for _, row in ipairs(visible) do
    row.label:ClearAllPoints()
    row.value:ClearAllPoints()
    if p.layout == "full" then
      row.label:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y)
      row.value:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad, y)
    else -- stacked: label and value share the line, value right-aligned
      row.label:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y)
      row.value:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad, y)
    end
    row.label:Show(); row.value:Show()
    y = y - lineH - gap
  end

  f:SetWidth(p.layout == "full" and 260 or 220)
  f:SetHeight(math.max(lineH + pad * 2, -y + pad))
end

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------

local function questLine()
  if not LP.Quests then return "--" end
  local best = LP.Quests:Best()
  if not best then return "none" end
  if best.complete then return best.title .. " (turn in)" end
  if not best.xpPerMin then return best.title .. " (?)" end
  return string.format("%s  %s/min", best.title, util.FormatNumber(best.xpPerMin))
end

function Box:Values()
  local r = LP.Estimator and LP.Estimator:Result() or {}
  local level = UnitLevel and UnitLevel("player") or 0
  local pool = LP.Modifiers and LP.Modifiers:GetRestedPool() or 0

  if r.maxLevel then
    return {
      level = string.format("%d  (max)", level),
      xpPerHour = "--", timeToLevel = "--", mobsToLevel = "--",
      rested = "--", topQuest = "--",
    }
  end
  if r.xpDisabled then
    return {
      level = string.format("%d  (XP off)", level),
      xpPerHour = "--", timeToLevel = "XP is turned off", mobsToLevel = "--",
      rested = "--", topQuest = "--",
    }
  end

  local mobs = "--"
  if r.mobsLow and r.mobsHigh then
    mobs = (r.mobsLow == r.mobsHigh) and tostring(r.mobsLow)
      or string.format("%d-%d", r.mobsLow, r.mobsHigh)
  elseif r.killSampleCount and r.killSampleCount > 0 then
    mobs = string.format("(%d kills)", r.killSampleCount)
  end

  return {
    level = string.format("%d  (%.1f%%)", level, r.percent or 0),
    xpPerHour = r.baseRatePerHour and util.FormatNumber(r.baseRatePerHour) or "--",
    timeToLevel = util.FormatTime(r.timeToLevel),
    mobsToLevel = mobs,
    rested = pool > 0 and util.FormatNumber(pool) or "none",
    topQuest = questLine(),
  }
end

function Box:Update()
  if not self.frame then return end
  local p = LP.db.profile.box
  if not p.shown then self.frame:Hide(); return end
  self.frame:Show()

  local v = self:Values()
  local r = LP.Estimator and LP.Estimator:Result() or {}

  if p.layout == "compact" then
    local first = self.rows[1]
    if first then
      first.label:SetText(string.format("%s  |cffaaaaaa/|r  %s/hr  |cffaaaaaa/|r  %s",
        v.level, v.xpPerHour, v.timeToLevel))
    end
  else
    for _, row in ipairs(self.rows) do
      row.label:SetText(row.spec.label)
      row.value:SetText(v[row.spec.key] or "--")
    end
    -- Colour the time-to-level by how much we trust it.
    for _, row in ipairs(self.rows) do
      if row.spec.key == "timeToLevel" then
        local c = p.colors.neutral
        if r.confidence == "good" then c = p.colors.good
        elseif r.confidence == "none" then c = p.colors.bad end
        row.value:SetTextColor(col(c))
      end
    end
  end
end

LP:On("PLAYER_READY", function() Box:Create() end)
LP:On("TICK", function() Box:Update() end)
LP:On("XP_EVENT", function() Box:Update() end)
LP:On("QUESTS_SCANNED", function() Box:Update() end)
LP:On("STYLE_CHANGED", function() Box:ApplyStyle(); Box:Update() end)
LP:On("TOGGLE_SHOWN", function(shown)
  LP.db.profile.box.shown = shown
  Box:Update()
end)
