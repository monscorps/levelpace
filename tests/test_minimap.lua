package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function boot()
  for line in io.lines("LevelPace/LevelPace.toc") do
    line = string.gsub(line, "%s+$", "")
    if string.match(line, "%.lua$") and not string.match(line, "^#") then
      h.load("LevelPace/" .. (string.gsub(line, "\\", "/")))
    end
  end
  local LP = _G.LevelPace
  LP:InitDB()
  LP:Fire("PLAYER_READY")
  LP:StartModules()
  return LP, LP.Minimap
end

-- ==== ring maths ====

h.run("angle maps onto the minimap ring", function()
  local LP, MM = boot()
  local x, y = MM:PositionFor(0)
  h.near(x, MM.RADIUS, 0.01, "0 degrees is due right")
  h.near(y, 0, 0.01, "and level")

  x, y = MM:PositionFor(90)
  h.near(x, 0, 0.01, "90 degrees is straight up")
  h.near(y, MM.RADIUS, 0.01, "y at radius")

  x, y = MM:PositionFor(180)
  h.near(x, -MM.RADIUS, 0.01, "180 is due left")
end)

h.run("the point always sits on the ring, never inside or outside", function()
  local LP, MM = boot()
  for deg = 0, 359, 17 do
    local x, y = MM:PositionFor(deg)
    h.near(math.sqrt(x * x + y * y), MM.RADIUS, 0.01, "radius holds at " .. deg)
  end
end)

h.run("angles outside 0-360 are normalised rather than flying off", function()
  local LP, MM = boot()
  local a, b = MM:PositionFor(0)
  local c, d = MM:PositionFor(360)
  h.near(a, c, 0.01, "360 == 0 (x)")
  h.near(b, d, 0.01, "360 == 0 (y)")
  local e, f = MM:PositionFor(-90)
  local g, i = MM:PositionFor(270)
  h.near(e, g, 0.01, "-90 == 270 (x)")
  h.near(f, i, 0.01, "-90 == 270 (y)")
end)

h.run("a cursor position converts back to an angle", function()
  local LP, MM = boot()
  h.near(MM:AngleFrom(10, 0), 0, 0.01, "right of centre")
  h.near(MM:AngleFrom(0, 10), 90, 0.01, "above centre")
  h.near(MM:AngleFrom(-10, 0), 180, 0.01, "left of centre")
  -- Dead centre has no meaningful angle; it must not produce NaN.
  local a = MM:AngleFrom(0, 0)
  h.eq(a == a, true, "not NaN")
end)

h.run("the angle is remembered", function()
  local LP, MM = boot()
  MM:SetAngle(123)
  h.eq(LP.db.profile.minimap.angle, 123, "persisted")
  MM:SetAngle(420)
  h.near(LP.db.profile.minimap.angle, 60, 0.01, "normalised before saving")
end)

-- ==== visibility ====

h.run("the button is shown by default and can be hidden", function()
  local LP, MM = boot()
  h.eq(MM:IsShown(), true, "visible by default -- it is the way in")
  MM:Toggle()
  h.eq(MM:IsShown(), false, "hidden")
  h.eq(LP.db.profile.minimap.shown, false, "remembered")
  MM:Toggle()
  h.eq(MM:IsShown(), true, "back")
end)

-- ==== menu ====

h.run("the menu lists the things the slash commands do", function()
  local LP, MM = boot()
  local items = MM:MenuItems()
  local byText = {}
  for _, it in ipairs(items) do byText[it.text or ""] = it end
  for _, want in ipairs({ "Meter", "Dashboard", "Leaderboard", "Options" }) do
    h.ok(byText[want], want .. " is in the menu")
  end
end)

h.run("every module gets a checkable entry", function()
  local LP, MM = boot()
  local items = MM:MenuItems()
  local found = {}
  for _, it in ipairs(items) do
    if it.moduleID then found[it.moduleID] = it end
  end
  for _, id in ipairs({ "levelpace", "nemesis", "rarefinder" }) do
    h.ok(found[id], id .. " has a menu entry")
    h.eq(found[id].checked, true, id .. " shows as on")
  end
end)

h.run("a module entry reflects being switched off", function()
  local LP, MM = boot()
  LP:SetModuleEnabled("nemesis", false)
  for _, it in ipairs(MM:MenuItems()) do
    if it.moduleID == "nemesis" then h.eq(it.checked, false, "unchecked") end
  end
end)

h.run("clicking a module entry toggles that module", function()
  local LP, MM = boot()
  for _, it in ipairs(MM:MenuItems()) do
    if it.moduleID == "rarefinder" then it.func() end
  end
  h.eq(LP:ModuleEnabled("rarefinder"), false, "switched off by the menu")
end)

h.run("the meter entry reflects and toggles the meter", function()
  local LP, MM = boot()
  local meterItem
  for _, it in ipairs(MM:MenuItems()) do
    if it.text == "Meter" then meterItem = it end
  end
  h.eq(meterItem.checked, false, "meter starts hidden")
  meterItem.func()
  h.eq(LP.Meter:IsShown(), true, "menu opened it")
end)

h.run("no menu entry is missing its handler", function()
  local LP, MM = boot()
  for _, it in ipairs(MM:MenuItems()) do
    if not it.isTitle and not it.disabled and it.text ~= "" then
      h.eq(type(it.func), "function", (it.text or "?") .. " has a handler")
    end
  end
end)

os.exit(h.report() and 0 or 1)
