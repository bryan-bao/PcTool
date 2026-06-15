function Test-BackupReady {
    <# .SYNOPSIS 检查备份清单是否已生成。#>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$ManifestPath)
    return (Test-Path -LiteralPath $ManifestPath)
}

function Invoke-SystemReset {
    <#
      .SYNOPSIS 触发 Windows“重置此电脑”。带备份守卫。
      .PARAMETER ManifestPath 备份清单路径，必须已存在才允许重装。
      .PARAMETER KeepFiles 是否保留个人文件（true=保留，false=全部删除）。
      .PARAMETER Execute 真正执行重装的开关；不带则只演练打印，不动系统。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [bool]$KeepFiles = $true,
        [switch]$Execute
    )
    if (-not (Test-BackupReady -ManifestPath $ManifestPath)) {
        throw '未检测到备份清单，已阻止重装。请先完成“备份桌面”。'
    }
    if (-not $Execute) {
        Write-Host '[演练] 备份已就绪。加 -Execute 才会真正重置此电脑。' -ForegroundColor Yellow
        return $false
    }
    $arg = if ($KeepFiles) { '-AllowDataLoss disabled' } else { '-CleanPC' }
    Write-Host '正在唤起“重置此电脑”向导…' -ForegroundColor Cyan
    Start-Process -FilePath 'systemreset.exe' -ArgumentList $arg -ErrorAction Stop
    return $true
}
Export-ModuleMember -Function Test-BackupReady, Invoke-SystemReset
