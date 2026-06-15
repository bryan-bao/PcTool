function Get-TempItems {
    $targets = @(
        @{ Path = $env:TEMP;                          Name = '用户临时文件' }
        @{ Path = (Join-Path $env:windir 'Temp');     Name = 'Windows 临时文件' }
        @{ Path = (Join-Path $env:windir 'Prefetch'); Name = '预读取文件 (Prefetch)' }
    )
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Path)) { continue }
        $size = Get-FolderSize $t.Path
        if ($size -le 0) { continue }
        [PSCustomObject]@{
            Path        = $t.Path
            DisplayName = $t.Name
            Category    = 'Temp'
            SizeBytes   = $size
            LastUsed    = $null
        }
    }
}

Export-ModuleMember -Function Get-TempItems
