-- LevelPace :: UI/Dash
--
-- One dashboard window hosting one tab per enabled module.
--
-- Modules do not write frame code. Each returns a list of plain rows from its
-- Dashboard() function and this renders them, so all three look the same, get
-- the same colour/opacity/font/size options, and a fourth module costs nothing
-- but a Dashboard() function.
--
-- Row kinds:
--   { kind = "header", text = }
--   { kind = "stat",   label = , value = , note = }
--   { kind = "list",   title = , items = { { text = , sub = }, ... } }
--   { kind = "empty",  text = }

local LP = _G.LevelPace
LP.Dash = LP.Dash or {}
local D = LP.Dash

local UI = LP.UI

local WIDTH, HEIGHT = 380, 320
local ROW_H, PAD = 15, 10

D.defaults = {
  shown = false,
  point = "CENTER", relPoint = "CENTER", x = 0, y = 0,
  scale = 1.0,
  font = "Fonts\\FRIZQT__.TTF",
  fontSize = 12,
  outline = "",
  colors = {
    bg     = { r = 0.04, g = 0.04, b = 0.06, a = 0.88 },
    border = { r = 0.00, g = 0.00, b = 0.00, a = 0.90 },
    header = { r = 0.55, g = 0.80, b = 1.00, a = 1.00 },
    label  = { r = 0.65, g = 0.65, b = 0.70, a = 1.00 },
    value  = { r = 1.00, g = 1.00, b = 1.00, a = 1.00 },
    note   = { r = 0.55, g = 0.55, b = 0.58, a = 1.00 },
    tabOn  = { r = 1.00, g = 0.82, b = 0.30, a = 1.00 },
    tabOff = { r = 0.50, g = 0.50, b = 0.55, a = 1.00 },
  },
}

-- Registered at file scope, before InitDB runs, so InitDB's CopyDefaults
-- installs it exactly like bar/box/gauge. Adding it at PLAYER_READY instead
-- left LP.db.profile.dash nil for anything reading it earlier.
if LP.defaults and LP.defaults.profile then
  LP.defaults.profile.dash = D.defaults
end

local selected = nil

local function style()
  local p = LP.db and LP.db.profile
  return (p and p.dash) or D.defaults
end

-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------

function D:Tabs()
  local out = {}
  if not LP.ModuleOrder then return out end
  local order = LP:ModuleOrder()
  for i = 1, #order do
    local m = LP:GetModule(order[i])
    -- A module without a Dashboard has nothing to show; giving it an empty
    -- tab would just be a dead end for the player to click on.
    if m and m.Dashboard and LP:ModuleEnabled(m.id) then
      out[#out + 1] = { id = m.id, title = m.title or m.id }
    end
  end
  return out
end

function D:Selected()
  local tabs = self:Tabs()
  if #tabs == 0 then return nil end
  for i = 1, #tabs do
    if tabs[i].id == selected then return selected end
  end
  -- The selected module was switched off. Fall back to the first live tab
  -- rather than leaving the window blank.
  selected = tabs[1].id
  return selected
end

function D:Select(id)
  local tabs = self:Tabs()
  for i = 1, #tabs do
    if tabs[i].id == id then
      selected = id
      self:Refresh()
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------

function D:Content()
  local id = self:Selected()
  if not id then return {} end
  local m = LP:GetModule(id)
  if not m or not m.Dashboard then return {} end

  -- A broken module must not take the window down with it.
  local ok, rows = pcall(m.Dashboard, m)
  if not ok then
    return { { kind = "empty", text = (m.title or id) .. " could not be read" } }
  end
  if type(rows) ~= "table" then
    return { { kind = "empty", text = "nothing to show yet" } }
  end
  return rows
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local function ensureFrame()
  if D.frame then return D.frame end
  if not CreateFrame or not UI or not UI.Panel then return nil end
  local s = style()

  local f = UI.Panel("LevelPaceDash", {
    width = WIDTH, height = HEIGHT,
    point = s.point, relPoint = s.relPoint, x = s.x, y = s.y,
    movable = true,
  })
  if not f then return nil end
  f:SetFrameStrata("DIALOG")
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    if LP.db and LP.db.profile.locked then return end
    self:StartMoving()
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    local st = style()
    st.point, st.relPoint, st.x, st.y = point, relPoint, x, y
  end)

  f.title = f:CreateFontString("LevelPaceDashTitle")
  f.tabStrings = {}
  f.rowStrings = {}
  f:Hide()

  D.frame = f
  return f
end

local function fontString(f, i)
  if f.rowStrings[i] then return f.rowStrings[i] end
  local fs = f:CreateFontString("LevelPaceDashRow" .. i)
  f.rowStrings[i] = fs
  return fs
end

function D:Refresh()
  local f = D.frame
  if not f then return end
  local s = style()

  UI.Style(f, s)
  if f.SetBackdropColor then
    local c = s.colors.bg
    f:SetBackdropColor(c.r, c.g, c.b, c.a)
  end

  -- Tab strip.
  local tabs = self:Tabs()
  local sel = self:Selected()
  for i = 1, math.max(#tabs, #f.tabStrings) do
    local t = tabs[i]
    local fs = f.tabStrings[i]
    if t and not fs then
      fs = f:CreateFontString("LevelPaceDashTab" .. i)
      f.tabStrings[i] = fs
    end
    if fs then
      if t then
        UI.ApplyFont(fs, s)
        fs:SetText(t.title)
        local c = (t.id == sel) and s.colors.tabOn or s.colors.tabOff
        if fs.SetTextColor then fs:SetTextColor(c.r, c.g, c.b, c.a) end
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * 92, -PAD)
        if fs.Show then fs:Show() end
      elseif fs.Hide then
        fs:Hide()
      end
    end
  end

  -- Body.
  local rows = self:Content()
  local y = -(PAD + ROW_H + 6)
  local n = 0

  local function put(text, colour, indent)
    n = n + 1
    local fs = fontString(f, n)
    UI.ApplyFont(fs, s)
    fs:SetText(text or "")
    if fs.SetTextColor and colour then
      fs:SetTextColor(colour.r, colour.g, colour.b, colour.a)
    end
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (indent or 0), y)
    if fs.Show then fs:Show() end
    y = y - ROW_H
  end

  for i = 1, #rows do
    local r = rows[i]
    if r.kind == "header" then
      if n > 0 then y = y - 4 end
      put(r.text, s.colors.header)
    elseif r.kind == "stat" then
      local text = (r.label or "") .. ":  |cffffffff" .. tostring(r.value or "") .. "|r"
      if r.note then text = text .. "  |cff8c8c94" .. r.note .. "|r" end
      put(text, s.colors.label)
    elseif r.kind == "list" then
      if r.title then put(r.title, s.colors.header) end
      for j = 1, #(r.items or {}) do
        local it = r.items[j]
        local text = tostring(it.text or "")
        if it.sub then text = text .. "  |cff8c8c94" .. it.sub .. "|r" end
        put(text, s.colors.value, 10)
      end
    elseif r.kind == "empty" then
      put(r.text or "nothing yet", s.colors.note)
    end
  end

  -- Retire any font strings left over from a longer previous render.
  for i = n + 1, #f.rowStrings do
    if f.rowStrings[i].Hide then f.rowStrings[i]:Hide() end
  end
end

function D:Toggle()
  local f = ensureFrame()
  if not f then LP:Print("dashboard needs the game client"); return end
  if f:IsShown() then f:Hide() else self:Refresh(); f:Show() end
  local s = style()
  s.shown = f:IsShown() and true or false
end

function D:Show()
  local f = ensureFrame()
  if not f then return end
  self:Refresh()
  f:Show()
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

LP:On("PLAYER_READY", function()
  ensureFrame()
  if style().shown then D:Show() end
end)

LP:On("STYLE_CHANGED", function() D:Refresh() end)
LP:On("MODULE_ENABLED", function() D:Refresh() end)
LP:On("MODULE_DISABLED", function() D:Refresh() end)
