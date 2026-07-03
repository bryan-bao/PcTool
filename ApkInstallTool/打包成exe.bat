@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
if errorlevel 1 (
  pause
  exit /b 1
)

echo [1/2] Installing/checking PyInstaller...
venv\Scripts\python.exe -m pip install pyinstaller
if errorlevel 1 (
  pause
  exit /b 1
)

echo [2/2] Building exe...
venv\Scripts\python.exe -m PyInstaller --noconfirm --clean --windowed ^
  --name "APKInstallTool" ^
  --add-data "platform-tools;platform-tools" ^
  run.py

echo.
echo Build finished. Output folder: dist\APKInstallTool
pause