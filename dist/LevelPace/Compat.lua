-- LevelPace :: Compat
-- Small utilities. The important one is ConvertGlobalString.

local LP = _G.LevelPace
LP.util = {}
local util = LP.util

-- Turn a WoW format string into a Lua pattern with captures.
--
-- The escape step is load-bearing. Every Lua magic character that appears
-- LITERALLY in the message must be escaped -- including + and -, which appear
-- in "(+86 exp Rested bonus, +12 group bonus)". But % must NOT be escaped,
-- because % is what marks the %s / %d placeholders we still have to find.
--
-- The naive converter that escapes only ( and ) matches the plain strings
-- fine and then silently fails on every _GROUP variant, because Lua reads the
-- literal + as a quantifier. That failure is invisible: you just never get
-- an event.
function util.ConvertGlobalString(fmt)
  if type(fmt) ~= "string" then return nil end
  local p = fmt
  -- 1. escape magic characters, deliberately excluding % and $
  p = string.gsub(p, "([%^%(%)%.%[%]%*%+%-%?])", "%%%1")
  -- 2. indexed placeholders first (%1$s), so they are not eaten by step 3
  p = string.gsub(p, "%%(%d)%$s", "(.-)")
  p = string.gsub(p, "%%(%d)%$d", "(%%d+)")
  -- 3. plain placeholders. %s is non-greedy so adjacent captures split.
  p = string.gsub(p, "%%s", "(.-)")
  p = string.gsub(p, "%%d", "(%%d+)")
  -- 4. any leftover literal $
  p = string.gsub(p, "%$", "%%$")
  return "^" .. p .. "$"
end

-- Registering an event that does not exist on 3.3.5a raises a hard Lua error
-- ('Attempt to register unknown event "X"') and aborts addon load. Every
-- registration goes through here.
function util.SafeRegisterEvent(frame, event)
  if not frame or not frame.RegisterEvent then return false end
  local ok = pcall(frame.RegisterEvent, frame, event)
  return ok and true or false
end

function util.Round(n, dp)
  if type(n) ~= "number" then return nil end
  local m = 10 ^ (dp or 0)
  return math.floor(n * m + 0.5) / m
end

function util.FormatTime(sec)
  if type(sec) ~= "number" or sec ~= sec or sec < 0 or sec == math.huge then return "--" end
  sec = math.floor(sec)
  if sec < 60 then return sec .. "s" end
  if sec < 3600 then
    return string.format("%dm %ds", math.floor(sec / 60), sec % 60)
  end
  return string.format("%dh %dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

function util.FormatNumber(n)
  if type(n) ~= "number" then return "--" end
  local neg = n < 0
  local s = tostring(math.floor(math.abs(n)))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  out = out:gsub("^,", "")
  return (neg and "-" or "") .. out
end

function util.CopyDefaults(dst, src)
  if type(dst) ~= "table" then dst = {} end
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = util.CopyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

function util.Median(list)
  if type(list) ~= "table" then return nil end
  local n = #list
  if n == 0 then return nil end
  local copy = {}
  for i = 1, n do copy[i] = list[i] end
  table.sort(copy)
  if n % 2 == 1 then return copy[(n + 1) / 2] end
  return (copy[n / 2] + copy[n / 2 + 1]) / 2
end

-- Value at a percentile (0..1) of a sorted copy. Used for the mobs-to-level
-- interquartile range.
function util.Percentile(list, p)
  local n = #list
  if n == 0 then return nil end
  local copy = {}
  for i = 1, n do copy[i] = list[i] end
  table.sort(copy)
  local idx = math.floor(p * (n - 1)) + 1
  if idx < 1 then idx = 1 end
  if idx > n then idx = n end
  return copy[idx]
end

-- A bounded ring buffer of numbers. Used for every rolling sample window so
-- nothing grows without limit across a long session.
function util.PushBounded(list, value, maxN)
  list[#list + 1] = value
  while #list > maxN do table.remove(list, 1) end
  return list
end

-- Strip the sign and any stray characters off a captured amount like "+86".
function util.ToNumber(s)
  if type(s) == "number" then return s end
  if type(s) ~= "string" then return nil end
  local digits = string.match(s, "(%d+)")
  return digits and tonumber(digits) or nil
end
