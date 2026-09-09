package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  return LP
end

h.run("registers a module and reads it back", function()
  local LP = load()
  local def = LP:RegisterModule({ id = "demo", title = "Demo" })
  h.ok(def, "returns the definition")
  h.eq(LP:GetModule("demo"), def, "GetModule finds it")
  h.eq(LP:GetModule("nope"), nil, "unknown id is nil")
end)

h.run("registration order is preserved", function()
  local LP = load()
  LP:RegisterModule({ id = "a" })
  LP:RegisterModule({ id = "b" })
  LP:RegisterModule({ id = "c" })
  local order = LP:ModuleOrder()
  h.eq(#order, 3, "three modules")
  h.eq(order[1], "a", "first")
  h.eq(order[3], "c", "third")
end)

h.run("ModuleOrder returns a copy, not the live table", function()
  local LP = load()
  LP:RegisterModule({ id = "a" })
  local order = LP:ModuleOrder()
  order[1] = "tampered"
  h.eq(LP:ModuleOrder()[1], "a", "internal order is unaffected")
end)

h.run("default enabled state honours def.default", function()
  local LP = load()
  LP:RegisterModule({ id = "on" })
  LP:RegisterModule({ id = "off", default = false })
  h.eq(LP:ModuleEnabled("on"), true, "default is enabled")
  h.eq(LP:ModuleEnabled("off"), false, "explicit default=false")
  h.eq(LP:ModuleEnabled("missing"), false, "unknown module is not enabled")
end)

h.run("saved state overrides the default", function()
  local LP = load()
  LP:RegisterModule({ id = "m", default = true })
  LP.db.profile.modules.m = { enabled = false }
  h.eq(LP:ModuleEnabled("m"), false, "saved false beats default true")
end)

h.run("duplicate id is refused", function()
  local LP = load()
  LP:RegisterModule({ id = "dup" })
  local ok = pcall(function() LP:RegisterModule({ id = "dup" }) end)
  h.eq(ok, false, "second registration raises")
end)

h.run("a module without an id is refused", function()
  local LP = load()
  h.eq(pcall(function() LP:RegisterModule({}) end), false, "no id raises")
  h.eq(pcall(function() LP:RegisterModule("nope") end), false, "non-table raises")
end)

h.run("enabling a module calls OnEnable exactly once", function()
  local LP = load()
  local calls = 0
  LP:RegisterModule({ id = "m", OnEnable = function() calls = calls + 1 end })
  LP:SetModuleEnabled("m", true)
  h.eq(calls, 1, "OnEnable ran")
  LP:SetModuleEnabled("m", true)
  h.eq(calls, 1, "enabling an enabled module is a no-op")
end)

h.run("disabling calls OnDisable and persists", function()
  local LP = load()
  local off = 0
  LP:RegisterModule({ id = "m", OnDisable = function() off = off + 1 end })
  LP:SetModuleEnabled("m", true)
  LP:SetModuleEnabled("m", false)
  h.eq(off, 1, "OnDisable ran")
  h.eq(LP.db.profile.modules.m.enabled, false, "state saved")
  h.eq(LP:ModuleEnabled("m"), false, "reads back disabled")
  LP:SetModuleEnabled("m", false)
  h.eq(off, 1, "disabling a disabled module is a no-op")
end)

h.run("lifecycle fires bus events", function()
  local LP = load()
  local seen = {}
  LP:On("MODULE_ENABLED", function(id) seen[#seen + 1] = "on:" .. id end)
  LP:On("MODULE_DISABLED", function(id) seen[#seen + 1] = "off:" .. id end)
  LP:RegisterModule({ id = "m" })
  LP:SetModuleEnabled("m", true)
  LP:SetModuleEnabled("m", false)
  h.eq(seen[1], "on:m", "enable event")
  h.eq(seen[2], "off:m", "disable event")
end)

h.run("a raising OnEnable does not take down the addon", function()
  local LP = load()
  LP:RegisterModule({ id = "bad", OnEnable = function() error("boom") end })
  local ok = pcall(function() LP:SetModuleEnabled("bad", true) end)
  h.eq(ok, true, "SetModuleEnabled survived")
  h.eq(LP:GetModule("bad").enabled, true, "still marked enabled")
end)

h.run("StartModules enables only what is enabled", function()
  local LP = load()
  local started = {}
  LP:RegisterModule({ id = "a", OnEnable = function() started[#started + 1] = "a" end })
  LP:RegisterModule({ id = "b", default = false,
                      OnEnable = function() started[#started + 1] = "b" end })
  LP:StartModules()
  h.eq(#started, 1, "one module started")
  h.eq(started[1], "a", "the enabled one")
end)

h.run("SetModuleEnabled on an unknown id returns false", function()
  local LP = load()
  h.eq(LP:SetModuleEnabled("ghost", true), false, "no such module")
end)

h.run("levelpace registers itself as a module", function()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Modules/LevelPace.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  local m = LP:GetModule("levelpace")
  h.ok(m, "registered")
  h.eq(m.title, "LevelPace", "has a title")
  h.eq(m.default, true, "enabled by default")
  h.eq(LP:ModuleEnabled("levelpace"), true, "reads as enabled")
end)

h.run("disabling levelpace hides its frames", function()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/Modules/LevelPace.lua")
  local LP = _G.LevelPace
  LP:InitDB()
  local shown = { bar = true, box = true, gauge = true }
  -- Field names match the real modules: Bar and Gauge use `holder`, Box uses
  -- `frame`. The previous version of this test mocked `LP.Bar.frame`, which
  -- does not exist, so it passed while the real bar was never hidden.
  LP.Bar   = { holder = { Hide = function() shown.bar = false end,
                          Show = function() shown.bar = true end } }
  LP.Box   = { frame  = { Hide = function() shown.box = false end,
                          Show = function() shown.box = true end } }
  LP.Gauge = { holder = { Hide = function() shown.gauge = false end,
                          Show = function() shown.gauge = true end } }
  LP:SetModuleEnabled("levelpace", true)
  LP:SetModuleEnabled("levelpace", false)
  h.eq(shown.bar, false, "bar hidden")
  h.eq(shown.box, false, "box hidden")
  h.eq(shown.gauge, false, "gauge hidden")
  LP:SetModuleEnabled("levelpace", true)
  h.eq(shown.bar, true, "bar shown again")
end)

-- ==== the toggle must actually stick ====
--
-- Reported from the game: turning LevelPace off made the frames "flash and
-- the boxes was still there". OnDisable hid them, and the very next TICK --
-- still reaching UI Update through the bus, which has no unsubscribe -- put
-- them straight back.

h.run("a disabled module's frames stay hidden across ticks", function()
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

  local bar = LP.Bar and LP.Bar.holder
  local box = LP.Box and LP.Box.frame
  h.ok(bar, "bar frame exists")
  h.ok(box, "box frame exists")

  LP.db.profile.bar.shown = true
  LP.db.profile.box.shown = true
  LP:SetModuleEnabled("levelpace", false)
  h.eq(bar:IsShown(), false, "bar hidden on disable")
  h.eq(box:IsShown(), false, "box hidden on disable")

  -- The tick that used to undo it.
  LP:Fire("TICK")
  LP:Fire("XP_EVENT", { total = 100 })
  h.eq(bar:IsShown(), false, "bar STILL hidden after a tick")
  h.eq(box:IsShown(), false, "box STILL hidden after a tick")

  -- And re-enabling brings them back on the next draw, without a reload.
  LP:SetModuleEnabled("levelpace", true)
  LP:Fire("TICK")
  h.eq(bar:IsShown(), true, "bar returns when switched back on")
  h.eq(box:IsShown(), true, "box returns when switched back on")
end)

-- ==== swallowed errors must surface ====

h.run("a handler error is printed once even with debug off", function()
  local LP = load()
  LP.debug = false
  local printed = {}
  LP.Print = function(_, m) printed[#printed + 1] = tostring(m) end
  LP:On("BOOM", function() error("attempt to call field 'randomseed' (a nil value)") end)
  LP:Fire("BOOM"); LP:Fire("BOOM"); LP:Fire("BOOM")
  local hits = 0
  for _, m in ipairs(printed) do if m:find("randomseed") then hits = hits + 1 end end
  h.eq(hits, 1, "reported exactly once, not zero and not three")
end)

h.run("ADDON_LOADED matches the real folder name, not a literal", function()
  h.load("LevelPace/Core.lua")
  local LP = _G.LevelPace
  h.eq(LP.ADDON_NAME, "LevelPace", "harness passes LevelPace as the vararg")
end)

os.exit(h.report() and 0 or 1)
