@echo off
REM ============================================================================
REM  LevelPace uploader
REM
REM  Sends your levelling stats to the leaderboard, and brings back everyone
REM  else's so the in-game parse gauge can score you against them.
REM
REM  Needs NOTHING installed. It uses the PowerShell that already ships with
REM  Windows 10 and 11.
REM ============================================================================
setlocal
cd /d "%~dp0"

if not exist "uploader\LevelPaceUpload.ps1" (
  echo.
  echo   Cannot find uploader\LevelPaceUpload.ps1
  echo.
  echo   Run this from inside the LevelPace-Leaderboard folder, with the
  echo   folder left intact. Do not move this .bat out on its own.
  echo.
  pause
  exit /b 1
)

REM -ExecutionPolicy Bypass applies to THIS run only. It does not change any
REM setting on the machine -- without it Windows refuses to run downloaded
REM scripts and this would fail with a confusing red error.
powershell -NoProfile -ExecutionPolicy Bypass -File "uploader\LevelPaceUpload.ps1" %*
set RC=%ERRORLEVEL%

if not "%RC%"=="0" (
  echo.
  echo   Finished with errors.
  echo   Try run-uploader-dryrun.bat -- it shows what it finds and sends nothing.
)

echo.
pause
