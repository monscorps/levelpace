@echo off
REM ============================================================================
REM  LevelPace uploader -- LEAVE IT RUNNING
REM
REM  Watches for changes and uploads by itself. Because WoW only writes its
REM  saved-variables file when you log out or type /reload, in practice this
REM  means: your stats go up shortly after you finish playing, without you
REM  having to remember anything.
REM
REM  To start it automatically with Windows:
REM    1. press Win+R
REM    2. type   shell:startup   and press Enter
REM    3. put a SHORTCUT to this file in the folder that opens
REM       (right-click this file -> Create shortcut, then move the shortcut)
REM
REM  Close the window to stop it. Nothing runs in the background afterwards.
REM ============================================================================
setlocal
cd /d "%~dp0"

if not exist "uploader\LevelPaceUpload.ps1" (
  echo.
  echo   Cannot find uploader\LevelPaceUpload.ps1 -- run this from inside the
  echo   LevelPace-Leaderboard folder.
  echo.
  pause
  exit /b 1
)

echo.
echo   LevelPace uploader -- watching.
echo   Leave this window open. Close it to stop.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "uploader\LevelPaceUpload.ps1" -Watch
echo.
echo   Stopped.
pause
