@echo off
setlocal
title FileTransfer Installer Builder

pushd "%~dp0"

if not exist "build-installer.ps1" (
    echo ERROR: build-installer.ps1 was not found.
    echo Current directory: %CD%
    echo.
    pause
    popd
    exit /b 1
)

echo Building Windows installer...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-installer.ps1"
set "_EXIT_CODE=%ERRORLEVEL%"

echo.
if "%_EXIT_CODE%"=="0" (
    echo [OK] Done. Installer: %~dp0FileTransferSetup.exe
) else (
    echo [X] Build failed. Exit code: %_EXIT_CODE%
)
echo.
pause

popd
exit /b %_EXIT_CODE%
