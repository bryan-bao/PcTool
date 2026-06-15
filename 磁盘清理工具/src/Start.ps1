$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning '建议以管理员身份运行（清理系统临时文件/回收站需要）。'
}
& (Join-Path $PSScriptRoot 'UI\MainWindow.ps1')
