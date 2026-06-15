function Invoke-DesktopRestore {
    <#
      .SYNOPSIS 按清单把备份的文件/快捷方式还原到桌面。
      .PARAMETER Manifest manifest.json 路径。
      .PARAMETER DesktopPath 还原目标（默认当前用户桌面）。
      .PARAMETER CommonDesktopPath 公共桌面路径；若同名项已在公共桌面存在，也跳过(防止复制成重复图标)。
      .PARAMETER OnlyNames 仅还原这些 Name（不传则还原清单里 Selected=true 的全部）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Manifest,
        [string]$DesktopPath = [Environment]::GetFolderPath('Desktop'),
        [string]$CommonDesktopPath = [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [string[]]$OnlyNames
    )
    if (-not (Test-Path -LiteralPath $Manifest)) { throw "找不到清单：$Manifest" }
    $root = Split-Path $Manifest -Parent
    $filesDir = Join-Path $root 'files'
    $data = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json

    $report = New-Object System.Collections.Generic.List[object]
    foreach ($it in $data.Items) {
        if (-not $it.Selected) { continue }
        if ($OnlyNames -and ($it.Name -notin $OnlyNames)) { continue }

        $leaf = Split-Path $it.SourcePath -Leaf
        $backupFile = Join-Path $filesDir $leaf
        $destPath = Join-Path $DesktopPath $leaf
        $restoreOk = $false; $note = ''

        # 关键：用户桌面 或 公共桌面 已存在同名项就跳过，
        # 避免“没重装也还原”导致的重复/嵌套，以及把公共桌面的快捷方式复制到用户桌面形成重复图标
        $commonExists = $false
        if ($CommonDesktopPath) {
            $commonExists = Test-Path -LiteralPath (Join-Path $CommonDesktopPath $leaf)
        }
        if ((Test-Path -LiteralPath $destPath) -or $commonExists) {
            $report.Add([pscustomobject]@{ Name = $it.Name; Restored = $false; Note = '桌面(或公共桌面)已存在同名项，已跳过(避免重复)' })
            continue
        }

        if ($it.Type -eq 'shortcut' -and $it.Target) {
            if (-not (Test-Path -LiteralPath $it.Target)) {
                $note = '目标本体不存在，可能需重装'
            }
        }
        if (Test-Path -LiteralPath $backupFile) {
            Copy-Item -LiteralPath $backupFile -Destination $destPath -Recurse -Force -ErrorAction SilentlyContinue
            $restoreOk = $true
        }
        $report.Add([pscustomobject]@{ Name = $it.Name; Restored = $restoreOk; Note = $note })
    }
    return $report
}
Export-ModuleMember -Function Invoke-DesktopRestore
