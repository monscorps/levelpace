@echo off
REM Reads LevelPace's saved variables, sends them, and writes Baseline.lua
REM back into your addon folder.
setlocal
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo.
  echo   Python was not found.
  echo.
  echo   Install Python 3 from python.org, and on the FIRST installer screen
  echo   tick "Add python.exe to PATH". Then run this again.
  echo.
  pause
  exit /b 1
)

set "SERVER=%LEVELPACE_SERVER%"
if "%SERVER%"=="" set "SERVER=http://localhost:8080"

echo.
echo   Server: %SERVER%
echo   (set LEVELPACE_SERVER to point somewhere else)
echo.
echo   Nothing is sent unless you enabled sharing in the addon:
echo     /lp  -^>  Leaderboard  -^>  Share my levelling stats
echo   ...and then logged out or typed /reload.
echo.

python "uploader\levelpace_upload.py" --server "%SERVER%" %*
echo.
pause
