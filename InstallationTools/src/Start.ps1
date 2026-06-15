# 入口：检查管理员权限（重装/部分优化需要），然后启动界面
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning '建议以管理员身份运行（重装/部分优化需要）。'
}
& (Join-Path $PSScriptRoot 'UI\MainWindow.ps1')
