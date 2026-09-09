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
  return LP, LP.Meter
end

-- ==== views ====

h.run("has views and one is selected", function()
  local LP, M = boot()
  local views = M:Views()
  h.ok(#views >= 2, #views .. " views")
  h.ok(M:Current(), "something is selected")
end)

h.run("cycling wraps around", function()
  local LP, M = boot()
  local n = #M:Views()
  local first = M:Current()
  for _ = 1, n do M:Cycle(1) end
  h.eq(M:Current(), first, "a full cycle returns to the start")
end)

h.run("cycling backwards works too", function()
  local LP, M = boot()
  local first = M:Current()
  M:Cycle(1)
  h.ok(M:Current() ~= first, "moved")
  M:Cycle(-1)
  h.eq(M:Current(), first, "and back")
end)

h.run("the selected view is remembered", function()
  local LP, M = boot()
  M:Cycle(1)
  local chosen = M:Current()
  h.eq(LP.db.profile.meter.view, chosen, "persisted to the profile")
end)

h.run("an unknown saved view falls back rather than showing nothing", function()
  local LP, M = boot()
  LP.db.profile.meter.view = "a-view-that-was-removed"
  h.ok(M:Current(), "still resolves to a real view")
  h.ok(M:Rows() ~= nil, "and can render")
end)

-- ==== rows ====

h.run("every view returns a list, never nil", function()
  local LP, M = boot()
  for _, v in ipairs(M:Views()) do
    M:Select(v.id)
    local rows = M:Rows()
    h.eq(type(rows), "table", v.id .. " returns a table")
  end
end)

h.run("a view whose data source raises degrades to empty", function()
  local LP, M = boot()
  M:AddView({ id = "broken", title = "Broken",
              rows = function() error("boom") end })
  M:Select("broken")
  local rows = M:Rows()
  h.eq(type(rows), "table", "still a table")
  h.eq(#rows, 0, "empty rather than a crash")
end)

h.run("rows are capped so a huge board cannot blow up the frame", function()
  local LP, M = boot()
  M:AddView({ id = "many", title = "Many", rows = function()
    local out = {}
    for i = 1, 500 do out[i] = { name = "P" .. i, value = i, pct = 50 } end
    return out
  end })
  M:Select("many")
  h.ok(#M:Rows() <= M.MAX_ROWS, "capped at " .. M.MAX_ROWS)
end)

h.run("the battleground view ranks your team by damage", function()
  local LP, M = boot()
  h.state.faction = "Alliance"
  h.state.playerName = "Me"
  h.state.bgScores = {
    { name = "Me",    faction = 1, damageDone = 300, healingDone = 0 },
    { name = "Mate",  faction = 1, damageDone = 900, healingDone = 0 },
    { name = "Enemy", faction = 0, damageDone = 999, healingDone = 0 },
  }
  M:Select("bgdamage")
  local rows = M:Rows()
  h.eq(#rows, 2, "own team only")
  h.eq(rows[1].name, "Mate", "highest first")
  h.eq(rows[2].isYou, true, "you are marked")
  h.ok(rows[1].band, "banded")
end)

h.run("the healing view lists only players who healed", function()
  local LP, M = boot()
  h.state.faction = "Alliance"
  h.state.playerName = "Me"
  h.state.bgScores = {
    { name = "Me",     faction = 1, damageDone = 900, healingDone = 0 },
    { name = "Healer", faction = 1, damageDone = 10,  healingDone = 5000 },
    { name = "Dps",    faction = 1, damageDone = 800, healingDone = 0 },
  }
  M:Select("bghealing")
  local rows = M:Rows()
  h.eq(#rows, 1, "only the one who actually healed")
  h.eq(rows[1].name, "Healer", "the healer")
end)

h.run("outside a battleground the bg views say so, rather than break", function()
  h.state.instanceType = nil
  local LP, M = boot()
  h.state.bgScores = {}
  M:Select("bgdamage")
  h.eq(#M:Rows(), 1, "one line: the reason")
  h.eq(M:Rows()[1].name, "not in a battleground", "says why")
  M:Select("bghealing")
  h.eq(M:Rows()[1].name, "not in a battleground", "same for healing")
end)

-- ==== visibility and cost ====

h.run("starts hidden and toggles", function()
  local LP, M = boot()
  h.eq(M:IsShown(), false, "off by default -- an always-on panel must be opt in")
  M:Toggle()
  h.eq(M:IsShown(), true, "shown")
  h.eq(LP.db.profile.meter.shown, true, "and remembered")
  M:Toggle()
  h.eq(M:IsShown(), false, "hidden again")
end)

h.run("a hidden meter does no work on tick", function()
  local LP, M = boot()
  local refreshes = 0
  local real = M.Refresh
  M.Refresh = function(...) refreshes = refreshes + 1; return real(...) end
  -- Hidden: the tick must not walk the scoreboard. This runs every second,
  -- in a 40-player battleground, forever.
  LP:Fire("TICK")
  h.eq(refreshes, 0, "no refresh while hidden")
  M:Toggle()
  LP:Fire("TICK")
  h.ok(refreshes >= 1, "refreshes once shown")
end)

h.run("geometry is remembered", function()
  local LP, M = boot()
  M:Toggle()
  M:SetSize(320, 240)
  h.eq(LP.db.profile.meter.width, 320, "width saved")
  h.eq(LP.db.profile.meter.height, 240, "height saved")
end)

h.run("size is clamped to something usable", function()
  local LP, M = boot()
  M:Toggle()
  M:SetSize(10, 10)
  h.ok(LP.db.profile.meter.width >= M.MIN_WIDTH, "not narrower than MIN_WIDTH")
  h.ok(LP.db.profile.meter.height >= M.MIN_HEIGHT, "not shorter than MIN_HEIGHT")
end)

-- ==== BG log view ====

h.run("the BG log view sits right after BG damage", function()
  local LP, M = boot()
  local ids = {}
  for i, v in ipairs(M:Views()) do ids[v.id] = i end
  h.eq(ids.bglog, ids.bgdamage + 1, "one click from the damage view")
end)

h.run("the BG log lists newest first, stamped with the match clock", function()
  h.state.instanceType = "pvp"; h.state.bgRunTimeMS = 65000
  local LP, M = boot()
  local N = LP.Nemesis
  N:Log("joined", "Late", "Late joined")
  h.state.bgRunTimeMS = 130000
  N:Log("kill", "Sneaky", "You killed Sneaky")
  M:Select("bglog")
  local rows = M:Rows()
  h.eq(#rows, 2, "two entries")
  h.eq(rows[1].name, "You killed Sneaky", "newest first")
  h.eq(rows[1].label, "2:10", "match clock on the right")
  h.eq(rows[2].label, "1:05", "older below")
  h.eq(rows[1].fill, 0, "no bar on a log line")
  h.ok(rows[1].band and rows[1].band.r, "coloured by kind")
  h.state.instanceType = nil
end)

h.run("empty views say why they are empty", function()
  h.state.instanceType = nil
  h.state.bgScores = {}
  local LP, M = boot()
  M:Select("bgdamage")
  h.eq(M:Rows()[1].name, "not in a battleground", "outside")
  h.state.instanceType = "pvp"
  h.ok(M:Rows()[1].name:find("waiting for the scoreboard", 1, true), "inside, before scores arrive")
  M:Select("bglog")
  h.eq(M:Rows()[1].name, "nothing has happened yet", "log: inside, nothing yet")
  -- Loaded, and simply nobody has healed: a different fact from "loading".
  h.state.bgScores = { { name = "Me", faction = 1, damageDone = 10, healingDone = 0 } }
  M:Select("bghealing")
  h.eq(M:Rows()[1].name, "nobody on your team has any yet", "loaded but empty says so")
  h.state.bgScores = {}
  h.state.instanceType = nil
end)

os.exit(h.report() and 0 or 1)
