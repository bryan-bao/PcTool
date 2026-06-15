BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Analyzer.psm1"   -Force   # New-JunkItem 用到 Get-FolderSize
    Import-Module "$PSScriptRoot\..\src\Modules\SystemJunk.psm1" -Force
    $script:tmp = Join-Path $env:TEMP ('dcjunk_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    Set-Content -Path (Join-Path $script:tmp 'a.bin') -Value ('x' * 5000)
}
AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'New-JunkItem' {
    It '对存在的文件夹返回汇总项（含 Targets 与总大小）' {
        $item = New-JunkItem 'TestCat' '测试垃圾' @($script:tmp)
        $item | Should -Not -BeNullOrEmpty
        $item.Category  | Should -Be 'TestCat'
        $item.SizeBytes | Should -BeGreaterOrEqual 5000
        $item.Targets   | Should -Contain $script:tmp
    }
    It '全部路径都不存在时返回 null' {
        New-JunkItem 'TestCat' '空' @('X:\没有_a', 'Y:\没有_b') | Should -BeNullOrEmpty
    }
    It '会过滤掉不存在的路径，只保留存在的' {
        $item = New-JunkItem 'TestCat' '混合' @($script:tmp, 'X:\不存在_zzz')
        $item.Targets.Count | Should -Be 1
    }
}

Describe '各扫描函数不抛异常、返回 null 或合法项' {
    It 'Get-WinUpdateItem'  { { Get-WinUpdateItem }  | Should -Not -Throw }
    It 'Get-CrashDumpItem'  { { Get-CrashDumpItem }  | Should -Not -Throw }
    It 'Get-ThumbnailItem'  { { Get-ThumbnailItem }  | Should -Not -Throw }
    It 'Get-SysLogItem'     { { Get-SysLogItem }     | Should -Not -Throw }
    It 'Get-WindowsOldItem' { { Get-WindowsOldItem } | Should -Not -Throw }
    It '返回项（若有）带 Category 和 Targets' {
        foreach ($fn in 'Get-WinUpdateItem','Get-CrashDumpItem','Get-ThumbnailItem','Get-SysLogItem') {
            $r = & $fn
            if ($r) { $r.Category | Should -Not -BeNullOrEmpty; $r.Targets | Should -Not -BeNullOrEmpty }
        }
    }
}
