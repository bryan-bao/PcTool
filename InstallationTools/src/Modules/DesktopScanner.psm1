function Get-DesktopItems {
    <#
      .SYNOPSIS 扫描桌面，返回每个项的结构化信息。
      .PARAMETER Path 要扫描的目录；默认当前用户桌面 + 公共桌面。
    #>
    [CmdletBinding()]
    param([string[]]$Path)

    if (-not $Path) {
        $Path = @(
            [Environment]::GetFolderPath('Desktop'),
            [Environment]::GetFolderPath('CommonDesktopDirectory')
        ) | Where-Object { $_ -and (Test-Path $_) }
    }

    $shell = New-Object -ComObject WScript.Shell
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($dir in $Path) {
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $entry = $_
            if ($entry.Extension -eq '.lnk') {
                $sc = $shell.CreateShortcut($entry.FullName)
                $target = $sc.TargetPath
                $drive = ''
                if ($target) {
                    try { $drive = ([System.IO.Path]::GetPathRoot($target)).TrimEnd('\', ':') } catch { $drive = '' }
                }
                $status = 'unknown'
                if ($drive) {
                    if ($drive -ieq 'C') { $status = 'needreinstall' }
                    else { $status = 'restorable' }
                }
                $results.Add([pscustomobject]@{
                        Name        = [System.IO.Path]::GetFileNameWithoutExtension($entry.Name)
                        Type        = 'shortcut'
                        SourcePath  = $entry.FullName
                        Target      = $target
                        TargetDrive = $drive
                        Status      = $status
                        SizeBytes   = $entry.Length
                    })
            }
            else {
                $results.Add([pscustomobject]@{
                        Name        = $entry.Name
                        Type        = 'file'
                        SourcePath  = $entry.FullName
                        Target      = ''
                        TargetDrive = ''
                        Status      = 'restorable'
                        SizeBytes   = if ($entry.PSIsContainer) { 0 } else { $entry.Length }
                    })
            }
        }
    }
    return $results
}
Export-ModuleMember -Function Get-DesktopItems
