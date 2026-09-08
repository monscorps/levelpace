package.path = "./tests/?.lua;" .. package.path
local h = require("harness")

local function tocFiles()
  local files = {}
  for line in io.lines("LevelPace/LevelPace.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then
      files[#files + 1] = "LevelPace/" .. line:gsub("\\", "/")
    end
  end
  return files
end

local function boot()
  for _, f in ipairs(tocFiles()) do h.load(f) end
  local LP = _G.LevelPace
  h.state.level, h.state.xp, h.state.xpMax = 71, 25000, 100000
  LP:InitDB(); LP:Fire("DB_READY"); LP:Fire("PLAYER_READY")
  return LP
end

-- The reported bug: label and value sit on the same line anchored to opposite
-- edges, so anything wider than the frame collides in the middle.
local PAD, GAP = 8, 14
local function assertNoOverlap(LP, note)
  local p = LP.db.profile.box
  local w = LP.Box.frame:GetWidth()
  for _, row in ipairs(LP.Box.rows) do
    if p.lines[row.spec.key] then
      local lw = row.label:GetStringWidth()
      local vw = row.value:GetStringWidth()
      h.ok(lw + vw + GAP <= w - PAD * 2 + GAP + 1,
        string.format("%s: '%s' (%d) + '%s' (%d) must fit in %d",
          note, tostring(row.label:GetText()), lw,
          tostring(row.value:GetText()), vw, w))
    end
  end
end

h.run("box fits its content when empty", function()
  local LP = boot()
  LP.Box:Update()
  assertNoOverlap(LP, "empty session")
end)

h.run("box grows for a long quest line instead of overlapping", function()
  local LP = boot()
  h.state.questLog = {
    { title = "Vengeance for the Fallen of Wintergarde Keep", level = 71,
      questID = 501, xp = 45000, isComplete = 1, objectives = {} },
  }
  LP.Quests:Scan()
  for _ = 1, 5 do LP.Rates:AddQuestRatioSample(45000 * 5, 45000, 1) end
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 5000 experience.")
  LP.Box:Update()
  assertNoOverlap(LP, "long quest title")
end)

h.run("quest titles are truncated, not left to run wild", function()
  local LP = boot()
  h.state.questLog = {
    { title = "Vengeance for the Fallen of Wintergarde Keep", level = 71,
      questID = 501, xp = 45000, isComplete = 1, objectives = {} },
  }
  LP.Quests:Scan()
  LP.Box:Update()
  local text
  for _, row in ipairs(LP.Box.rows) do
    if row.spec.key == "topQuest" then text = row.value:GetText() end
  end
  h.ok(text and #text < 40, "quest line is bounded (" .. tostring(text) .. ")")
  h.ok(text and text:find("%.%.%."), "and shows an ellipsis where it was cut")
end)

h.run("box fits big numbers at high level", function()
  local LP = boot()
  h.state.level, h.state.xpMax = 79, 1670800
  h.state.rested = 900000
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 900000 experience.")
  LP.Estimator:Refresh()
  LP.Box:Update()
  assertNoOverlap(LP, "seven-figure values")
end)

h.run("box fits at every font size", function()
  local LP = boot()
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 5000 experience.")
  for _, size in ipairs({ 7, 11, 16, 24 }) do
    LP.db.profile.box.fontSize = size
    LP.Box:ApplyStyle(); LP.Box:Update()
    assertNoOverlap(LP, "font size " .. size)
  end
end)

h.run("box fits in every layout", function()
  local LP = boot()
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 5000 experience.")
  for _, layout in ipairs({ "stacked", "full", "compact" }) do
    LP.db.profile.box.layout = layout
    LP.Box:ApplyStyle(); LP.Box:Update()
    h.ok(LP.Box.frame:GetWidth() >= 140, layout .. " has a sane width")
    if layout ~= "compact" then assertNoOverlap(LP, layout) end
  end
end)

h.run("hiding lines shrinks the box", function()
  local LP = boot()
  h.advance(10)
  LP.Ledger:OnChat("Ghoul dies, you gain 5000 experience.")
  LP.db.profile.box.layout = "stacked"
  LP.Box:ApplyStyle(); LP.Box:Update()
  local tall = LP.Box.frame:GetHeight()
  for k in pairs(LP.db.profile.box.lines) do LP.db.profile.box.lines[k] = false end
  LP.db.profile.box.lines.level = true
  LP.Box:Relayout(); LP.Box:Update()
  h.ok(LP.Box.frame:GetHeight() < tall, "one line is shorter than six")
end)

h.run("box never exceeds a sane maximum width", function()
  local LP = boot()
  h.state.questLog = {
    { title = string.rep("X", 400), level = 71, questID = 1, xp = 999999,
      isComplete = 1, objectives = {} },
  }
  LP.Quests:Scan()
  LP.Box:Update()
  h.ok(LP.Box.frame:GetWidth() <= 420, "capped at 420, not 2400")
end)

os.exit(h.report() and 0 or 1)
