-- LevelPace :: UI/Minimap
--
-- The minimap button and its menu.
--
-- Slash commands are fine once you know them and useless before that. This is
-- the discoverable way in: one button, every feature behind it, and the module
-- toggles as checkboxes so their state is visible rather than remembered.
--
-- The ring maths is kept separate from the frame code so it can be tested
-- without a game client -- positioning a button on a circle is exactly the
-- kind of thing that is silently 90 degrees out forever.

local LP = _G.LevelPace
LP.Minimap = LP.Minimap or {}
local MM = LP.Minimap

MM.RADIUS = 80          -- standard distance from the minimap centre
MM.SIZE   = 31

-- A black-and-purple stock icon: shadow magic reads as dark violet at 20px,
-- and it exists in every 3.3.5a client.
MM.ICON = "Interface\\Icons\\Spell_Shadow_ShadowWordPain"

MM.defaults = {
  shown = true,
  angle = 210,          -- lower-left of the ring, where fewest addons sit
}

if LP.defaults and LP.defaults.profile then
  LP.defaults.profile.minimap = MM.defaults
end

local function cfg()
  local p = LP.db and LP.db.profile
  return (p and p.minimap) or MM.defaults
end

-- ---------------------------------------------------------------------------
-- Ring maths
-- ---------------------------------------------------------------------------

local function normalise(deg)
  deg = deg % 360
  if deg < 0 then deg = deg + 360 end
  return deg
end

function MM:PositionFor(deg)
  local r = math.rad(normalise(deg))
  return MM.RADIUS * math.cos(r), MM.RADIUS * math.sin(r)
end

function MM:AngleFrom(dx, dy)
  -- atan2 is not available on 3.3.5a's Lua as math.atan2? It is: 5.1 has it.
  -- Dead centre has no angle; return the saved one rather than NaN.
  if dx == 0 and dy == 0 then return normalise(cfg().angle or 0) end
  return normalise(math.deg(math.atan2(dy, dx)))
end

function MM:SetAngle(deg)
  local a = normalise(deg)
  cfg().angle = a
  if MM.button then
    local x, y = MM:PositionFor(a)
    MM.button:ClearAllPoints()
    MM.button:SetPoint("CENTER", _G.Minimap, "CENTER", x, y)
  end
  return a
end

-- ---------------------------------------------------------------------------
-- Menu
--
-- Returned as data so it can be asserted on without a dropdown frame. The
-- renderer below turns it into UIDropDownMenu entries.
-- ---------------------------------------------------------------------------

function MM:MenuItems()
  local items = {}

  items[#items + 1] = { text = "LevelPace", isTitle = true, notCheckable = true }

  items[#items + 1] = {
    text = "Meter", tooltip = "The always-on panel",
    checked = LP.Meter and LP.Meter:IsShown() or false,
    func = function() if LP.Meter then LP.Meter:Toggle() end end,
  }
  items[#items + 1] = {
    text = "Dashboard", tooltip = "Tabs for each module",
    checked = (LP.Dash and LP.Dash.frame and LP.Dash.frame:IsShown()) or false,
    func = function() if LP.Dash then LP.Dash:Toggle() end end,
  }
  items[#items + 1] = {
    text = "Leaderboard", notCheckable = true,
    func = function() if LP.Board then LP.Board:Toggle() end end,
  }

  items[#items + 1] = { text = "", isSeparator = true, notCheckable = true, disabled = true }
  items[#items + 1] = { text = "Modules", isTitle = true, notCheckable = true }

  local order = LP:ModuleOrder()
  for i = 1, #order do
    local m = LP:GetModule(order[i])
    items[#items + 1] = {
      text = m.title or m.id,
      moduleID = m.id,
      tooltip = m.desc,
      checked = LP:ModuleEnabled(m.id),
      -- Read the state at click time, not at build time: the menu may have
      -- been open while something else changed it.
      func = function() LP:SetModuleEnabled(m.id, not LP:ModuleEnabled(m.id)) end,
    }
  end

  items[#items + 1] = { text = "", isSeparator = true, notCheckable = true, disabled = true }

  items[#items + 1] = {
    text = "Lock frames", checked = LP.db and LP.db.profile.locked or false,
    func = function()
      LP.db.profile.locked = not LP.db.profile.locked
      LP:Fire("LOCK_CHANGED", LP.db.profile.locked)
    end,
  }
  items[#items + 1] = {
    text = "Options", notCheckable = true,
    func = function()
      if InterfaceOptionsFrame_OpenToCategory and LP.optionsPanel then
        InterfaceOptionsFrame_OpenToCategory(LP.optionsPanel)
      else
        LP:Print("options unavailable")
      end
    end,
  }
  items[#items + 1] = {
    text = "Hide this button", notCheckable = true,
    func = function()
      MM:Toggle()
      LP:Print("minimap button hidden. /lp minimap to bring it back.")
    end,
  }

  return items
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local dragging = false

local function buildMenu()
  if MM.menu or not CreateFrame then return MM.menu end
  local f = CreateFrame("Frame", "LevelPaceMinimapMenu", _G.UIParent,
                        "UIDropDownMenuTemplate")
  MM.menu = f
  return f
end

local function showMenu()
  local menu = buildMenu()
  if not menu or not UIDropDownMenu_Initialize then
    -- No dropdown API (or running headless): fall back to the command list
    -- rather than doing nothing at all.
    LP:Print("menu unavailable -- try /lp meter, /lp dash, /lp modules")
    return
  end
  UIDropDownMenu_Initialize(menu, function()
    for _, it in ipairs(MM:MenuItems()) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = it.text
      info.isTitle = it.isTitle
      info.disabled = it.disabled
      info.notCheckable = it.notCheckable or it.isTitle
      info.checked = it.checked
      info.keepShownOnClick = (it.moduleID ~= nil) or (it.text == "Lock frames")
      info.func = it.func
      info.tooltipTitle = it.text
      info.tooltipText = it.tooltip
      UIDropDownMenu_AddButton(info)
    end
  end, "MENU")
  ToggleDropDownMenu(1, nil, menu, "cursor", 0, 0)
end

local function ensureButton()
  if MM.button then return MM.button end
  if not CreateFrame or not _G.Minimap then return nil end

  local b = CreateFrame("Button", "LevelPaceMinimapButton", _G.Minimap)
  b:SetWidth(MM.SIZE); b:SetHeight(MM.SIZE)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture(MM.ICON)
  icon:SetWidth(20); icon:SetHeight(20)
  icon:SetPoint("CENTER", b, "CENTER", 0, 1)
  -- Trim the transparent border every stock icon carries, and push it darker
  -- and more violet so it reads as this addon rather than as a warlock spell.
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  icon:SetVertexColor(0.72, 0.45, 1.0)
  b.icon = icon

  local ring = b:CreateTexture(nil, "OVERLAY")
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetWidth(53); ring:SetHeight(53)
  ring:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b.ring = ring

  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function() showMenu() end)

  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", function()
    dragging = true
    b:SetScript("OnUpdate", function()
      local mx, my = _G.Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = _G.Minimap:GetEffectiveScale()
      if not mx or not cx or not scale or scale == 0 then return end
      MM:SetAngle(MM:AngleFrom(cx / scale - mx, cy / scale - my))
    end)
  end)
  b:SetScript("OnDragStop", function()
    dragging = false
    b:SetScript("OnUpdate", nil)
  end)

  b:SetScript("OnEnter", function()
    if not GameTooltip then return end
    GameTooltip:SetOwner(b, "ANCHOR_LEFT")
    GameTooltip:AddLine("LevelPace")
    GameTooltip:AddLine("Click for the menu.", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag to move around the minimap.", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)

  MM.button = b
  MM:SetAngle(cfg().angle or MM.defaults.angle)
  return b
end

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------

function MM:IsShown()
  if MM.button then return MM.button:IsShown() and true or false end
  return cfg().shown and true or false
end

function MM:Show()
  local b = ensureButton()
  cfg().shown = true
  if b then b:Show() end
end

function MM:Hide()
  cfg().shown = false
  if MM.button then MM.button:Hide() end
end

function MM:Toggle()
  if self:IsShown() then self:Hide() else self:Show() end
end

LP:On("PLAYER_READY", function()
  ensureButton()
  if cfg().shown then MM:Show() else MM:Hide() end
end)
