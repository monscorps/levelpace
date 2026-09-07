-- LevelPace :: Init
--
-- Loaded LAST in the TOC. Its only job is to start the addon.
--
-- Bootstrap cannot be called from Core.lua's file scope because it needs
-- LP.util.SafeRegisterEvent, and Compat.lua loads after Core.lua. Putting the
-- call in its own final file makes the entry point explicit rather than
-- hiding it at the bottom of an unrelated module.

local LP = _G.LevelPace
LP:Bootstrap()
