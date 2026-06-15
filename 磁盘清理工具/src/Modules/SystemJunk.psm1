# 系统垃圾扫描：Windows 更新缓存、崩溃转储、缩略图缓存、系统日志、Windows.old。
# 每项返回统一形状，并带 Targets（实际要删的若干路径，可能是文件夹或文件）。

function New-JunkItem {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Targets
    )
    $existing = @($Targets | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($existing.Count -eq 0) { return $null }
    $total = [long]0
    foreach ($p in $existing) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            $total += Get-FolderSize $p
        } else {
            try { $total += [long]((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Length) } catch { }
        }
    }
    if ($total -le 0) { return $null }
    [PSCustomObject]@{
        Path        = $existing[0]
        DisplayName = $Name
        Category    = $Category
        SizeBytes   = $total
        LastUsed    = $null
        Targets     = $existing
    }
}

function Get-WinUpdateItem {
    New-JunkItem 'WinUpdate' 'Windows 更新缓存' @(
        (Join-Path $env:windir 'SoftwareDistribution\Download')
        (Join-Path $env:windir 'SoftwareDistribution\DeliveryOptimization')
    )
}

function Get-CrashDumpItem {
    New-JunkItem 'CrashDump' '崩溃转储 / 错误报告' @(
        (Join-Path $env:windir 'Minidump')
        (Join-Path $env:windir 'MEMORY.DMP')
        (Join-Path $env:LOCALAPPDATA 'CrashDumps')
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')
    )
}

function Get-ThumbnailItem {
    $exp = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    $files = @()
    if (Test-Path -LiteralPath $exp) {
        $files += @(Get-ChildItem -LiteralPath $exp -Filter 'thumbcache_*.db' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $files += @(Get-ChildItem -LiteralPath $exp -Filter 'iconcache_*.db'  -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
    }
    $targets = @($files) + @( (Join-Path $env:LOCALAPPDATA 'D3DSCache') )
    New-JunkItem 'Thumbnails' '缩略图 / 图标缓存' $targets
}

function Get-SysLogItem {
    New-JunkItem 'SysLog' '系统日志' @( (Join-Path $env:windir 'Logs') )
}

function Get-WindowsOldItem {
    # 旧系统备份（升级后留下），可能很大，但删了不能回退——默认不勾、需用户自选。
    New-JunkItem 'WindowsOld' 'Windows.old 旧系统' @( (Join-Path $env:SystemDrive 'Windows.old') )
}

Export-ModuleMember -Function New-JunkItem, Get-WinUpdateItem, Get-CrashDumpItem, Get-ThumbnailItem, Get-SysLogItem, Get-WindowsOldItem
