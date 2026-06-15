function Invoke-DesktopBackup {
    <#
      .SYNOPSIS 把选中的桌面项备份到安全目录，并写 manifest.json。
      .PARAMETER Items 扫描结果（每项需带 Selected 布尔字段）。
      .PARAMETER Destination 备份输出目录（应在非 C 盘）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$Destination
    )

    $filesDir = Join-Path $Destination 'files'
    New-Item -ItemType Directory -Force $Destination | Out-Null
    New-Item -ItemType Directory -Force $filesDir | Out-Null

    foreach ($it in ($Items | Where-Object { $_.Selected })) {
        if ($it.SourcePath -and (Test-Path -LiteralPath $it.SourcePath)) {
            $leaf = Split-Path $it.SourcePath -Leaf
            Copy-Item -LiteralPath $it.SourcePath -Destination (Join-Path $filesDir $leaf) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $manifest = [pscustomobject]@{
        CreatedAt = (Get-Date).ToString('s')
        Source    = 'desktop'
        Items     = $Items
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $Destination 'manifest.json') -Encoding UTF8
    return (Join-Path $Destination 'manifest.json')
}
Export-ModuleMember -Function Invoke-DesktopBackup
