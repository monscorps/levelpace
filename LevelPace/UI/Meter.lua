-- LevelPace :: UI/Meter
--
-- The always-on panel. Behaves like a damage meter: it sits there, you move
-- and resize it, it remembers where it was, and you cycle views by clicking
-- the header.
--
-- Three things this gets right that a naive version would not:
--
--   1. It does NOTHING while hidden. The refresh walks the battleground
--      scoreboard, and that runs once a second, in a 40-player battleground,
--      forever. A hidden panel that still scans is a frame-rate bug nobody
--      will ever attribute to this addon.
--   2. Row frames are pooled. Frames are never garbage collected on 3.3.5a,
--      so a redraw that allocates leaks for the whole session.
--   3. Rows are capped. A leaderboard with 400 entries must not try to build
--      400 status bars.

local LP = _G.LevelPace
LP.Meter = LP.Meter or {}
local M = LP.Meter

local UI = LP.UI

M.MAX_ROWS   = 25
M.MIN_WIDTH  = 160
M.MIN_HEIGHT = 80
M.ROW_H      = 14

local REFRESH_SECONDS = 1

M.defaults = {
  shown = false,
  view = "bgdamage",
  width = 240, height = 200,
  point = "RIGHT", relPoint = "RIGHT", x = -20, y = 0,
  scale = 1.0,
  font = "Fonts\\FRIZQT__.TTF",
  fontSize = 11,
  outline = "",
  colors = {
    bg     = { r = 0.03, g = 0.03, b = 0.05, a = 0.80 },
    header = { r = 1.00, g = 0.82, b = 0.30, a = 1.00 },
    text   = { r = 1.00, g = 1.00, b = 1.00, a = 1.00 },
    you    = { r = 1.00, g = 0.96, b = 0.62, a = 1.00 },
    barBG  = { r = 0.12, g = 0.12, b = 0.15, a = 0.70 },
  },
}

if LP.defaults and LP.defaults.profile then
  LP.defaults.profile.meter = M.defaults
end

local function cfg()
  local p = LP.db and LP.db.profile
  return (p and p.meter) or M.defaults
end

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

M.views = {}

function M:AddView(v)
  for i = 1, #self.views do
    if self.views[i].id == v.id then self.views[i] = v; return v end
  end
  self.views[#self.views + 1] = v
  return v
end

function M:Views() return self.views end

function M:Current()
  local want = cfg().view
  for i = 1, #self.views do
    if self.views[i].id == want then return want end
  end
  -- A view removed in an update must not leave the panel blank forever.
  return self.views[1] and self.views[1].id or nil
end

function M:Select(id)
  for i = 1, #self.views do
    if self.views[i].id == id then
      cfg().view = id
      self:Refresh()
      return true
    end
  end
  return false
end

function M:Cycle(step)
  local cur, idx = self:Current(), 1
  for i = 1, #self.views do
    if self.views[i].id == cur then idx = i break end
  end
  idx = idx + (step or 1)
  while idx > #self.views do idx = idx - #self.views end
  while idx < 1 do idx = idx + #self.views end
  return self:Select(self.views[idx].id)
end

function M:Rows()
  local id = self:Current()
  if not id then return {} end
  for i = 1, #self.views do
    if self.views[i].id == id then
      -- A broken view must not take the panel down with it.
      local ok, rows = pcall(self.views[i].rows)
      if not ok or type(rows) ~= "table" then return {} end
      while #rows > M.MAX_ROWS do table.remove(rows) end
      return rows
    end
  end
  return {}
end

function M:CurrentTitle()
  local id = self:Current()
  for i = 1, #self.views do
    if self.views[i].id == id then return self.views[i].title end
  end
  return "LevelPace"
end

-- ---------------------------------------------------------------------------
-- Built-in views
-- ---------------------------------------------------------------------------

local function bgRows(field, requireNonZero)
  local N = LP.Nemesis
  if not N or not N.ScanTeam then return {} end
  local team = N:ScanTeam()
  local me = UnitName and UnitName("player") or nil

  local rows, values = {}, {}
  for i = 1, #team do
    local v = team[i][field] or 0
    if (not requireNonZero) or v > 0 then
      rows[#rows + 1] = { name = team[i].name, value = v, isYou = (team[i].name == me) }
      values[#values + 1] = v
    end
  end
  table.sort(rows, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.name < b.name
  end)

  local top = rows[1] and rows[1].value or 0
  for i = 1, #rows do
    local pct = LP.util.RankPercentile(rows[i].value, values)
    rows[i].pct = pct
    rows[i].band = pct and LP.data and LP.data.BandFor and LP.data.BandFor(pct) or nil
    -- The bar length is share-of-top, like a damage meter. The COLOUR is the
    -- percentile band. Length answers "how far behind the leader"; colour
    -- answers "how good is that". They are different questions.
    rows[i].fill = (top > 0) and (rows[i].value / top * 100) or 0
    rows[i].label = LP.util.FormatNumber(rows[i].value)
  end
  return rows
end

M:AddView({ id = "bgdamage",  title = "BG damage",
            rows = function() return bgRows("damage", false) end })
M:AddView({ id = "bghealing", title = "BG healing",
            rows = function() return bgRows("healing", true) end })
M:AddView({ id = "bgkills",   title = "BG killing blows",
            rows = function() return bgRows("killingBlows", false) end })

M:AddView({ id = "rares", title = "Rare kills", rows = function()
  local RF = LP.RareFinder
  if not RF then return {} end
  local top = RF:TopRares(M.MAX_ROWS)
  local rows, values = {}, {}
  for i = 1, #top do values[i] = top[i].n end
  local best = top[1] and top[1].n or 0
  for i = 1, #top do
    local pct = LP.util.RankPercentile(top[i].n, values)
    rows[i] = {
      name = top[i].name or ("#" .. top[i].npc),
      value = top[i].n, label = "x" .. top[i].n, pct = pct,
      band = pct and LP.data and LP.data.BandFor(pct) or nil,
      fill = (best > 0) and (top[i].n / best * 100) or 0,
    }
  end
  return rows
end })

M:AddView({ id = "board", title = "Leaderboard", rows = function()
  -- Written into the addon folder by the companion; absent until it has run.
  local board = _G.LevelPaceBoard
  local entries = board and board.overall
  if type(entries) ~= "table" then return {} end
  local me = UnitName and UnitName("player") or nil
  local rows = {}
  local best = entries[1] and (entries[1].metric or 0) or 0
  for i = 1, math.min(#entries, M.MAX_ROWS) do
    local e = entries[i]
    local pct = e.percentile or e.pct
    rows[i] = {
      name = e.name or e.display or "?",
      value = e.metric or 0,
      label = string.format("%.2f", e.metric or 0),
      pct = pct,
      band = pct and LP.data and LP.data.BandFor(pct) or nil,
      fill = (best > 0) and ((e.metric or 0) / best * 100) or 0,
      isYou = (me and (e.name == me or e.display == me)) or false,
    }
  end
  return rows
end })

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local function saveGeometry(f)
  local c = cfg()
  local point, _, relPoint, x, y = f:GetPoint()
  c.point, c.relPoint, c.x, c.y = point, relPoint, x, y
  c.width, c.height = f:GetWidth(), f:GetHeight()
end

local function ensureFrame()
  if M.frame then return M.frame end
  if not CreateFrame or not UI or not UI.Panel then return nil end
  local c = cfg()

  local f = UI.Panel("LevelPaceMeter", {
    width = c.width, height = c.height,
    point = c.point, relPoint = c.relPoint, x = c.x, y = c.y,
    movable = true,
  })
  if not f then return nil end
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    if LP.db and LP.db.profile.locked then return end
    self:StartMoving()
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    saveGeometry(self)
  end)

  if f.SetResizable then
    f:SetResizable(true)
    if f.SetMinResize then f:SetMinResize(M.MIN_WIDTH, M.MIN_HEIGHT) end
  end

  -- Header doubles as the view selector: left-click forward, right-click back.
  f.header = f:CreateFontString("LevelPaceMeterHeader")
  f.headerBtn = CreateFrame("Button", "LevelPaceMeterHeaderBtn", f)
  f.headerBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -5)
  f.headerBtn:SetWidth(c.width - 12)
  f.headerBtn:SetHeight(14)
  f.headerBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  f.headerBtn:SetScript("OnClick", function(_, button)
    M:Cycle(button == "RightButton" and -1 or 1)
  end)

  -- Resize grip, bottom-right, exactly where everyone expects it.
  local grip = CreateFrame("Button", "LevelPaceMeterGrip", f)
  grip:SetWidth(14); grip:SetHeight(14)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetScript("OnMouseDown", function()
    if LP.db and LP.db.profile.locked then return end
    if f.StartSizing then f:StartSizing("BOTTOMRIGHT") end
  end)
  grip:SetScript("OnMouseUp", function()
    if f.StopMovingOrSizing then f:StopMovingOrSizing() end
    M:SetSize(f:GetWidth(), f:GetHeight())
  end)
  f.grip = grip

  f.rows = {}
  f:Hide()
  M.frame = f
  return f
end

local function rowFrame(f, i)
  if f.rows[i] then return f.rows[i] end
  local bar = CreateFrame("StatusBar", "LevelPaceMeterRow" .. i, f)
  bar:SetMinMaxValues(0, 100)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar.bg = bar:CreateTexture("LevelPaceMeterRowBG" .. i)
  if bar.bg.SetAllPoints then bar.bg:SetAllPoints(bar) end
  if bar.bg.SetDrawLayer then bar.bg:SetDrawLayer("BACKGROUND") end
  bar.left = bar:CreateFontString("LevelPaceMeterRowL" .. i)
  bar.right = bar:CreateFontString("LevelPaceMeterRowR" .. i)
  f.rows[i] = bar
  return bar
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function M:SetSize(w, h)
  local c = cfg()
  c.width = math.max(M.MIN_WIDTH, math.floor(w or c.width))
  c.height = math.max(M.MIN_HEIGHT, math.floor(h or c.height))
  local f = M.frame
  if f then
    f:SetWidth(c.width)
    f:SetHeight(c.height)
    if f.headerBtn then f.headerBtn:SetWidth(c.width - 12) end
    self:Refresh()
  end
end

function M:Refresh()
  local f = M.frame
  if not f or not f:IsShown() then return end
  local c = cfg()

  UI.Style(f, c)
  if f.SetBackdropColor then
    local b = c.colors.bg
    f:SetBackdropColor(b.r, b.g, b.b, b.a)
  end

  UI.ApplyFont(f.header, c)
  f.header:SetText(self:CurrentTitle())
  if f.header.SetTextColor then
    local hc = c.colors.header
    f.header:SetTextColor(hc.r, hc.g, hc.b, hc.a)
  end
  f.header:ClearAllPoints()
  f.header:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)

  local rows = self:Rows()
  local width = c.width - 12
  -- Only draw what fits: a taller panel shows more, a short one shows fewer,
  -- and nothing is drawn off the bottom edge where it cannot be read.
  local fit = math.floor((c.height - 24) / M.ROW_H)
  if fit < 0 then fit = 0 end
  local n = math.min(#rows, fit)

  for i = 1, n do
    local r = rows[i]
    local bar = rowFrame(f, i)
    bar:SetWidth(width)
    bar:SetHeight(M.ROW_H - 2)
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -(22 + (i - 1) * M.ROW_H))
    bar:SetValue(r.fill or 0)

    local col = r.band or c.colors.text
    if bar.SetStatusBarColor then bar:SetStatusBarColor(col.r, col.g, col.b, 0.85) end
    if bar.bg and bar.bg.SetTexture then
      local bb = c.colors.barBG
      bar.bg:SetTexture(bb.r, bb.g, bb.b, bb.a)
    end

    UI.ApplyFont(bar.left, c)
    UI.ApplyFont(bar.right, c)
    bar.left:ClearAllPoints()
    bar.left:SetPoint("LEFT", bar, "LEFT", 4, 0)
    bar.right:ClearAllPoints()
    bar.right:SetPoint("RIGHT", bar, "RIGHT", -4, 0)

    local name = r.name or "?"
    if r.isYou then name = "> " .. name end
    bar.left:SetText(name)
    bar.right:SetText(r.label or tostring(r.value or ""))

    local tc = r.isYou and c.colors.you or c.colors.text
    if bar.left.SetTextColor then bar.left:SetTextColor(tc.r, tc.g, tc.b, tc.a) end
    if bar.right.SetTextColor then bar.right:SetTextColor(tc.r, tc.g, tc.b, tc.a) end
    if bar.Show then bar:Show() end
  end

  for i = n + 1, #f.rows do
    if f.rows[i].Hide then f.rows[i]:Hide() end
  end
end

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------

function M:IsShown()
  return (M.frame and M.frame:IsShown()) and true or false
end

function M:Show()
  local f = ensureFrame()
  if not f then return end
  f:Show()
  cfg().shown = true
  self:Refresh()
end

function M:Hide()
  if M.frame then M.frame:Hide() end
  cfg().shown = false
end

function M:Toggle()
  if self:IsShown() then self:Hide() else self:Show() end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local lastRefresh = 0

LP:On("PLAYER_READY", function()
  ensureFrame()
  if cfg().shown then M:Show() end
end)

LP:On("TICK", function()
  -- Guarded twice on purpose. The scoreboard walk is not free, and this runs
  -- every second forever; a hidden panel must cost nothing at all.
  if not M.frame or not M.frame:IsShown() then return end
  local now = (GetTime and GetTime()) or 0
  if now - lastRefresh < REFRESH_SECONDS and now >= lastRefresh then return end
  lastRefresh = now
  M:Refresh()
end)

LP:On("STYLE_CHANGED", function() M:Refresh() end)

-- Entering a battleground switches to the live view, the way a damage meter
-- switches segment when a fight starts.
LP:On("PLAYER_READY", function()
  LP:RegisterEvent("PLAYER_ENTERING_BATTLEGROUND", "__meter", function()
    if M:IsShown() then M:Select("bgdamage") end
  end)
end)
