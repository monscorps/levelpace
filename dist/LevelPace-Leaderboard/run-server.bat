@echo off
REM LevelPace leaderboard server -- runs on YOUR machine, not in WoW.
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

echo.
echo   Starting the LevelPace leaderboard server.
echo   Open http://localhost:8080 in your browser.
echo   Close this window to stop it.
echo.
python "server\levelpace_server.py" --port 8080 --db "levelpace.db"
pause
