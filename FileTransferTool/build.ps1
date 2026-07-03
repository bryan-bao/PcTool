# One-click build: compile to a single exe and copy it to the project root for easy double-click.
# Usage: run  .\build.ps1  in this folder.
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

Write-Host "Building..." -ForegroundColor Cyan
& $wails.Source build
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed" -ForegroundColor Red; exit 1 }

$out = Join-Path $PSScriptRoot "FileTransfer.exe"
Copy-Item ".\build\bin\filetransfer.exe" $out -Force
Write-Host "Done. Double-click to run: $out" -ForegroundColor Green
