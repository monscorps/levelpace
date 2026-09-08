-- LevelPace :: UI/Bar
-- A slim, movable, themeable XP bar.

local LP = _G.LevelPace
local util = LP.util

local Bar = {}
LP.Bar = Bar

local BACKDROP = {
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 8, edgeSize = 8,
  insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

local function col(c) return c.r, c.g, c.b, c.a end

function Bar:Create()
  if self.frame or not CreateFrame then return self.frame end
  local p = LP.db.profile.bar

  -- Holder carries the backdrop and the drag behaviour; the StatusBar sits
  -- inside it so the border does not clip the fill.
  local holder = CreateFrame("Frame", "LevelPaceBarHolder", UIParent)
  holder:SetWidth(p.width)
  holder:SetHeight(p.height)
  holder:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
  holder:SetFrameStrata("MEDIUM")
  holder:SetClampedToScreen(true)
  holder:SetMovable(true)
  holder:EnableMouse(true)
  holder:RegisterForDrag("LeftButton")
  -- SetBackdrop is a native frame method on 3.3.5a -- no BackdropTemplate.
  holder:SetBackdrop(BACKDROP)

  holder:SetScript("OnDragStart", function(f)
    if LP.db.profile.locked then return end
    f:StartMoving()
  end)
  holder:SetScript("OnDragStop", function(f)
    f:StopMovingOrSizing()
    Bar:SavePosition()
  end)
  holder:SetScript("OnEnter", function(f) if LP.Tooltip then LP.Tooltip:Show(f) end end)
  holder:SetScript("OnLeave", function() if LP.Tooltip then LP.Tooltip:Hide() end end)

  local bar = CreateFrame("StatusBar", "LevelPaceBar", holder)
  bar:SetPoint("TOPLEFT", holder, "TOPLEFT", 2, -2)
  bar:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -2, 2)
  bar:SetStatusBarTexture(p.texture)
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)

  -- Rested overlay: a Texture on the BORDER layer INSIDE the StatusBar,
  -- which is how Blizzard does it in MainMenuBar.lua rather than stacking a
  -- second StatusBar.
  local rested = bar:CreateTexture("LevelPaceBarRested", "BORDER")
  rested:SetTexture(p.texture)
  rested:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
  rested:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
  rested:SetWidth(1)
  rested:Hide()

  local text = bar:CreateFontString("LevelPaceBarText", "OVERLAY")
  text:SetPoint("CENTER", bar, "CENTER", 0, 0)

  self.holder, self.frame, self.rested, self.text = holder, bar, rested, text
  self:ApplyStyle()
  self:Update()
  return holder
end

function Bar:SavePosition()
  local p = LP.db.profile.bar
  -- Frames are always anchored to UIParent, so only the offsets are stored.
  -- GetPoint's second return is the relative frame as USERDATA and must never
  -- reach SavedVariables -- it is deliberately discarded here.
  local point, _, relPoint, x, y = self.holder:GetPoint()
  p.point, p.relPoint, p.x, p.y = point, relPoint, x, y
end

function Bar:ApplyStyle()
  if not self.frame then return end
  local p = LP.db.profile.bar
  local box = LP.db.profile.box

  self.holder:SetWidth(p.width)
  self.holder:SetHeight(p.height)
  self.holder:SetBackdropColor(col(p.colors.bg))
  self.holder:SetBackdropBorderColor(col(p.colors.border))

  self.frame:SetStatusBarTexture(p.texture)
  self.frame:SetStatusBarColor(col(p.colors.fill))

  self.rested:SetTexture(p.texture)
  self.rested:SetVertexColor(col(p.colors.rested))

  self.text:SetFont(box.font, math.max(7, box.fontSize - 1), box.outline)
  self.text:SetTextColor(col(box.colors.value))
end

function Bar:Update()
  -- Owned by the levelpace module; do not draw while it is off.
  if LP.ModuleOff and LP:ModuleOff("levelpace") then
    if self.holder then self.holder:Hide() end
    return
  end
  if not self.frame or not UnitXP then return end

  -- Visibility is decided FIRST. It used to sit after the max-level early
  -- return, so at level 80 (where UnitXPMax is 0) the bar could never be
  -- hidden by /lp hide or by unticking it in the options.
  if LP.db.profile.bar.shown then self.holder:Show() else self.holder:Hide() end

  local xp, xpMax = UnitXP("player"), UnitXPMax("player")
  if not xpMax or xpMax <= 0 then
    -- Max level: nothing to fill.
    self.frame:SetMinMaxValues(0, 1)
    self.frame:SetValue(0)
    self.rested:Hide()
    self.text:SetText(MAX_PLAYER_LEVEL and ("Level " .. (UnitLevel("player") or "")) or "")
    return
  end

  self.frame:SetMinMaxValues(0, xpMax)
  self.frame:SetValue(xp)

  -- The rested overlay spans the portion of the REMAINING bar that will be
  -- earned at double speed. A pool of P doubles P base into 2P total, so the
  -- marker covers 2P of bar, clamped to the level.
  local pool = LP.Modifiers and LP.Modifiers:GetRestedPool() or 0
  local width = self.frame:GetWidth() or 0
  if pool > 0 and width > 0 then
    local covered = math.min(2 * pool, xpMax - xp)
    local startFrac = xp / xpMax
    local coverFrac = covered / xpMax
    self.rested:ClearAllPoints()
    self.rested:SetPoint("TOPLEFT", self.frame, "TOPLEFT", startFrac * width, 0)
    self.rested:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", startFrac * width, 0)
    self.rested:SetWidth(math.max(1, coverFrac * width))
    self.rested:Show()
  else
    self.rested:Hide()
  end

  local pct = xp / xpMax * 100
  self.text:SetText(string.format("%s / %s  (%.1f%%)",
    util.FormatNumber(xp), util.FormatNumber(xpMax), pct))
end

LP:On("PLAYER_READY", function()
  Bar:Create()
  if not CreateFrame then return end
  local f = CreateFrame("Frame", "LevelPaceBarEvents")
  util.SafeRegisterEvent(f, "PLAYER_XP_UPDATE")
  util.SafeRegisterEvent(f, "UPDATE_EXHAUSTION")
  util.SafeRegisterEvent(f, "PLAYER_LEVEL_UP")
  f:SetScript("OnEvent", function() Bar:Update() end)
end)

-- Redraw on the shared heartbeat so the countdown moves while idle.
LP:On("TICK", function() Bar:Update() end)

LP:On("XP_EVENT", function() Bar:Update() end)
LP:On("STYLE_CHANGED", function() Bar:ApplyStyle(); Bar:Update() end)
LP:On("TOGGLE_SHOWN", function(shown)
  LP.db.profile.bar.shown = shown
  Bar:Update()
end)
