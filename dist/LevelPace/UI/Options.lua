-- LevelPace :: UI/Options
-- Interface Options panels: colour + opacity on every element, fonts, sizes.

local LP = _G.LevelPace
local util = LP.util

local Options = {}
LP.Options = Options

local FONTS = {
  { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
  { name = "Arial Narrow",  path = "Fonts\\ARIALN.TTF" },
  { name = "Morpheus",      path = "Fonts\\MORPHEUS.TTF" },
  { name = "Skurri",        path = "Fonts\\SKURRI.TTF" },
}

local OUTLINES = {
  { name = "None", value = "" },
  { name = "Outline", value = "OUTLINE" },
  { name = "Thick outline", value = "THICKOUTLINE" },
}

local LAYOUTS = {
  { name = "Compact (one line)", value = "compact" },
  { name = "Stacked", value = "stacked" },
  { name = "Full (labelled rows)", value = "full" },
}

local TEXTURES = {
  { name = "Blizzard", path = "Interface\\TargetingFrame\\UI-StatusBar" },
  { name = "Flat", path = "Interface\\ChatFrame\\ChatFrameBackground" },
  { name = "Tooltip", path = "Interface\\Tooltips\\UI-Tooltip-Background" },
}

local uid = 0
local function nextName(prefix)
  uid = uid + 1
  return "LevelPaceOpt" .. prefix .. uid
end

local function changed()
  LP:Fire("STYLE_CHANGED")
end

-- ---------------------------------------------------------------------------
-- Widget helpers
-- ---------------------------------------------------------------------------

local function makeLabel(parent, text, x, y, font)
  local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  fs:SetText(text)
  return fs
end

local function makeCheck(parent, label, x, y, get, set)
  -- Must be NAMED or $parentText does not resolve and the label never shows.
  local name = nextName("Check")
  local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
  c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  local fs = _G[name .. "Text"]
  if fs then fs:SetText(label) end
  c:SetChecked(get() and true or false)
  c:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    changed()
  end)
  c.Refresh = function() c:SetChecked(get() and true or false) end
  return c
end

local function makeSlider(parent, label, x, y, minV, maxV, step, get, set)
  local name = nextName("Slider")
  local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
  s:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 6, y)
  s:SetWidth(180)
  s:SetMinMaxValues(minV, maxV)
  s:SetValueStep(step)
  s:SetValue(get())
  if _G[name .. "Text"] then _G[name .. "Text"]:SetText(label .. ": " .. get()) end
  if _G[name .. "Low"] then _G[name .. "Low"]:SetText(tostring(minV)) end
  if _G[name .. "High"] then _G[name .. "High"]:SetText(tostring(maxV)) end
  s:SetScript("OnValueChanged", function(self, value)
    -- OptionsSliderTemplate does not snap to SetValueStep while dragging on
    -- 3.3.5a, so round here or the value drifts to fractions.
    local v = math.floor(value / step + 0.5) * step
    set(v)
    if _G[name .. "Text"] then _G[name .. "Text"]:SetText(label .. ": " .. v) end
    changed()
  end)
  s.Refresh = function()
    s:SetValue(get())
    if _G[name .. "Text"] then _G[name .. "Text"]:SetText(label .. ": " .. get()) end
  end
  return s
end

local function makeDropdown(parent, label, x, y, items, get, set)
  local name = nextName("Drop")
  makeLabel(parent, label, x + 4, y + 16, "GameFontNormalSmall")
  local d = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
  d:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 12, y)

  local function currentName()
    local cur = get()
    for _, it in ipairs(items) do
      if (it.value or it.path) == cur then return it.name end
    end
    return items[1] and items[1].name or ""
  end

  UIDropDownMenu_Initialize(d, function()
    for _, it in ipairs(items) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = it.name
      info.value = it.value or it.path
      info.func = function(self)
        set(self.value)
        UIDropDownMenu_SetText(d, self:GetText())
        changed()
      end
      info.checked = ((it.value or it.path) == get())
      UIDropDownMenu_AddButton(info)
    end
  end)
  UIDropDownMenu_SetWidth(d, 150)
  UIDropDownMenu_SetText(d, currentName())
  d.Refresh = function() UIDropDownMenu_SetText(d, currentName()) end
  return d
end

-- Colour swatch with opacity. ColorPickerFrame on 3.3.5a exposes
-- .hasOpacity / .opacity / .opacityFunc / .cancelFunc / .previousValues.
--
-- The one trap: OpacitySliderFrame's value is TRANSPARENCY, so alpha is
-- 1 - value. Getting that backwards makes the slider feel inverted.
local function makeSwatch(parent, label, x, y, tbl)
  local name = nextName("Swatch")
  local b = CreateFrame("Button", name, parent)
  b:SetWidth(16); b:SetHeight(16)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

  local border = b:CreateTexture(nil, "BACKGROUND")
  border:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
  border:SetPoint("TOPLEFT", -1, 1)
  border:SetPoint("BOTTOMRIGHT", 1, -1)
  border:SetVertexColor(0, 0, 0, 1)

  local tex = b:CreateTexture(nil, "ARTWORK")
  tex:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
  tex:SetAllPoints(b)

  local fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", b, "RIGHT", 6, 0)
  fs:SetText(label)

  local function paint()
    tex:SetVertexColor(tbl.r, tbl.g, tbl.b, 1)
    b.alphaHint = tbl.a
  end
  paint()

  b:SetScript("OnClick", function()
    local prev = { tbl.r, tbl.g, tbl.b, tbl.a }
    local function apply()
      local r, g, bl = ColorPickerFrame:GetColorRGB()
      tbl.r, tbl.g, tbl.b = r, g, bl
      -- OpacitySliderFrame reports TRANSPARENCY.
      if OpacitySliderFrame then tbl.a = 1 - OpacitySliderFrame:GetValue() end
      paint(); changed()
    end
    ColorPickerFrame.func = apply
    ColorPickerFrame.opacityFunc = apply
    ColorPickerFrame.cancelFunc = function()
      tbl.r, tbl.g, tbl.b, tbl.a = prev[1], prev[2], prev[3], prev[4]
      paint(); changed()
    end
    ColorPickerFrame.hasOpacity = true
    ColorPickerFrame.opacity = 1 - (tbl.a or 1)
    ColorPickerFrame.previousValues = { prev[1], prev[2], prev[3], 1 - prev[4] }
    ColorPickerFrame:SetColorRGB(tbl.r, tbl.g, tbl.b)
    -- Hide-then-Show forces the callbacks to rebind.
    ColorPickerFrame:Hide()
    ColorPickerFrame:Show()
  end)

  b.Refresh = paint
  return b
end

local function makeButton(parent, label, x, y, onClick)
  local b = CreateFrame("Button", nextName("Btn"), parent, "UIPanelButtonTemplate")
  b:SetWidth(140); b:SetHeight(22)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

-- ---------------------------------------------------------------------------
-- Panels
-- ---------------------------------------------------------------------------

local function newPanel(name, parentName)
  local p = CreateFrame("Frame", "LevelPacePanel" .. name:gsub("%s", ""), UIParent)
  p.name = name
  if parentName then p.parent = parentName end
  p:Hide()
  p.widgets = {}
  p.refresh = function()
    for _, w in ipairs(p.widgets) do if w.Refresh then w.Refresh() end end
  end
  return p
end

local function track(panel, w)
  table.insert(panel.widgets, w)
  return w
end

function Options:BuildGeneral()
  local p = newPanel("LevelPace")
  local db = LP.db.profile

  makeLabel(p, "LevelPace", 16, -16, "GameFontNormalLarge")
  makeLabel(p, "Honest XP tracking and quest-vs-grind ranking.", 16, -40, "GameFontHighlightSmall")

  local y = -70
  track(p, makeCheck(p, "Show XP bar", 16, y,
    function() return db.bar.shown end,
    function(v) db.bar.shown = v; if LP.Bar then LP.Bar:Update() end end))
  y = y - 28
  track(p, makeCheck(p, "Show stats box", 16, y,
    function() return db.box.shown end,
    function(v) db.box.shown = v; if LP.Box then LP.Box:Update() end end))
  y = y - 28
  track(p, makeCheck(p, "Lock frames (stop dragging)", 16, y,
    function() return db.locked end,
    function(v) db.locked = v end))
  y = y - 34

  track(p, makeCheck(p, "Count rested XP in the projection", 16, y,
    function() return db.countRestedInProjection end,
    function(v) db.countRestedInProjection = v; if LP.Estimator then LP.Estimator:Refresh() end end))
  y = y - 26
  makeLabel(p, "Rested doubles kill XP but does nothing for quests.", 38, y, "GameFontDisableSmall")
  y = y - 44

  track(p, makeSlider(p, "Warn about idle gaps over (minutes)", 16, y, 0, 60, 1,
    function() return math.floor((db.gapWarnSeconds or 600) / 60) end,
    function(v) db.gapWarnSeconds = v * 60 end))
  y = y - 44
  makeLabel(p, "Gaps are reported, never removed. 0 disables the warning.",
    22, y, "GameFontDisableSmall")
  y = y - 40

  makeButton(p, "Reset this level", 16, y, function()
    if LP.History then LP.History:Reset() end
    LP:Print("tracking reset for this level.")
  end)
  makeLabel(p, "The only filter in the addon.", 170, y - 6, "GameFontDisableSmall")

  self.panel = p
  LP.optionsPanel = p
  return p
end

function Options:BuildAppearance()
  local p = newPanel("Appearance", "LevelPace")
  local db = LP.db.profile

  makeLabel(p, "Bar", 16, -16, "GameFontNormalLarge")
  local y = -44
  track(p, makeSwatch(p, "Fill", 16, y, db.bar.colors.fill))
  track(p, makeSwatch(p, "Rested overlay", 150, y, db.bar.colors.rested))
  y = y - 26
  track(p, makeSwatch(p, "Background", 16, y, db.bar.colors.bg))
  track(p, makeSwatch(p, "Border", 150, y, db.bar.colors.border))
  y = y - 40

  track(p, makeSlider(p, "Bar width", 16, y, 80, 600, 5,
    function() return db.bar.width end, function(v) db.bar.width = v end))
  y = y - 44
  track(p, makeSlider(p, "Bar height", 16, y, 6, 40, 1,
    function() return db.bar.height end, function(v) db.bar.height = v end))
  y = y - 50
  track(p, makeDropdown(p, "Bar texture", 16, y, TEXTURES,
    function() return db.bar.texture end, function(v) db.bar.texture = v end))
  y = y - 56

  makeLabel(p, "Box", 16, y, "GameFontNormalLarge")
  y = y - 28
  track(p, makeSwatch(p, "Background", 16, y, db.box.colors.bg))
  track(p, makeSwatch(p, "Border", 150, y, db.box.colors.border))
  y = y - 26
  track(p, makeSwatch(p, "Labels", 16, y, db.box.colors.label))
  track(p, makeSwatch(p, "Values", 150, y, db.box.colors.value))
  y = y - 26
  track(p, makeSwatch(p, "Good", 16, y, db.box.colors.good))
  track(p, makeSwatch(p, "Uncertain", 150, y, db.box.colors.neutral))
  y = y - 26
  track(p, makeSwatch(p, "Bad", 16, y, db.box.colors.bad))
  y = y - 46

  track(p, makeDropdown(p, "Layout", 16, y, LAYOUTS,
    function() return db.box.layout end, function(v) db.box.layout = v end))
  track(p, makeDropdown(p, "Font", 240, y, FONTS,
    function() return db.box.font end, function(v) db.box.font = v end))
  y = y - 56
  track(p, makeDropdown(p, "Outline", 16, y, OUTLINES,
    function() return db.box.outline end, function(v) db.box.outline = v end))
  y = y - 56

  track(p, makeSlider(p, "Font size", 16, y, 7, 24, 1,
    function() return db.box.fontSize end, function(v) db.box.fontSize = v end))
  track(p, makeSlider(p, "Box scale", 240, y, 50, 200, 5,
    function() return math.floor(db.box.scale * 100) end,
    function(v) db.box.scale = v / 100 end))
  y = y - 44
  track(p, makeSlider(p, "Line spacing", 16, y, 0, 12, 1,
    function() return db.box.spacing end, function(v) db.box.spacing = v end))

  return p
end

function Options:BuildLines()
  local p = newPanel("Displayed lines", "LevelPace")
  local db = LP.db.profile

  makeLabel(p, "Displayed lines", 16, -16, "GameFontNormalLarge")
  makeLabel(p, "Choose what the stats box shows.", 16, -40, "GameFontHighlightSmall")

  local y = -70
  for _, spec in ipairs(LP.Box and LP.Box.LINES or {}) do
    local key = spec.key
    track(p, makeCheck(p, spec.label, 16, y,
      function() return db.box.lines[key] end,
      function(v) db.box.lines[key] = v; if LP.Box then LP.Box:Relayout(); LP.Box:Update() end end))
    y = y - 28
  end

  y = y - 20
  makeButton(p, "Print quest ranking", 16, y, function()
    if LP.Quests then LP.Quests:PrintRanking() end
  end)
  return p
end

function Options:Build()
  if self.built or not CreateFrame then return end
  if not InterfaceOptions_AddCategory then return end
  self.built = true
  InterfaceOptions_AddCategory(self:BuildGeneral())
  InterfaceOptions_AddCategory(self:BuildAppearance())
  InterfaceOptions_AddCategory(self:BuildLines())
end

LP:On("PLAYER_READY", function() Options:Build() end)
