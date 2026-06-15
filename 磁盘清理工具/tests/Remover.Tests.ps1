BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Remover.psm1" -Force
    $script:tmp = Join-Path $env:TEMP ('dcrm_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
}
AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Remove-ToRecycleBin' {
    It '能删掉一个文件并返回成功' {
        $f = Join-Path $script:tmp 'del1.txt'
        Set-Content -Path $f -Value 'bye'
        $r = Remove-ToRecycleBin $f
        $r.Success | Should -BeTrue
        Test-Path $f | Should -BeFalse
    }
    It '删不存在的文件返回失败但不抛异常' {
        $r = Remove-ToRecycleBin (Join-Path $script:tmp '不存在.txt')
        $r.Success | Should -BeFalse
    }
    It '带 -Force 删普通文件也成功' {
        $f = Join-Path $script:tmp 'force1.txt'
        Set-Content -Path $f -Value 'x'
        $r = Remove-ToRecycleBin $f -Force
        $r.Success | Should -BeTrue
        Test-Path $f | Should -BeFalse
    }
}

Describe 'Stop-OccupyingBrowser' {
    It '函数已导出（不在测试里真执行，以免误关浏览器）' {
        Get-Command Stop-OccupyingBrowser -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
