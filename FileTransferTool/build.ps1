# One-click build: compile to a single exe and copy it to the project root for easy double-click.
# Usage: run  .\build.ps1  in this folder.
$ErrorActionPreference = "Stop"
$env:GOROOT = "D:\dev\go"
$env:GOPATH = "D:\dev\gopath"
$env:GOMODCACHE = "D:\dev\gopath\pkg\mod"
$env:Path = "D:\dev\go\bin;D:\dev\gopath\bin;" + $env:Path
$env:NPM_CONFIG_REGISTRY = "https://registry.npmmirror.com"
Set-Location $PSScriptRoot

Write-Host "Building..." -ForegroundColor Cyan
& "D:\dev\gopath\bin\wails.exe" build
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed" -ForegroundColor Red; exit 1 }

$out = Join-Path $PSScriptRoot "FileTransfer.exe"
Copy-Item ".\build\bin\filetransfer.exe" $out -Force
Write-Host "Done. Double-click to run: $out" -ForegroundColor Green
