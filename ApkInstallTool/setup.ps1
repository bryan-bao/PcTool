# Bootstrap local dependencies for ApkInstallTool.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$venvPython = Join-Path $PSScriptRoot "venv\Scripts\python.exe"
$requirements = Join-Path $PSScriptRoot "requirements.txt"
$platformTools = Join-Path $PSScriptRoot "platform-tools"
$localAdb = Join-Path $platformTools "adb.exe"

function Fail($message) {
    Write-Host "[X] $message" -ForegroundColor Red
    exit 1
}

if (!(Test-Path $venvPython)) {
    $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    Write-Host "[INFO] Creating Python virtual environment..." -ForegroundColor Cyan
    if ($pyLauncher) {
        & $pyLauncher.Source -3 -m venv (Join-Path $PSScriptRoot "venv")
    }
    elseif ($python) {
        & $python.Source -m venv (Join-Path $PSScriptRoot "venv")
    }
    else {
        Fail "Python was not found. Install Python 3.11+ and enable Add Python to PATH."
    }
    if ($LASTEXITCODE -ne 0) { Fail "Failed to create venv." }
}

if (!(Test-Path $requirements)) {
    Fail "requirements.txt was not found."
}

Write-Host "[INFO] Installing Python dependencies..." -ForegroundColor Cyan
& $venvPython -m pip install -U pip
if ($LASTEXITCODE -ne 0) { Fail "Failed to upgrade pip. Check your network and retry." }
& $venvPython -m pip install -r $requirements
if ($LASTEXITCODE -ne 0) { Fail "Failed to install Python dependencies. Check your network and retry." }

if ((Test-Path $localAdb) -or (Get-Command adb.exe -ErrorAction SilentlyContinue)) {
    Write-Host "[OK] ADB is available." -ForegroundColor Green
    exit 0
}

Write-Host "[INFO] ADB was not found. Downloading official Android platform-tools..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $platformTools | Out-Null

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apk-installer-platform-tools-" + [System.Guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tmpRoot "platform-tools.zip"
$extractDir = Join-Path $tmpRoot "extract"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

try {
    Invoke-WebRequest -Uri "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" -OutFile $zipPath -UseBasicParsing
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    $srcDir = Join-Path $extractDir "platform-tools"
    foreach ($name in @("adb.exe", "AdbWinApi.dll", "AdbWinUsbApi.dll")) {
        $src = Join-Path $srcDir $name
        if (!(Test-Path $src)) { Fail "Downloaded platform-tools is missing $name." }
        Copy-Item -LiteralPath $src -Destination (Join-Path $platformTools $name) -Force
    }
}
finally {
    if (Test-Path $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[OK] ADB is ready in platform-tools." -ForegroundColor Green
