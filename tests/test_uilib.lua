package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function load()
  h.load("LevelPace/Core.lua")
  h.load("LevelPace/Compat.lua")
  h.load("LevelPace/UI/Lib.lua")
  return _G.LevelPace
end

h.run("Panel builds a frame with a backdrop", function()
  local LP = load()
  local f = LP.UI.Panel("TestPanel", { width = 200, height = 80 })
  h.ok(f, "frame returned")
  h.eq(f:GetWidth(), 200, "width applied")
  h.eq(f:GetHeight(), 80, "height applied")
  h.eq(f:GetName(), "TestPanel", "named")
end)

h.run("ApplyColor handles a colour table with alpha", function()
  local LP = load()
  local region = { }
  function region:SetTexture(r, g, b, a) self.c = { r, g, b, a } end
  LP.UI.ApplyColor(region, { r = 0.5, g = 0.25, b = 1, a = 0.8 })
  h.eq(region.c[1], 0.5, "r")
  h.eq(region.c[4], 0.8, "a")
end)

h.run("ApplyColor defaults a missing alpha to 1", function()
  local LP = load()
  local region = {}
  function region:SetTexture(r, g, b, a) self.c = { r, g, b, a } end
  LP.UI.ApplyColor(region, { r = 1, g = 1, b = 1 })
  h.eq(region.c[4], 1, "alpha defaulted")
end)

h.run("ApplyColor ignores junk rather than raising", function()
  local LP = load()
  local region = {}
  function region:SetTexture() self.called = true end
  h.eq(pcall(LP.UI.ApplyColor, region, nil), true, "nil colour is safe")
  h.eq(pcall(LP.UI.ApplyColor, nil, { r = 1, g = 1, b = 1 }), true, "nil region is safe")
end)

h.run("ApplyFont sets path, size and outline", function()
  local LP = load()
  local fs = {}
  function fs:SetFont(p, s, o) self.font = { p, s, o } end
  LP.UI.ApplyFont(fs, { font = "Fonts\\FRIZQT__.TTF", fontSize = 13, outline = "OUTLINE" })
  h.eq(fs.font[1], "Fonts\\FRIZQT__.TTF", "path")
  h.eq(fs.font[2], 13, "size")
  h.eq(fs.font[3], "OUTLINE", "outline")
end)

os.exit(h.report() and 0 or 1)
