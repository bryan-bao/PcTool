function Get-BrowserCacheItems {
    $local = $env:LOCALAPPDATA
    $browsers = @(
        @{ Name = 'Chrome 缓存'; Base = "$local\Google\Chrome\User Data" }
        @{ Name = 'Edge 缓存';   Base = "$local\Microsoft\Edge\User Data" }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path -LiteralPath $b.Base)) { continue }
        # 各用户配置（Default、Profile 1...）下的 Cache 目录
        $cacheDirs = Get-ChildItem -LiteralPath $b.Base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
            ForEach-Object { Join-Path $_.FullName 'Cache' } |
            Where-Object { Test-Path -LiteralPath $_ }
        $total = 0
        foreach ($c in $cacheDirs) { $total += Get-FolderSize $c }
        if ($total -le 0) { continue }
        [PSCustomObject]@{
            Path        = $b.Base
            DisplayName = $b.Name
            Category    = 'BrowserCache'
            SizeBytes   = [long]$total
            LastUsed    = $null
            CacheDirs   = $cacheDirs   # 删除时用：只删这些 Cache 子目录
        }
    }
}

Export-ModuleMember -Function Get-BrowserCacheItems
