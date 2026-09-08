-- LevelPace :: Data/Icons
--
-- Rank bands and achievement icons.
--
-- Why stock WoW icons rather than custom art: 3.3.5a textures must be BLP or
-- TGA at power-of-two sizes, and an icon renders at roughly 32-40px. Painterly
-- art downscaled to 64x64 turns to mud. The game ships thousands of icons that
-- are already the right format, already in memory, and instantly readable to a
-- player who has seen them for years.
--
-- A wrong path is not fatal: the client shows the question-mark icon. FALLBACK
-- is that path, named, so the degradation is deliberate rather than accidental.

local LP = _G.LevelPace
LP.data = LP.data or {}

local ICON = "Interface\\Icons\\"
LP.data.ICON_FALLBACK = ICON .. "INV_Misc_QuestionMark"

-- ---------------------------------------------------------------------------
-- Rank bands
--
-- The five WoW item-quality colours, plus the two WarcraftLogs adds: pink for
-- 99th and gold for a 100 parse. Hex strings are the "|cffRRGGBB" body, so
-- they are usable directly in chat and font strings.
-- ---------------------------------------------------------------------------

LP.data.BANDS = {
  { id = "grey",   label = "Common",    min = 0,   hex = "9d9d9d", r = 0.62, g = 0.62, b = 0.62 },
  { id = "green",  label = "Uncommon",  min = 25,  hex = "1eff00", r = 0.12, g = 1.00, b = 0.00 },
  { id = "blue",   label = "Rare",      min = 50,  hex = "0070dd", r = 0.00, g = 0.44, b = 0.87 },
  { id = "purple", label = "Epic",      min = 75,  hex = "a335ee", r = 0.64, g = 0.21, b = 0.93 },
  { id = "orange", label = "Legendary", min = 95,  hex = "ff8000", r = 1.00, g = 0.50, b = 0.00 },
  { id = "pink",   label = "Astounding", min = 99, hex = "e268a8", r = 0.89, g = 0.41, b = 0.66 },
  { id = "gold",   label = "Perfect",   min = 100, hex = "e5cc80", r = 0.90, g = 0.80, b = 0.50 },
}

-- Highest band whose threshold the percentile meets. Ordered ascending, so
-- this walks backwards and takes the first match.
function LP.data.BandFor(pct)
  if type(pct) ~= "number" then return nil end
  local bands = LP.data.BANDS
  for i = #bands, 1, -1 do
    if pct >= bands[i].min then return bands[i] end
  end
  return bands[1]
end

function LP.data.Colourise(text, band)
  if not band then return tostring(text) end
  return "|cff" .. band.hex .. tostring(text) .. "|r"
end

-- ---------------------------------------------------------------------------
-- Achievement icons
--
-- Every path below is a stock 3.3.5a icon. Where an obvious thematic match
-- exists it is used; where it does not, a legible generic beats a clever
-- obscure one, because this is read at 32px in a list.
-- ---------------------------------------------------------------------------

LP.data.ACHIEVEMENT_ICONS = {
  -- Kill counts
  firstblood  = ICON .. "Ability_Rogue_Ambush",
  tencount    = ICON .. "Ability_Warrior_Cleave",
  century     = ICON .. "Ability_Warrior_Rampage",

  -- Streaks
  streak5     = ICON .. "Ability_Warrior_Charge",
  streak10    = ICON .. "Ability_Warrior_InnerRage",
  streak25    = ICON .. "Spell_Fire_MeteorStorm",

  -- Burst
  bloodbath   = ICON .. "Ability_Warrior_BloodBath",

  -- Nemesis
  revenge     = ICON .. "Ability_Warrior_Revenge",
  nemesisdown = ICON .. "Ability_Rogue_Eviscerate",
  evenscore   = ICON .. "Ability_Warrior_ChallangeShout",  -- Blizzard's spelling
  archrival   = ICON .. "Spell_Shadow_ShadowWordPain",
  humbled     = ICON .. "Spell_Holy_Rebirth",

  -- Breadth and gear
  wellrounded = ICON .. "Achievement_BG_winWSG",
  geared      = ICON .. "INV_Chest_Plate06",
}

function LP.data.AchievementIcon(id)
  return LP.data.ACHIEVEMENT_ICONS[id] or LP.data.ICON_FALLBACK
end
