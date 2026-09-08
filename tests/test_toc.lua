-- Load the addon exactly as the client does: every file in the TOC, in TOC
-- order, then the real ADDON_LOADED -> PLAYER_LOGIN path.
--
-- This exists because it has already gone wrong once. Init.lua was present on
-- disk but absent from the TOC, so LP:Bootstrap() was never called: the addon
-- loaded in game and silently did nothing, while every unit test passed
-- because the tests loaded files by hand and fired the events themselves.
--
-- Anything that can only be caught by reading the TOC belongs here.

package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function tocFiles()
  local files = {}
  for line in io.lines("LevelPace/LevelPace.toc") do
    line = string.gsub(line, "%s+$", "")
    if string.match(line, "%.lua$") and not string.match(line, "^#") then
      files[#files + 1] = { toc = line, path = (string.gsub(line, "\\", "/")) }
    end
  end
  return files
end

h.run("the TOC lists at least the known core files", function()
  local files = tocFiles()
  h.ok(#files >= 20, "TOC lists " .. #files .. " lua files")
  h.eq(files[1].path, "Core.lua", "Core.lua loads first -- everything else needs LP")
  h.eq(files[#files].path, "Init.lua", "Init.lua loads last -- it is the only bootstrap")
end)

h.run("every file named in the TOC exists on disk", function()
  for _, f in ipairs(tocFiles()) do
    local fh = io.open("LevelPace/" .. f.path, "r")
    h.ok(fh, "exists: " .. f.toc)
    if fh then fh:close() end
  end
end)

h.run("every lua file on disk is named in the TOC", function()
  -- A file present but unlisted loads in tests and not in game.
  local listed = {}
  for _, f in ipairs(tocFiles()) do listed[f.path] = true end
  local pipe = io.popen("cd LevelPace && find . -name '*.lua' | sed 's|^\\./||'")
  for line in pipe:lines() do
    h.ok(listed[line], "listed in TOC: " .. line)
  end
  pipe:close()
end)

h.run("the whole addon loads in TOC order without error", function()
  for _, f in ipairs(tocFiles()) do
    local ok, err = pcall(h.load, "LevelPace/" .. f.path)
    h.ok(ok, "loaded " .. f.toc .. (ok and "" or (" -- " .. tostring(err))))
  end
end)

h.run("the real login path reaches an enabled module", function()
  for _, f in ipairs(tocFiles()) do h.load("LevelPace/" .. f.path) end
  local LP = _G.LevelPace

  LP:Bootstrap()
  h.ok(LP.bootstrapFrame, "Bootstrap created its frame")

  local bf = LP.bootstrapFrame
  bf.scripts.OnEvent(bf, "ADDON_LOADED", "LevelPace")
  h.ok(LP.db, "ADDON_LOADED initialised the database")

  bf.scripts.OnEvent(bf, "PLAYER_LOGIN")
  local order = LP:ModuleOrder()
  h.eq(#order, 1, "one module registered")
  h.eq(order[1], "levelpace", "it is levelpace")
  h.eq(LP:GetModule("levelpace").enabled, true, "PLAYER_LOGIN enabled it")
end)

os.exit(h.report() and 0 or 1)
