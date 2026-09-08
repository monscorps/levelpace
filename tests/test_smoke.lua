package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

-- Load every file the TOC lists, in TOC order, exactly as the client would.
local function tocFiles()
  local files = {}
  for line in io.lines("LevelPace/LevelPace.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^##") and not line:match("^#") then
      files[#files + 1] = "LevelPace/" .. line:gsub("\\", "/")
    end
  end
  return files
end

h.run("every TOC file exists and loads without error", function()
  local files = tocFiles()
  h.ok(#files >= 13, "TOC lists the full stack (" .. #files .. " files)")
  for _, f in ipairs(files) do
    local fh = io.open(f, "r")
    h.ok(fh, "file exists: " .. f)
    if fh then fh:close() end
    local okLoad, err = pcall(h.load, f)
    h.ok(okLoad, "loads: " .. f .. (okLoad and "" or (" -- " .. tostring(err))))
  end
end)

h.run("full stack boots through DB_READY and PLAYER_READY", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.state.level = 71
  h.state.xp, h.state.xpMax = 250000, 1000000

  local errors = {}
  LP.debug = true
  local realPrint = LP.Print
  LP.Print = function(_, ...) 
    local msg = tostring((select(1, ...)))
    if msg:find("error in") then errors[#errors + 1] = msg end
  end

  LP:InitDB()
  LP:Fire("DB_READY")
  LP:Fire("PLAYER_READY")
  LP.Print = realPrint

  h.eq(#errors, 0, "no handler errors during boot: " .. table.concat(errors, " | "))
  h.ok(LP.db, "db initialised")
  h.ok(LP.Bar and LP.Bar.frame, "bar created")
  h.ok(LP.Box and LP.Box.frame, "box created")
  h.ok(LP.Options and LP.Options.built, "options panels registered")
  h.eq(#(h.state.panels or {}), 4, "four options panels")
end)

h.run("a full kill-to-projection round trip", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.state.level = 71
  h.state.xp, h.state.xpMax = 0, 100000
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")

  for i = 1, 12 do
    h.advance(10)
    LP.Ledger:OnChat("Ravenous Ghoul dies, you gain 500 experience.")
  end
  local r = LP.Estimator:Refresh()
  h.ok(r.baseRate and r.baseRate > 0, "a rate was measured")
  h.ok(r.timeToLevel and r.timeToLevel > 0, "time to level projected")
  h.ok(r.mobsLow and r.mobsLow > 0, "mobs to level estimated after 12 kills")
  h.eq(LP.History:Current().killCount, 12, "kills recorded")
end)

h.run("the in-game board opens with no data and says so", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")
  h.ok(LP.Board and LP.Board.frame, "board frame built")
  h.eq(LP.Board:Data(), nil, "no board file yet")
  h.ok(pcall(function() LP.Board:Toggle() end), "opens without erroring")
  h.ok(LP.Board.rows[1].text and LP.Board.rows[1].text:find("No board data"),
       "and explains why it is empty rather than showing a blank grid")
end)

h.run("the board renders a published snapshot", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")
  _G.LevelPaceBoard = {
    fetched = 0,
    overall = { { rank = 1, name = "Dan", class = "WARRIOR", level = 74,
                  parse = 97, levels = 4, best = 100 } },
    twinks = { { rank = 1, name = "Twinky", class = "ROGUE", bracket = 19,
                 ilvl = 44.5, weekly = 180, kd = 11.4,
                 nemesis = { { name = "Gankzor", count = 31 } } } },
  }
  LP.Board.view = "overall"
  h.ok(pcall(function() LP.Board:Update() end), "overall renders")
  h.ok(LP.Board.rows[1].text and LP.Board.rows[1].text:find("Dan", 1, true), "shows the player")
  h.ok(LP.Board.rows[1].text:find("ff8000") or LP.Board.rows[1].text:find("|cff"),
       "parse is colour-coded")
  LP.Board.view = "twinks"
  h.ok(pcall(function() LP.Board:Update() end), "twinks renders")
  h.ok(LP.Board.rows[1].text and LP.Board.rows[1].text:find("Gankzor", 1, true), "shows the nemesis")
  h.ok(LP.Board.footer.text and LP.Board.footer.text:find("approximate", 1, true),
       "and labels the twink numbers as approximate")
  _G.LevelPaceBoard = nil
end)

h.run("slash commands do not error", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")
  for _, cmd in ipairs({ "", "board", "reset", "quests", "share", "lock", "unlock", "show", "hide", "help" }) do
    local ok, err = pcall(LP.Dispatch, cmd)
    h.ok(ok, "/lp " .. cmd .. (ok and "" or (" -- " .. tostring(err))))
  end
end)

h.run("UI updates survive being called with no data at all", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")
  h.ok(pcall(function() LP.Bar:Update() end), "bar update on an empty session")
  h.ok(pcall(function() LP.Box:Update() end), "box update on an empty session")
  h.ok(pcall(function() LP.Tooltip:Show(LP.Bar.holder) end), "tooltip on an empty session")
  for _, layout in ipairs({ "compact", "stacked", "full" }) do
    LP.db.profile.box.layout = layout
    h.ok(pcall(function() LP.Box:ApplyStyle(); LP.Box:Update() end), "layout: " .. layout)
  end
end)


-- REGRESSION: the addon must wire itself up from loading the TOC alone, with
-- no help from the test. Bootstrap was defined but never called, which meant
-- the addon loaded in game and then did nothing at all.
h.run("loading the TOC alone registers the bootstrap events", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.ok(LP.bootstrapFrame, "Bootstrap ran at load time without being called by hand")
  if LP.bootstrapFrame then
    h.ok(LP.bootstrapFrame.events["ADDON_LOADED"], "ADDON_LOADED registered")
    h.ok(LP.bootstrapFrame.events["PLAYER_LOGIN"], "PLAYER_LOGIN registered")
    h.ok(LP.bootstrapFrame:GetScript("OnEvent"), "OnEvent handler installed")
  end
end)

-- REGRESSION: driving the real event sequence (not the internal bus) must
-- bring the whole addon up.
h.run("real ADDON_LOADED then PLAYER_LOGIN boots the addon", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.state.level = 71
  local onEvent = LP.bootstrapFrame and LP.bootstrapFrame:GetScript("OnEvent")
  h.ok(onEvent, "handler present")
  if not onEvent then return end
  onEvent(LP.bootstrapFrame, "ADDON_LOADED", "SomeOtherAddon")
  h.eq(LP.db, nil, "another addon's ADDON_LOADED is ignored")
  onEvent(LP.bootstrapFrame, "ADDON_LOADED", "LevelPace")
  h.ok(LP.db, "our ADDON_LOADED initialises the db")
  onEvent(LP.bootstrapFrame, "PLAYER_LOGIN")
  h.ok(LP.Bar and LP.Bar.frame, "bar built")
  h.ok(LP.Box and LP.Box.frame, "box built")
  h.ok(LP.driverStarted, "scheduler driver started")
end)


-- REGRESSION (reported): the display only refreshed when XP arrived, so
-- time-to-level sat frozen between kills instead of counting down.
h.run("the heartbeat refreshes the projection with no XP events at all", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.state.level, h.state.xp, h.state.xpMax = 71, 0, 100000
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")

  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 1000 experience.")
  local before = LP.Estimator:Result().timeToLevel
  h.ok(before, "a projection exists")

  -- No further XP. Only time passes, and only the scheduler runs.
  h.advance(200)
  LP:_Tick(1)
  local after = LP.Estimator:Result().timeToLevel
  h.ok(after, "still projecting")
  h.ok(after > before, "idling made the estimate WORSE, as it should")
end)

h.run("the shared TICK drives both frames", function()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.state.level, h.state.xp, h.state.xpMax = 71, 0, 100000
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")
  local ticks = 0
  LP:On("TICK", function() ticks = ticks + 1 end)
  LP:_Tick(1)
  h.eq(ticks, 1, "one tick per second")
  h.ok(LP.Bar.text and LP.Bar.text.text, "bar text was written on the tick")
end)

os.exit(h.report() and 0 or 1)
