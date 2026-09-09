-- LevelPace :: Modules/LevelPace
--
-- The levelling feature set, registered as a module so it can be toggled
-- alongside Nemesis and RareFinder.
--
-- The existing files keep their own PLAYER_READY wiring. This module owns the
-- visible surface only, which is what "turn the dashboard off" means to a
-- player, and keeps this stage behaviour-neutral.

local LP = _G.LevelPace

-- Bar and Gauge keep their root frame in `holder`; Box keeps it in `frame`.
-- Looking only at `frame` meant OnDisable silently skipped the bar and the
-- gauge entirely -- they were never hidden at all, which is half of why
-- turning the module off appeared to do nothing.
local function each(fn)
  for _, part in ipairs({ LP.Bar, LP.Box, LP.Gauge }) do
    if part then
      local f = part.holder or part.frame
      if f then fn(f) end
    end
  end
end

-- Reads what the estimator already computes. This module owns presentation,
-- not measurement -- and it presents things the same way UI/Box does, so the
-- two never disagree in front of the player.
local function Dashboard()
  local util = LP.util
  local r = (LP.Estimator and LP.Estimator:Result()) or {}
  local rows = { { kind = "header", text = "Levelling" } }

  local lvl = (UnitLevel and UnitLevel("player")) or nil
  if lvl then rows[#rows + 1] = { kind = "stat", label = "Level", value = lvl } end

  -- Every finished level against everyone else's time at that level -- the
  -- per-level parse, newest first. Before the max-level return on purpose:
  -- an 80 who levelled with the addon still has these.
  local ranked = LP.Parse and LP.Parse.LevelParses and LP.Parse:LevelParses(12) or {}
  if #ranked > 0 then
    local items = {}
    for _, p in ipairs(ranked) do
      items[#items + 1] = {
        text = string.format("Level %d   %s   %.2f lvl/hr", p.level,
                             util.FormatTime(p.elapsed), p.lph),
        sub = p.pct and string.format("%d%%  %s  (of %d at this level)",
                                      math.floor(p.pct + 0.5), p.band.name, p.of)
              or (p.of > 1 and string.format("%d of %d needed at this level", p.of, LP.Parse.MIN_BASELINE)
                  or "nobody else at this level yet"),
        colour = p.band,
      }
    end
    rows[#rows + 1] = { kind = "list", title = "Your levels, ranked", items = items }
  end

  if r.maxLevel then
    rows[#rows + 1] = { kind = "empty", text = "Max level -- nothing left to project." }
    return rows
  end
  if r.xpDisabled then
    rows[#rows + 1] = { kind = "empty", text = "XP gain is turned off." }
    return rows
  end

  if r.percent then
    rows[#rows + 1] = { kind = "stat", label = "Progress",
      value = string.format("%.1f%%", r.percent) }
  end
  if r.baseRatePerHour then
    rows[#rows + 1] = { kind = "stat", label = "XP per hour",
      value = util.FormatNumber(r.baseRatePerHour), note = r.rateSource }
  end
  if r.timeToLevel then
    rows[#rows + 1] = { kind = "stat", label = "Time to level",
      value = util.FormatTime(r.timeToLevel) }
  end

  -- A RANGE, deliberately: you kill mixed-level mobs, and a single integer
  -- would be false precision. Below the sample threshold the estimator
  -- returns nothing rather than something confidently wrong.
  if r.mobsLow and r.mobsHigh then
    rows[#rows + 1] = { kind = "stat", label = "Mobs to level",
      value = (r.mobsLow == r.mobsHigh) and tostring(r.mobsLow)
              or string.format("%d-%d", r.mobsLow, r.mobsHigh) }
  end

  if r.confidence then
    rows[#rows + 1] = { kind = "stat", label = "Confidence", value = r.confidence,
      note = (r.killSampleCount or 0) .. " kill sample(s)" }
  end
  if r.gapWarning then
    rows[#rows + 1] = { kind = "empty",
      text = "Includes a break of " .. util.FormatTime(r.gapWarning) ..
             " -- projections assume you keep going." }
  end

  if #rows == 1 then
    rows[#rows + 1] = { kind = "empty", text = "Gain some XP and this fills in." }
  end
  return rows
end

LP:RegisterModule({
  id = "levelpace",
  title = "LevelPace",
  desc = "XP pace, time to level, and whether your quests beat grinding.",
  default = true,
  Dashboard = Dashboard,

  OnEnable = function()
    each(function(f) if f.Show then f:Show() end end)
  end,

  OnDisable = function()
    each(function(f) if f.Hide then f:Hide() end end)
  end,
})
