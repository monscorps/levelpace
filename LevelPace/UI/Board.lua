-- LevelPace :: UI/Board
--
-- The leaderboard, in game. Opens with /lp board.
--
-- The addon cannot fetch anything, so this renders whatever the uploader last
-- wrote into Board.lua. That means the rankings are as of the last upload
-- followed by a /reload -- which the window says out loud, because a stale
-- board that looks live is worse than no board.

local LP = _G.LevelPace
local util = LP.util

local Board = {}
LP.Board = Board

local ROWS = 14
local ROW_H = 18
local WIDTH = 560

local BACKDROP = {
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- Class colours, 3.3.5a set. DEATHKNIGHT exists on this client.
local CLASS_COLOR = {
  WARRIOR = { .78, .61, .43 }, PALADIN = { .96, .55, .73 }, HUNTER = { .67, .83, .45 },
  ROGUE   = { 1, .96, .41 },   PRIEST  = { 1, 1, 1 },       DEATHKNIGHT = { .77, .12, .23 },
  SHAMAN  = { 0, .44, .87 },   MAGE    = { .41, .8, .94 },  WARLOCK = { .58, .51, .79 },
  DRUID   = { 1, .49, .04 },
}

local TABS = {
  { key = "overall", label = "Overall" },
  { key = "twinks",  label = "Twinks" },
}

function Board:Data()
  local b = _G.LevelPaceBoard
  if type(b) ~= "table" then return nil end
  return b
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

function Board:Create()
  if self.frame or not CreateFrame then return self.frame end

  local f = CreateFrame("Frame", "LevelPaceBoardFrame", UIParent)
  f:SetWidth(WIDTH)
  f:SetHeight(ROWS * ROW_H + 96)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetBackdrop(BACKDROP)
  f:SetBackdropColor(0.03, 0.04, 0.06, 0.95)
  f:SetScript("OnDragStart", function(s) s:StartMoving() end)
  f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
  f:Hide()

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -14)
  title:SetText("LevelPace")

  self.stale = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.stale:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -18)
  self.stale:SetJustifyH("RIGHT")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

  -- tabs
  self.tabs = {}
  local x = 14
  for i, spec in ipairs(TABS) do
    local b = CreateFrame("Button", "LevelPaceBoardTab" .. i, f, "UIPanelButtonTemplate")
    b:SetWidth(90); b:SetHeight(20)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -40)
    b:SetText(spec.label)
    b:SetScript("OnClick", function()
      Board.view = spec.key
      Board:Update()
    end)
    self.tabs[i] = b
    x = x + 94
  end

  -- header
  self.header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  self.header:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -66)
  self.header:SetJustifyH("LEFT")
  self.header:SetTextColor(0.55, 0.58, 0.65)

  -- rows: one FontString per row, monospaced by construction rather than by
  -- font -- the client ships no monospace face, so columns are padded.
  self.rows = {}
  for i = 1, ROWS do
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -82 - (i - 1) * ROW_H)
    fs:SetJustifyH("LEFT")
    fs:SetWidth(WIDTH - 32)
    self.rows[i] = fs
  end

  self.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
  self.footer:SetJustifyH("LEFT")
  self.footer:SetWidth(WIDTH - 32)

  self.frame = f
  self.view = self.view or "overall"
  return f
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- Pad to a column width. GameFontHighlightSmall is proportional, so this is
-- approximate -- good enough for a scoreboard, and far simpler than laying
-- out a real grid of frames.
local function pad(s, n)
  s = tostring(s or "")
  if #s > n then return string.sub(s, 1, n - 1) .. "." end
  return s .. string.rep(" ", n - #s)
end

local function classColored(name, class)
  local c = CLASS_COLOR[class or ""]
  if not c then return name end
  return string.format("|cff%02x%02x%02x%s|r",
    c[1] * 255, c[2] * 255, c[3] * 255, name)
end

function Board:RenderOverall(data)
  self.header:SetText(pad("#", 4) .. pad("player", 22) .. pad("lvl", 6)
    .. pad("levels", 8) .. pad("best", 7) .. "parse")
  local list = data and data.overall or {}
  for i = 1, ROWS do
    local e = list[i + (self.offset or 0)]
    if not e then self.rows[i]:SetText(""); else
      local parse = e.parse and LP.Parse:Colorize(e.parse, string.format("%d", e.parse))
        or "|cff888888--|r"
      self.rows[i]:SetText(
        pad(e.rank, 4)
        .. pad(classColored(e.name or "?", e.class), 22 + 10)  -- +10 for the colour escape
        .. pad(e.level or "-", 6)
        .. pad(e.levels or 0, 8)
        .. pad(e.best and math.floor(e.best) or "-", 7)
        .. parse)
    end
  end
  return #list
end

function Board:RenderTwinks(data)
  self.header:SetText(pad("#", 4) .. pad("player", 20) .. pad("brkt", 6)
    .. pad("ilvl", 7) .. pad("wk", 6) .. pad("k/d", 7) .. "nemesis")
  local list = data and data.twinks or {}
  for i = 1, ROWS do
    local e = list[i + (self.offset or 0)]
    if not e then self.rows[i]:SetText(""); else
      local nem = "-"
      if e.nemesis and e.nemesis[1] then
        nem = string.format("|cffff8000%s|r x%d",
          e.nemesis[1].name or "?", e.nemesis[1].count or 0)
      end
      self.rows[i]:SetText(
        pad(e.rank, 4)
        .. pad(classColored(e.name or "?", e.class), 20 + 10)
        .. pad(e.bracket or "-", 6)
        .. pad(e.ilvl and string.format("%.0f", e.ilvl) or "-", 7)
        .. pad(e.weekly or 0, 6)
        .. pad(e.kd and string.format("%.2f", e.kd) or "-", 7)
        .. nem)
    end
  end
  return #list
end

function Board:Update()
  if not self.frame then return end
  local data = self:Data()

  for i, spec in ipairs(TABS) do
    -- No tab-selected texture without the Blizzard tab template, so the
    -- active tab is simply disabled -- unclickable and visibly different.
    if spec.key == self.view then self.tabs[i]:Disable() else self.tabs[i]:Enable() end
  end

  if not data then
    self.header:SetText("")
    for i = 1, ROWS do self.rows[i]:SetText("") end
    self.rows[1]:SetText("|cffe0a040No board data yet.|r")
    self.rows[3]:SetText("The uploader writes it into the addon folder.")
    self.rows[4]:SetText("Run it, then |cff44ddff/reload|r.")
    self.stale:SetText("")
    self.footer:SetText("")
    return
  end

  local n
  if self.view == "twinks" then n = self:RenderTwinks(data) else n = self:RenderOverall(data) end

  -- Say how old this is. A snapshot that looks live is worse than none.
  local age = data.fetched and ((time and time() or 0) - data.fetched) or nil
  if age and age > 0 then
    local txt
    if age < 5400 then txt = string.format("%d min old", math.floor(age / 60))
    elseif age < 172800 then txt = string.format("%d hours old", math.floor(age / 3600))
    else txt = string.format("%d days old", math.floor(age / 86400)) end
    self.stale:SetText("snapshot " .. txt)
  else
    self.stale:SetText("")
  end

  local foot = string.format("%d ranked. Updates when the uploader runs and you /reload.", n)
  if self.view == "twinks" then
    foot = foot .. "\nWeekly kills and nemeses are reconstructed, not read -- treat them as approximate."
  end
  self.footer:SetText(foot)
end

function Board:Toggle()
  self:Create()
  if self.frame:IsShown() then
    self.frame:Hide()
  else
    self.offset = 0
    self:Update()
    self.frame:Show()
  end
end

function Board:Scroll(delta)
  if not self.frame or not self.frame:IsShown() then return end
  local data = self:Data()
  local list = data and (self.view == "twinks" and data.twinks or data.overall) or {}
  local maxOff = math.max(0, #list - ROWS)
  self.offset = math.min(maxOff, math.max(0, (self.offset or 0) + delta))
  self:Update()
end

LP:On("PLAYER_READY", function()
  Board:Create()
  if Board.frame then
    Board.frame:EnableMouseWheel(true)
    Board.frame:SetScript("OnMouseWheel", function(_, d) Board:Scroll(-d * 3) end)
  end
end)
