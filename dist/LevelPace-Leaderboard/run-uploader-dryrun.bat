@echo off
REM Shows EXACTLY what would be uploaded. Sends nothing. Run this first.
setlocal
cd /d "%~dp0"
where python >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Install Python 3 from python.org and tick
  echo "Add python.exe to PATH" on the first installer screen.
  pause
  exit /b 1
)
echo.
echo   DRY RUN -- nothing will be sent anywhere.
echo.
python "uploader\levelpace_upload.py" --dry-run --no-baseline
echo.
pause
