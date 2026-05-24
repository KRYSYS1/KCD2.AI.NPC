@echo off
title KCD2 AI NPC Server
cd /d "%~dp0"

echo Checking dependencies...
python -c "import rich, pyfiglet" 2>nul
if errorlevel 1 (
    echo Installing rich and pyfiglet...
    python -m pip install rich pyfiglet -q
)

echo.
python run_server.py

echo.
echo ==========================================
echo Server stopped or failed to start.
echo If you see an error above, copy it or take a screenshot.
echo ==========================================
pause
