function Get-OptimizationItems {
    <# .SYNOPSIS 列出可选的优化项。#>
    [CmdletBinding()] param()
    return @(
        [pscustomobject]@{ Id = 'show-file-ext'; Name = '显示文件扩展名'; Description = '资源管理器里显示 .txt/.exe 等后缀，避免被伪装' }
    )
}

function Invoke-Optimization {
    <# .SYNOPSIS 执行某个优化项（支持 -WhatIf）。 #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Id)

    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    switch ($Id) {
        'show-file-ext' {
            if ($PSCmdlet.ShouldProcess('注册表 HideFileExt', '设为 0（显示后缀）')) {
                Set-ItemProperty -Path $advanced -Name 'HideFileExt' -Value 0 -Type DWord
            }
        }
        default { throw "未知优化项：$Id" }
    }
}
Export-ModuleMember -Function Get-OptimizationItems, Invoke-Optimization
