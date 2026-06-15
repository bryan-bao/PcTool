function Get-DiskList {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [PSCustomObject]@{
            Drive      = $_.DeviceID            # 形如 'C:'
            TotalBytes = [long]$_.Size
            FreeBytes  = [long]$_.FreeSpace
        }
    }
}

Export-ModuleMember -Function Get-DiskList
