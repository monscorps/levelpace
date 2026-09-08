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

os.exit(h.report() and 0 or 1)
