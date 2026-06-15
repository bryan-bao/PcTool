function Get-RecycleBinItem {
    # 用 Shell COM 枚举回收站，累加占用大小
    $shell = New-Object -ComObject Shell.Application
    $bin = $shell.NameSpace(0xA)   # ssfBITBUCKET = 回收站
    if ($null -eq $bin) { return $null }
    $total = 0
    foreach ($it in $bin.Items()) {
        try { $total += [long]$it.Size } catch { }
    }
    if ($total -le 0) { return $null }
    [PSCustomObject]@{
        Path        = '回收站'
        DisplayName = '回收站'
        Category    = 'RecycleBin'
        SizeBytes   = [long]$total
        LastUsed    = $null
    }
}

function Clear-AllRecycleBin {
    # 彻底清空所有盘回收站（回收站本就是要清空的）
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-RecycleBinItem, Clear-AllRecycleBin
