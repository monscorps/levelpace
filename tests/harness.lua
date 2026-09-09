-- Mock WoW 3.3.5a environment for testing LevelPace outside the game.
--
-- Every global string here is the verbatim 3.3.5a enUS value from
-- FrameXML/GlobalStrings.lua. Do not paraphrase them -- the parser is built
-- from these at runtime, so a wrong string here means the tests validate
-- fiction.

local harness = {}

-- Fixed unix base so time() is deterministic across runs but distinct from
-- GetTime(). 2025-09-04T00:00:00Z.
local TIME_BASE = 1756944000
local clock = 0

harness.state = {}

function harness.setTime(t) clock = t end
function harness.advance(dt) clock = clock + dt end
function harness.now() return clock end

local function stubFrame(name)
  local f = { name = name, events = {}, scripts = {}, points = {}, regions = {} }
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:UnregisterAllEvents() self.events = {} end
  function f:IsEventRegistered(e) return self.events[e] and true or false end
  function f:SetScript(k, fn) self.scripts[k] = fn end
  function f:GetScript(k) return self.scripts[k] end
  function f:HookScript(k, fn) self.scripts[k] = fn end
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:IsShown() return self.shown and true or false end
  function f:IsVisible() return self.shown and true or false end
  function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
  function f:GetPoint() local p = self.points[1]; if p then return unpack(p) end end
  function f:ClearAllPoints() self.points = {} end
  function f:GetName() return self.name end
  function f:GetWidth() return self.width or 200 end
  function f:GetHeight() return self.height or 16 end
  function f:SetWidth(w) self.width = w end
  function f:SetHeight(hh) self.height = hh end
  function f:SetSize(w, hh) self.width, self.height = w, hh end
  function f:GetValue() return self.value or 0 end
  function f:SetValue(v) self.value = v end
  function f:SetText(t) self.text = t end
  function f:GetText() return self.text end
  -- Approximate text measurement so layout tests can detect overlap.
  -- Colour escapes (|cffRRGGBB ... |r) are not drawn, so strip them first.
  function f:GetStringWidth()
    local t = self.text or ""
    t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return #t * 6
  end
  function f:CreateFontString(n) local fs = stubFrame(n); self.regions[#self.regions + 1] = fs; return fs end
  function f:CreateTexture(n) local t = stubFrame(n); self.regions[#self.regions + 1] = t; return t end
  function f:GetStatusBarTexture() return self.barTexture end
  function f:GetEffectiveScale() return 1 end
  local noop = function() end
  for _, m in ipairs {
    "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor", "SetMovable",
    "EnableMouse", "RegisterForDrag", "SetClampedToScreen", "SetFrameStrata",
    "SetFrameLevel", "SetStatusBarTexture", "SetStatusBarColor", "SetMinMaxValues",
    "SetFont", "SetTextColor", "SetAlpha", "SetJustifyH", "SetJustifyV",
    "StartMoving", "StopMovingOrSizing", "SetAllPoints", "SetParent", "SetTexture",
    "SetVertexColor", "SetTexCoord", "SetDrawLayer", "SetScale", "SetUserPlaced",
    "SetResizable", "SetShadowOffset", "SetShadowColor", "SetOrientation",
    "SetChecked", "SetValueStep", "SetObeyStepOnDrag", "SetHitRectInsets",
    "SetAutoFocus", "ClearFocus", "SetFocus", "HighlightText", "SetMaxLetters",
    "EnableMouseWheel", "Disable", "Enable", "SetNormalTexture", "SetHighlightTexture",
    "SetMinResize", "SetMaxResize", "StartSizing", "RegisterForClicks",
  } do
    f[m] = f[m] or noop
  end
  return f
end
harness.stubFrame = stubFrame

local function installGlobals()
  -- Make the sandbox as strict as WoW's, not as permissive as native Lua.
  --
  -- WoW REMOVES parts of the standard library. math.randomseed is the one
  -- that mattered: it exists in LuaJIT and stock Lua 5.1 -- every test
  -- environment -- and not in the game. Export called it as the first step
  -- of every write, so on a real client no blob was ever produced, while
  -- every test here passed for weeks. Anything the game does not provide
  -- must be nil here too, so a call to it fails in tests before it fails
  -- for a player.
  math.randomseed = nil
  _G.loadstring = _G.loadstring   -- WoW keeps loadstring; listed for the record
  -- GetTime() is seconds since the client started: it RESTARTS AT ZERO every
  -- session. time() is a unix timestamp: wall clock, monotonic across
  -- sessions. Conflating them is not academic -- persisting a GetTime() value
  -- and comparing it next login is a bug this project has already shipped
  -- once (every stored kill read as future-dated, so every achievement fired).
  -- Keeping them distinct here is what lets a test catch it.
  _G.GetTime = function() return clock end
  _G.time = function() return TIME_BASE + math.floor(clock) end
  -- WoW's date() mirrors os.date, including the "*t" form that returns a
  -- TABLE with wday/hour/min/sec. Returning a bare string here hid a real
  -- bug: a string is truthy, so an `if not t` guard passes and t.wday is nil.
  _G.date = function(fmt, t) return os.date(fmt or "%c", t) end

  -- Core registers its slash handler only `if _G.SlashCmdList`. Without this
  -- the guard skips registration and the entire command interface -- the way
  -- players actually drive the addon -- goes untested.
  _G.SlashCmdList = {}

  _G.strtrim = function(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end
  _G.strsplit = function(sep, str)
    local out = {}
    for piece in string.gmatch(str, "([^" .. sep .. "]+)") do out[#out + 1] = piece end
    return unpack(out)
  end
  _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  _G.tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end end
  _G.hooksecurefunc = function(name, fn) harness.state.hooks = harness.state.hooks or {}; harness.state.hooks[name] = fn end

  -- ==== 3.3.5a enUS GlobalStrings ====
  _G.COMBATLOG_XPGAIN_FIRSTPERSON         = "%s dies, you gain %d experience."
  _G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = "You gain %d experience."
  _G.COMBATLOG_XPGAIN_EXHAUSTION1         = "%s dies, you gain %d experience. (%s exp %s bonus)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION2         = "%s dies, you gain %d experience. (%s exp %s bonus)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION4         = "%s dies, you gain %d experience. (%s exp %s penalty)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION5         = "%s dies, you gain %d experience. (%s exp %s penalty)"
  _G.COMBATLOG_XPGAIN_QUEST               = "You gain %d experience. (%s exp %s bonus)"
  -- Group variants (client appends the group clause).
  _G.COMBATLOG_XPGAIN_FIRSTPERSON_GROUP   = "%s dies, you gain %d experience. (+%d group bonus)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION1_GROUP   = "%s dies, you gain %d experience. (%s exp %s bonus, +%d group bonus)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION2_GROUP   = "%s dies, you gain %d experience. (%s exp %s bonus, +%d group bonus)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION4_GROUP   = "%s dies, you gain %d experience. (%s exp %s penalty, +%d group bonus)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION5_GROUP   = "%s dies, you gain %d experience. (%s exp %s penalty, +%d group bonus)"

  _G.COMBATLOG_XPGAIN_FIRSTPERSON_RAID          = "%s dies, you gain %d experience. (-%d raid penalty)"
  _G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP = "You gain %d experience. (+%d group bonus)"
  _G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID  = "You gain %d experience. (-%d raid penalty)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION1_RAID          = "%s dies, you gain %d experience. (%s exp %s bonus, -%d raid penalty)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION2_RAID          = "%s dies, you gain %d experience. (%s exp %s bonus, -%d raid penalty)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION4_RAID          = "%s dies, you gain %d experience. (%s exp %s penalty, -%d raid penalty)"
  _G.COMBATLOG_XPGAIN_EXHAUSTION5_RAID          = "%s dies, you gain %d experience. (%s exp %s penalty, -%d raid penalty)"

  -- Minimap and dropdown menu surfaces.
  _G.Minimap = _G.Minimap or stubFrame("Minimap")
  _G.Minimap.GetCenter = function() return 100, 100 end
  _G.GetCursorPosition = function()
    local c = harness.state.cursor or { x = 100, y = 100 }
    return c.x, c.y
  end
  _G.UIDropDownMenu_Initialize = function(frame, fn) harness.state.menuInit = fn end
  _G.UIDropDownMenu_CreateInfo = function() return {} end
  _G.UIDropDownMenu_AddButton = function(info)
    harness.state.menuButtons = harness.state.menuButtons or {}
    table.insert(harness.state.menuButtons, info)
  end
  _G.ToggleDropDownMenu = function() harness.state.menuToggled = true end

  _G.UnitIsGhost = function() return harness.state.isGhost end
  _G.UnitName = function(unit)
    local named = (harness.state.unitNames or {})[unit]
    if named then return named end
    return harness.state.playerName or "Tester"
  end
  _G.GetNumPartyMembers = function() return harness.state.partyMembers or 0 end
  _G.GetNumRaidMembers = function() return harness.state.raidMembers or 0 end

  _G.ERR_QUEST_COMPLETE_S   = "%s completed."
  _G.ERR_QUEST_REWARD_EXP_I = "Experience gained: %d."
  _G.ERR_ZONE_EXPLORED_XP   = "Discovered %s: %d experience gained"

  _G.QUEST_MONSTERS_KILLED = "%s slain: %d/%d"
  _G.QUEST_OBJECTS_FOUND   = "%s: %d/%d"
  _G.QUEST_ITEMS_NEEDED    = "%s: %d/%d"

  _G.EXPERIENCE_COLON = "Experience:"
  _G.MAX_PLAYER_LEVEL = 80
  _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) harness.state.chat = harness.state.chat or {}; table.insert(harness.state.chat, m) end }

  -- ==== unit / player API ====
  _G.UnitXP           = function() return harness.state.xp or 0 end
  _G.UnitXPMax        = function() return harness.state.xpMax or 1000 end
  _G.UnitLevel        = function() return harness.state.level or 1 end
  _G.GetXPExhaustion  = function() return harness.state.rested end
  _G.IsXPUserDisabled = function() return harness.state.xpDisabled end
  _G.GetRealmName     = function() return harness.state.realm or "TestRealm" end
  _G.GetZoneText      = function() return harness.state.zone or "Howling Fjord" end
  _G.GetRealZoneText  = function() return harness.state.zone or "Howling Fjord" end
  _G.GetSubZoneText   = function() return "" end
  _G.GetAddOnMetadata = function(_, field) return field == "Version" and "0.1.0" or nil end

  -- ==== inventory ====
  _G.GetInventoryItemID   = function(_, slot) return (harness.state.gear or {})[slot] end
  _G.GetInventoryItemLink = function(_, slot)
    -- Prefer the item-level fixture when one is set; fall back to gear ids.
    if (harness.state.items or {})[slot] then
      return "|cffffffff|Hitem:slot" .. slot .. "|h[Item]|h|r"
    end
    local id = (harness.state.gear or {})[slot]
    return id and ("|cffe6cc80|Hitem:" .. id .. ":0:0:0|h[Heirloom]|h|r") or nil
  end
  _G.INVSLOT_HEAD, _G.INVSLOT_NECK, _G.INVSLOT_SHOULDER = 1, 2, 3
  _G.INVSLOT_BODY, _G.INVSLOT_CHEST, _G.INVSLOT_WAIST   = 4, 5, 6
  _G.INVSLOT_LEGS, _G.INVSLOT_FEET, _G.INVSLOT_WRIST    = 7, 8, 9
  _G.INVSLOT_HAND, _G.INVSLOT_FINGER1, _G.INVSLOT_FINGER2 = 10, 11, 12
  _G.INVSLOT_TRINKET1, _G.INVSLOT_TRINKET2, _G.INVSLOT_BACK = 13, 14, 15

  -- ==== PvP ====
  -- Exactly TWO returns on 3.3.5a: hk, highestRank. Not three.
  _G.GetPVPLifetimeStats  = function()
    return harness.state.lifetimeHK or 0, harness.state.highestRank or 0
  end
  _G.GetPVPSessionStats   = function()
    return harness.state.todayHK or 0, harness.state.todayHonor or 0
  end
  _G.GetPVPYesterdayStats = function()
    return harness.state.yesterdayHK or 0, 0
  end

  -- ==== Battleground scoreboard ====
  -- GetBattlefieldScore returns TWELVE values on 3.3.5a, in this order:
  --   name, killingBlows, honorableKills, deaths, honorGained,
  --   faction, rank, race, class, classToken, damageDone, healingDone
  -- Verified against Blizzard's own FrameXML (WorldStateFrame.lua:662).
  -- Modern wiki pages give a different order; they are documenting a later
  -- expansion. faction is 0 = Horde, 1 = Alliance.
  harness.state.bgScores = harness.state.bgScores or {}
  _G.GetNumBattlefieldScores = function()
    return #(harness.state.bgScores or {})
  end
  _G.GetBattlefieldScore = function(i)
    local r = (harness.state.bgScores or {})[i]
    if not r then return nil end
    return r.name, r.killingBlows or 0, r.honorableKills or 0, r.deaths or 0,
           r.honorGained or 0, r.faction, r.rank or 0, r.race or "Human",
           r.class or "Warrior", r.classToken or "WARRIOR",
           r.damageDone or 0, r.healingDone or 0
  end
  _G.RequestBattlefieldScoreData = function()
    harness.state.scoreRequests = (harness.state.scoreRequests or 0) + 1
  end
  _G.GetBattlefieldWinner = function() return harness.state.bgWinner end
  -- IsInInstance's SECOND return names the instance type: "pvp" in a
  -- battleground, "arena", "party", "raid", or nil outside.
  _G.IsInInstance = function()
    local t = harness.state.instanceType
    return t ~= nil, t
  end
  -- Verbatim from 3.3.5a FrameXML/Constants.lua.
  _G.RAID_CLASS_COLORS = {
    ["HUNTER"] = { r = 0.67, g = 0.83, b = 0.45 },
    ["WARLOCK"] = { r = 0.58, g = 0.51, b = 0.79 },
    ["PRIEST"] = { r = 1.0, g = 1.0, b = 1.0 },
    ["PALADIN"] = { r = 0.96, g = 0.55, b = 0.73 },
    ["MAGE"] = { r = 0.41, g = 0.8, b = 0.94 },
    ["ROGUE"] = { r = 1.0, g = 0.96, b = 0.41 },
    ["DRUID"] = { r = 1.0, g = 0.49, b = 0.04 },
    ["SHAMAN"] = { r = 0.0, g = 0.44, b = 0.87 },
    ["WARRIOR"] = { r = 0.78, g = 0.61, b = 0.43 },
    ["DEATHKNIGHT"] = { r = 0.77, g = 0.12, b = 0.23 },
  }
  _G.CLASS_ICON_TCOORDS = {
    ["WARRIOR"]     = {0, 0.25, 0, 0.25},
    ["MAGE"]        = {0.25, 0.49609375, 0, 0.25},
    ["ROGUE"]       = {0.49609375, 0.7421875, 0, 0.25},
    ["DRUID"]       = {0.7421875, 0.98828125, 0, 0.25},
    ["HUNTER"]      = {0, 0.25, 0.25, 0.5},
    ["SHAMAN"]      = {0.25, 0.49609375, 0.25, 0.5},
    ["PRIEST"]      = {0.49609375, 0.7421875, 0.25, 0.5},
    ["WARLOCK"]     = {0.7421875, 0.98828125, 0.25, 0.5},
    ["PALADIN"]     = {0, 0.25, 0.5, 0.75},
    ["DEATHKNIGHT"] = {0.25, .5, 0.5, .75},
  }
  -- Milliseconds, not seconds (WorldStateFrame.lua:824).
  _G.GetBattlefieldInstanceRunTime = function()
    return harness.state.bgRunTimeMS or 0
  end
  _G.IsActiveBattlefieldArena = function() return harness.state.isArena end
  _G.GetBattlefieldFlagPosition = function(i)
    local f = (harness.state.flags or {})[i]
    if not f then return nil end
    return f.x, f.y, f.token
  end
  _G.GetNumBattlefieldFlagPositions = function()
    return #(harness.state.flags or {})
  end

  -- Three returns on 3.3.5a: name, rankName, rankIndex. Takes a UNIT token --
  -- there is no way to look a guild up by player name, and no nameplate unit
  -- tokens exist on this client.
  _G.GetGuildInfo = function(unit)
    local g = (harness.state.guilds or {})[unit]
    if not g then return nil end
    return g, "Member", 4
  end

  -- PlaySoundFile returns NOTHING on 3.3.5a: a bad path fails silently, so
  -- the addon cannot detect one. Record calls so tests can assert intent.
  _G.PlaySoundFile = function(path)
    harness.state.sounds = harness.state.sounds or {}
    table.insert(harness.state.sounds, path)
  end
  _G.PlaySound = _G.PlaySoundFile
  _G.UnitGUID = function(unit)
    if unit == "player" then return harness.state.playerGUID or "0xPLAYER" end
    return nil
  end
  _G.bit = _G.bit or {
    band = function(a, b)
      local r, m = 0, 1
      while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
      end
      return r
    end,
  }
  -- harness.state.items = { [slot] = { ilvl, quality, equipLoc } }; a slot
  -- with ilvl = false models a COLD ITEM CACHE, which is the trap on 3.3.5a.
  _G.GetItemInfo = function(link)
    local slot = tonumber(tostring(link):match("slot(%d+)"))
    local it = slot and (harness.state.items or {})[slot]
    if not it then return nil end
    if it.ilvl == false then return nil end
    return "Item", link, it.quality or 2, it.ilvl or 100, 1,
           "Armor", "Mail", 1, it.equipLoc or "INVTYPE_CHEST", "tex", 0
  end

  -- ==== quest log ====
  -- harness.state.questLog is an array of:
  --   { title, level, isHeader, isComplete, questID, xp, objectives = {{text, type, finished}} }
  local selection = 1
  _G.GetNumQuestLogEntries = function()
    local q = harness.state.questLog or {}
    local n = 0
    for _, e in ipairs(q) do if not e.isHeader then n = n + 1 end end
    return #q, n
  end
  _G.GetQuestLogTitle = function(i)
    local e = (harness.state.questLog or {})[i]
    if not e then return nil end
    -- 3.3.5a returns 10 values; questID is position 9.
    return e.title, e.level, e.questTag, e.suggestedGroup, e.isHeader,
           e.isCollapsed, e.isComplete, e.isDaily, e.questID, e.displayQuestID
  end
  _G.SelectQuestLogEntry  = function(i) selection = i end
  _G.GetQuestLogSelection = function() return selection end
  _G.GetQuestLogRewardXP  = function()
    local e = (harness.state.questLog or {})[selection]
    return e and e.xp or 0
  end
  _G.GetNumQuestLeaderBoards = function(i)
    local e = (harness.state.questLog or {})[i or selection]
    return e and e.objectives and #e.objectives or 0
  end
  _G.GetQuestLogLeaderBoard = function(j, i)
    local e = (harness.state.questLog or {})[i or selection]
    local o = e and e.objectives and e.objectives[j]
    if not o then return nil end
    return o.text, o.type or "monster", o.finished
  end

  _G.GetRewardXP = function() return harness.state.rewardXP or 0 end
  _G.GetTitleText = function() return harness.state.questGiverTitle or "" end
  _G.GetQuestLogRewardMoney = function() return 0 end

  -- ==== UI globals needed by the Bar/Box/Options modules ====
  _G.ColorPickerFrame = stubFrame("ColorPickerFrame")
  _G.ColorPickerFrame.GetColorRGB = function() return 1, 1, 1 end
  _G.ColorPickerFrame.SetColorRGB = function() end
  _G.OpacitySliderFrame = stubFrame("OpacitySliderFrame")
  _G.OpacitySliderFrame.GetValue = function() return 0 end
  _G.InterfaceOptions_AddCategory = function(panel)
    harness.state.panels = harness.state.panels or {}
    table.insert(harness.state.panels, panel)
  end
  _G.InterfaceOptionsFrame_OpenToCategory = function() end
  _G.UIDropDownMenu_Initialize = function(f, fn) f.initFn = fn end
  _G.UIDropDownMenu_CreateInfo = function() return {} end
  _G.UIDropDownMenu_AddButton = function() end
  _G.UIDropDownMenu_SetWidth = function() end
  _G.UIDropDownMenu_SetText = function(f, t) f.dropText = t end
  _G.GameFontNormal = {}
  _G.UnitClass = function() return "Warrior", "WARRIOR" end
  _G.UnitFactionGroup = function() return harness.state.faction or "Alliance" end

  _G.CreateFrame = function(_, name) return stubFrame(name) end
  _G.UIParent = stubFrame("UIParent")
  _G.GameTooltip = stubFrame("GameTooltip")
  _G.GameTooltip.AddLine = function() end
  _G.GameTooltip.AddDoubleLine = function() end
  _G.GameTooltip.SetOwner = function() end
  _G.GameTooltip.ClearLines = function() end
end

function harness.reset()
  clock = 0
  harness.state = { xp = 0, xpMax = 1000, level = 1, gear = {}, questLog = {} }
  _G.LevelPace = nil
  _G.LevelPaceDB = nil
  _G.LevelPaceCharDB = nil
  installGlobals()
end

function harness.load(path)
  local chunk, err = loadfile(path)
  if not chunk then error("could not load " .. path .. ": " .. tostring(err), 2) end
  return chunk("LevelPace", _G.LevelPace)
end

-- Load the standard module stack in TOC order.
function harness.loadCore()
  harness.load("LevelPace/Core.lua")
  harness.load("LevelPace/Compat.lua")
  harness.load("LevelPace/Data/XPTable.lua")
  return _G.LevelPace
end

-- ==== assertions ====
local pass, fail, failures = 0, 0, {}

function harness.ok(v, msg)
  if v then pass = pass + 1
  else fail = fail + 1; failures[#failures + 1] = msg or "assertion failed" end
end

function harness.eq(a, b, msg)
  if a == b then pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = string.format("%s -- expected %s, got %s",
      msg or "eq", tostring(b), tostring(a))
  end
end

function harness.near(a, b, tol, msg)
  if type(a) == "number" and math.abs(a - b) <= tol then pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = string.format("%s -- expected ~%s (+/-%s), got %s",
      msg or "near", tostring(b), tostring(tol), tostring(a))
  end
end

function harness.run(name, fn)
  harness.reset()
  local okRun, err = pcall(fn)
  if not okRun then
    fail = fail + 1
    failures[#failures + 1] = name .. " -- ERROR: " .. tostring(err)
  end
end

function harness.report()
  print(string.format("  %d passed, %d failed", pass, fail))
  for _, f in ipairs(failures) do print("    FAIL: " .. f) end
  return fail == 0
end

harness.reset()
return harness
