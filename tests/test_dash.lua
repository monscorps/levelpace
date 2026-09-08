package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/UI/Lib.lua")
  h.load("LevelPace/UI/Dash.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  return LP, LP.Dash
end

local function withModules(LP)
  LP:RegisterModule({
    id = "alpha", title = "Alpha",
    Dashboard = function()
      return {
        { kind = "header", text = "Alpha things" },
        { kind = "stat", label = "Count", value = "7" },
      }
    end,
  })
  LP:RegisterModule({
    id = "beta", title = "Beta",
    Dashboard = function() return { { kind = "empty", text = "nothing yet" } } end,
  })
  -- No Dashboard function at all: must not appear as a tab.
  LP:RegisterModule({ id = "gamma", title = "Gamma" })
  LP:SetModuleEnabled("alpha", true)
  LP:SetModuleEnabled("beta", true)
  LP:SetModuleEnabled("gamma", true)
end

-- ==== tabs ====

h.run("one tab per enabled module that has a dashboard", function()
  local LP, D = load()
  withModules(LP)
  local tabs = D:Tabs()
  h.eq(#tabs, 2, "two tabs")
  h.eq(tabs[1].id, "alpha", "in registration order")
  h.eq(tabs[2].id, "beta", "second")
end)

h.run("a disabled module loses its tab", function()
  local LP, D = load()
  withModules(LP)
  LP:SetModuleEnabled("alpha", false)
  local tabs = D:Tabs()
  h.eq(#tabs, 1, "one left")
  h.eq(tabs[1].id, "beta", "the enabled one")
end)

h.run("selection falls back when the selected module is switched off", function()
  local LP, D = load()
  withModules(LP)
  D:Select("alpha")
  h.eq(D:Selected(), "alpha", "selected")
  LP:SetModuleEnabled("alpha", false)
  h.eq(D:Selected(), "beta", "fell back to a live tab rather than showing nothing")
end)

h.run("selecting an unknown or dashboard-less module is refused", function()
  local LP, D = load()
  withModules(LP)
  D:Select("alpha")
  h.eq(D:Select("nope"), false, "unknown id")
  h.eq(D:Select("gamma"), false, "no dashboard")
  h.eq(D:Selected(), "alpha", "selection unchanged")
end)

h.run("with no modules at all there is no selection and no crash", function()
  local LP, D = load()
  h.eq(#D:Tabs(), 0, "no tabs")
  h.eq(D:Selected(), nil, "nothing selected")
  h.eq(pcall(function() D:Refresh() end), true, "refresh is safe")
end)

-- ==== content ====

h.run("renders the selected module's content", function()
  local LP, D = load()
  withModules(LP)
  D:Select("alpha")
  local rows = D:Content()
  h.eq(#rows, 2, "two rows")
  h.eq(rows[1].kind, "header", "header first")
  h.eq(rows[2].value, "7", "stat value")
end)

h.run("a module whose Dashboard raises degrades to a message", function()
  local LP, D = load()
  LP:RegisterModule({
    id = "bad", title = "Bad",
    Dashboard = function() error("boom") end,
  })
  LP:SetModuleEnabled("bad", true)
  D:Select("bad")
  local rows = D:Content()
  h.eq(#rows, 1, "one row")
  h.eq(rows[1].kind, "empty", "an error becomes an empty-state, not a crash")
end)

h.run("a Dashboard returning junk is treated as empty", function()
  local LP, D = load()
  LP:RegisterModule({ id = "junk", title = "Junk", Dashboard = function() return "nope" end })
  LP:SetModuleEnabled("junk", true)
  D:Select("junk")
  local rows = D:Content()
  h.eq(rows[1].kind, "empty", "not a table -- empty state")
end)

-- ==== styling ====

h.run("style defaults exist and are complete", function()
  local LP, D = load()
  local s = LP.db.profile.dash
  h.ok(s, "dash style saved")
  h.ok(s.colors.bg, "background colour")
  h.ok(s.colors.label, "label colour")
  h.ok(s.colors.value, "value colour")
  h.ok(s.colors.header, "header colour")
  h.ok(s.font, "font")
  h.ok(s.fontSize, "size")
  h.ok(s.scale, "scale")
  h.eq(type(s.colors.bg.a), "number", "background has opacity")
end)

h.run("STYLE_CHANGED triggers a refresh", function()
  local LP, D = load()
  withModules(LP)
  local refreshed = 0
  D.Refresh = function() refreshed = refreshed + 1 end
  LP:Fire("STYLE_CHANGED")
  h.ok(refreshed >= 1, "redrew on style change")
end)

-- ==== the REAL modules ====
--
-- test_dash's other cases use fake modules, which is why a real wiring bug
-- slipped through: Dashboard() was defined on the module table but never put
-- into the RegisterModule definition, so only one tab ever appeared.

h.run("every shipped module exposes a working dashboard", function()
  for line in io.lines("LevelPace/LevelPace.toc") do
    line = string.gsub(line, "%s+$", "")
    if string.match(line, "%.lua$") and not string.match(line, "^#") then
      h.load("LevelPace/" .. (string.gsub(line, "\\", "/")))
    end
  end
  local LP = _G.LevelPace
  LP:InitDB()
  LP:StartModules()

  local tabs = LP.Dash:Tabs()
  h.eq(#tabs, 3, "three tabs, one per shipped module")

  local byID = {}
  for _, t in ipairs(tabs) do byID[t.id] = true end
  for _, want in ipairs({ "levelpace", "nemesis", "rarefinder" }) do
    h.ok(byID[want], want .. " has a tab")
    h.eq(LP.Dash:Select(want), true, "can select " .. want)
    local rows = LP.Dash:Content()
    h.ok(type(rows) == "table" and #rows > 0, want .. " renders at least one row")
  end
end)

os.exit(h.report() and 0 or 1)
