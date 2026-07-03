# One-click Windows installer build.
# Usage: run  .\build-installer.ps1  in this folder.
$ErrorActionPreference = "Stop"

$env:GOPROXY = if ($env:GOPROXY) { $env:GOPROXY } else { "https://goproxy.cn,direct" }
$env:NPM_CONFIG_REGISTRY = "https://registry.npmmirror.com"
Set-Location $PSScriptRoot

$wails = Get-Command wails.exe -ErrorAction SilentlyContinue
if (!$wails) {
    $go = Get-Command go.exe -ErrorAction SilentlyContinue
    if (!$go) {
        Write-Host "[X] Go was not found. Install Go first: https://go.dev/dl/" -ForegroundColor Red
        exit 1
    }
    Write-Host "[INFO] Wails CLI was not found. Installing it with go install..." -ForegroundColor Cyan
    & $go.Source install github.com/wailsapp/wails/v2/cmd/wails@latest
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[X] Failed to install Wails CLI" -ForegroundColor Red
        exit 1
    }
    $goPath = (& $go.Source env GOPATH).Trim()
    $env:Path = (Join-Path $goPath "bin") + ";" + $env:Path
    $wails = Get-Command wails.exe -ErrorAction SilentlyContinue
}
if (!$wails) {
    Write-Host "[X] Wails CLI was not found after install. Add GOPATH\bin to PATH and retry." -ForegroundColor Red
    exit 1
}

$makensis = Get-Command makensis.exe -ErrorAction SilentlyContinue
if (!$makensis) {
    $commonNsis = @(
        "C:\Program Files (x86)\NSIS\makensis.exe",
        "C:\Program Files\NSIS\makensis.exe"
    )
    foreach ($candidate in $commonNsis) {
        if (Test-Path -LiteralPath $candidate) {
            $env:Path = (Split-Path -Parent $candidate) + ";" + $env:Path
            $makensis = Get-Command makensis.exe -ErrorAction SilentlyContinue
            break
        }
    }
}

if (!$makensis) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "[INFO] NSIS was not found. Installing NSIS with winget..." -ForegroundColor Cyan
        & $winget.Source install -e --id NSIS.NSIS --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[X] NSIS install failed. Install it manually, then run this script again." -ForegroundColor Red
            Write-Host "    https://nsis.sourceforge.io/Download" -ForegroundColor Yellow
            exit 1
        }
        $env:Path = "C:\Program Files (x86)\NSIS;C:\Program Files\NSIS;" + $env:Path
        $makensis = Get-Command makensis.exe -ErrorAction SilentlyContinue
    }
}

if (!$makensis) {
    Write-Host "[X] NSIS was not found. Install NSIS first, then run this script again." -ForegroundColor Red
    Write-Host "    winget install -e --id NSIS.NSIS" -ForegroundColor Yellow
    Write-Host "    or download from https://nsis.sourceforge.io/Download" -ForegroundColor Yellow
    exit 1
}

Write-Host "[INFO] Building Windows installer..." -ForegroundColor Cyan
& $wails.Source build -clean -nsis -webview2 embed
if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] Installer build failed" -ForegroundColor Red
    exit 1
}

$installer = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "build\bin") -Filter "*installer.exe" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (!$installer) {
    throw "Wails build finished, but no installer exe was found in build\bin."
}

$out = Join-Path $PSScriptRoot "FileTransferSetup.exe"
Copy-Item -LiteralPath $installer.FullName -Destination $out -Force

Write-Host "[OK] Installer ready:" -ForegroundColor Green
Write-Host "     $out" -ForegroundColor Green
