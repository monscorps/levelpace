@echo off
REM ============================================================================
REM  LevelPace uploader -- TEST RUN
REM
REM  Shows you EXACTLY what would be sent, and sends nothing at all.
REM  Run this first if you want to see what leaves your machine before any
REM  of it does. That is a reasonable thing to want.
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
echo   TEST RUN. Nothing will be uploaded and nothing will be changed.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "uploader\LevelPaceUpload.ps1" -DryRun -NoBaseline
echo.
pause
