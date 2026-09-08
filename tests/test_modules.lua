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

os.exit(h.report() and 0 or 1)
