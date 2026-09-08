-- LevelPace :: UI/Lib
--
-- Shared frame, colour and font helpers. Every module dashboard is built from
-- these so the colour/opacity/font/size options behave identically everywhere
-- instead of each module growing its own copy.

local LP = _G.LevelPace
LP.UI = LP.UI or {}
local UI = LP.UI

local BACKDROP = {
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

function UI.Panel(name, opts)
  if not CreateFrame then return nil end
  opts = opts or {}
  local f = CreateFrame("Frame", name, opts.parent or UIParent)
  f:SetWidth(opts.width or 200)
  f:SetHeight(opts.height or 100)
  f:SetPoint(opts.point or "CENTER", UIParent,
             opts.relPoint or "CENTER", opts.x or 0, opts.y or 0)
  if f.SetBackdrop then f:SetBackdrop(opts.backdrop or BACKDROP) end
  if opts.movable and f.SetMovable then
    f:SetMovable(true)
    f:EnableMouse(true)
  end
  return f
end

function UI.ApplyColor(region, color)
  if not region or not color then return end
  local a = color.a
  if a == nil then a = 1 end
  if region.SetTexture then
    region:SetTexture(color.r or 0, color.g or 0, color.b or 0, a)
  elseif region.SetTextColor then
    region:SetTextColor(color.r or 0, color.g or 0, color.b or 0, a)
  end
end

function UI.ApplyFont(fontString, style)
  if not fontString or not style or not fontString.SetFont then return end
  fontString:SetFont(style.font or "Fonts\\FRIZQT__.TTF",
                     style.fontSize or 11,
                     style.outline or "")
end

function UI.Style(frame, style)
  if not frame or not style then return end
  if style.scale and frame.SetScale then frame:SetScale(style.scale) end
  if style.alpha and frame.SetAlpha then frame:SetAlpha(style.alpha) end
end
