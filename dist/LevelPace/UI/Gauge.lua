-- LevelPace :: UI/Gauge
--
-- A toggleable bar showing your current pace as a WarcraftLogs-style parse:
-- a fill whose length is the percentile and whose colour is the band.

local LP = _G.LevelPace
local util = LP.util

local Gauge = {}
LP.Gauge = Gauge

local BACKDROP = {
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 8, edgeSize = 8,
  insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

local function col(c) return c.r, c.g, c.b, c.a end

function Gauge:Create()
  if self.holder or not CreateFrame then return self.holder end
  local p = LP.db.profile.gauge

  local holder = CreateFrame("Frame", "LevelPaceGaugeHolder", UIParent)
  holder:SetWidth(p.width)
  holder:SetHeight(p.height)
  holder:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
  holder:SetFrameStrata("MEDIUM")
  holder:SetClampedToScreen(true)
  holder:SetMovable(true)
  holder:EnableMouse(true)
  holder:RegisterForDrag("LeftButton")
  holder:SetBackdrop(BACKDROP)
  holder:SetScript("OnDragStart", function(f)
    if LP.db.profile.locked then return end
    f:StartMoving()
  end)
  holder:SetScript("OnDragStop", function(f)
    f:StopMovingOrSizing()
    local point, _, relPoint, x, y = f:GetPoint()
    local g = LP.db.profile.gauge
    g.point, g.relPoint, g.x, g.y = point, relPoint, x, y
  end)
  holder:SetScript("OnEnter", function(f) Gauge:ShowTooltip(f) end)
  holder:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  local bar = CreateFrame("StatusBar", "LevelPaceGauge", holder)
  bar:SetPoint("TOPLEFT", holder, "TOPLEFT", 2, -2)
  bar:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -2, 2)
  bar:SetStatusBarTexture(LP.db.profile.bar.texture)
  bar:SetMinMaxValues(0, 100)
  bar:SetValue(0)

  local text = bar:CreateFontString("LevelPaceGaugeText", "OVERLAY")
  text:SetPoint("CENTER", bar, "CENTER", 0, 0)

  self.holder, self.bar, self.text = holder, bar, text
  self:ApplyStyle()
  self:Update()
  return holder
end

function Gauge:ApplyStyle()
  if not self.holder then return end
  local p = LP.db.profile.gauge
  local box = LP.db.profile.box
  self.holder:SetWidth(p.width)
  self.holder:SetHeight(p.height)
  self.holder:SetBackdropColor(col(LP.db.profile.bar.colors.bg))
  self.holder:SetBackdropBorderColor(col(LP.db.profile.bar.colors.border))
  self.bar:SetStatusBarTexture(LP.db.profile.bar.texture)
  self.text:SetFont(box.font, math.max(7, box.fontSize), box.outline)
end

function Gauge:Update()
  if not self.holder then return end
  if not LP.db.profile.gauge.shown then self.holder:Hide(); return end
  self.holder:Show()

  local pct, band, lph, label, n = LP.Parse:Current()

  if not pct then
    -- No baseline yet. Show an empty grey bar rather than implying a score.
    self.bar:SetValue(0)
    self.bar:SetStatusBarColor(0.3, 0.3, 0.3, 1)
    local need = LP.Parse.MIN_BASELINE - (n or 0)
    self.text:SetText(lph
      and string.format("|cff888888no baseline (%d more level%s)|r",
            need, need == 1 and "" or "s")
      or "|cff888888measuring...|r")
    self.text:SetTextColor(1, 1, 1)
    return
  end

  self.bar:SetValue(pct)
  self.bar:SetStatusBarColor(band.r, band.g, band.b, 1)
  self.text:SetText(string.format("%d  %s", math.floor(pct + 0.5), band.name))
  self.text:SetTextColor(1, 1, 1)
end

function Gauge:ShowTooltip(owner)
  if not GameTooltip then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:AddLine("Pace parse", 0.27, 0.87, 1)

  local pct, band, lph, label, n = LP.Parse:Current()
  if pct then
    GameTooltip:AddDoubleLine("Percentile",
      LP.Parse:Colorize(pct, string.format("%d  (%s)", math.floor(pct + 0.5), band.name)),
      0.65, 0.65, 0.7, 1, 1, 1)
  else
    GameTooltip:AddLine("Not enough history to score yet.", 0.95, 0.85, 0.35)
    GameTooltip:AddLine(string.format("Needs %d completed levels; you have %d.",
      LP.Parse.MIN_BASELINE, n or 0), 0.65, 0.65, 0.7)
  end
  if lph then
    GameTooltip:AddDoubleLine("Pace", string.format("%.2f levels/hr", lph),
      0.65, 0.65, 0.7, 1, 1, 1)
  end
  GameTooltip:AddDoubleLine("Compared against", label or "--", 0.65, 0.65, 0.7, 0.8, 0.8, 0.8)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Measured in levels per hour, not XP per hour, so it is",
    0.65, 0.65, 0.7)
  GameTooltip:AddLine("comparable across levels and across server rates.",
    0.65, 0.65, 0.7)
  GameTooltip:Show()
end

LP:On("PLAYER_READY", function() Gauge:Create() end)
LP:On("TICK", function() Gauge:Update() end)
LP:On("STYLE_CHANGED", function() Gauge:ApplyStyle(); Gauge:Update() end)
