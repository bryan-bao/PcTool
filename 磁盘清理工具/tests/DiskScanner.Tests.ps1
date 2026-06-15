BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\DiskScanner.psm1" -Force
}

Describe 'Get-DiskList' {
    It '至少返回一个盘' {
        $disks = Get-DiskList
        $disks.Count | Should -BeGreaterThan 0
    }
    It '每个盘有盘符、总量、可用量字段' {
        $d = Get-DiskList | Select-Object -First 1
        $d.Drive    | Should -Match '^[A-Z]:$'
        $d.TotalBytes | Should -BeGreaterThan 0
        $d.PSObject.Properties.Name | Should -Contain 'FreeBytes'
    }
}
