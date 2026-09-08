-- LevelPace :: Modules/LevelPace
--
-- The levelling feature set, registered as a module so it can be toggled
-- alongside Nemesis and RareFinder.
--
-- The existing files keep their own PLAYER_READY wiring. This module owns the
-- visible surface only, which is what "turn the dashboard off" means to a
-- player, and keeps this stage behaviour-neutral.

local LP = _G.LevelPace

local function each(fn)
  for _, part in ipairs({ LP.Bar, LP.Box, LP.Gauge }) do
    if part and part.frame then fn(part.frame) end
  end
end

LP:RegisterModule({
  id = "levelpace",
  title = "LevelPace",
  desc = "XP pace, time to level, and whether your quests beat grinding.",
  default = true,

  OnEnable = function()
    each(function(f) if f.Show then f:Show() end end)
  end,

  OnDisable = function()
    each(function(f) if f.Hide then f:Hide() end end)
  end,
})
