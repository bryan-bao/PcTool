BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\LargeFiles.psm1" -Force
    $script:tmp = Join-Path $env:TEMP ('dclarge_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    # 造一个 2MB 的大文件、一个小文件
    $fs = [System.IO.File]::Create((Join-Path $script:tmp 'big.bin'))
    $fs.SetLength(2MB); $fs.Close()
    Set-Content -Path (Join-Path $script:tmp 'small.txt') -Value 'tiny'
}
AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-LargeFiles' {
    It '只返回超过阈值的文件' {
        $items = Get-LargeFiles -Roots @($script:tmp) -MinBytes 1MB
        @($items).Count | Should -Be 1
        $items[0].DisplayName | Should -Match 'big\.bin'
    }
    It '返回项 Category 为 LargeFile，带 LastUsed' {
        $i = @(Get-LargeFiles -Roots @($script:tmp) -MinBytes 1MB)[0]
        $i.Category | Should -Be 'LargeFile'
        $i.LastUsed | Should -BeOfType ([datetime])
    }
    It '按大小降序' {
        $fs = [System.IO.File]::Create((Join-Path $script:tmp 'big2.bin'))
        $fs.SetLength(3MB); $fs.Close()
        $items = Get-LargeFiles -Roots @($script:tmp) -MinBytes 1MB
        $items[0].SizeBytes | Should -BeGreaterOrEqual $items[1].SizeBytes
    }
}
