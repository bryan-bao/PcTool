@echo off
setlocal
title TranslationTool
cd /d "%~dp0"

if not exist "venv\Scripts\python.exe" (
  echo First run: creating Python virtual environment and installing dependencies...
  py -3 -m venv venv
  if errorlevel 1 (
    echo Failed to create venv. Install Python 3.11+ and enable "Add Python to PATH".
    pause
    exit /b 1
  )
  venv\Scripts\python.exe -m pip install -U pip
  if errorlevel 1 (
    echo Failed to upgrade pip. Check your network and retry.
    pause
    exit /b 1
  )
  venv\Scripts\python.exe -m pip install -r requirements.txt
  if errorlevel 1 (
    echo Failed to install dependencies. Check your network and retry.
    pause
    exit /b 1
  )
)

echo Starting TranslationTool. The browser will open in a moment...
start "" /min cmd /c "timeout /t 2 >nul & start http://127.0.0.1:8765"
venv\Scripts\python.exe app.py
echo.
echo TranslationTool exited. If it closed immediately, check the error above.
pause