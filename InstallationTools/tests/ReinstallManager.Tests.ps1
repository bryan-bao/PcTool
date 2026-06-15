BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\ReinstallManager.psm1" -Force
}
Describe 'Test-BackupReady' {
    It '清单不存在时返回 false' {
        Test-BackupReady -ManifestPath (Join-Path $env:TEMP 'no_such_manifest.json') | Should -Be $false
    }
    It '清单存在时返回 true' {
        $p = Join-Path $env:TEMP ("mok_" + [guid]::NewGuid() + '.json')
        '{}' | Set-Content $p -Encoding UTF8
        Test-BackupReady -ManifestPath $p | Should -Be $true
        Remove-Item $p -Force
    }
}
Describe 'Invoke-SystemReset 守卫' {
    It '没备份时拒绝执行并抛错' {
        { Invoke-SystemReset -ManifestPath (Join-Path $env:TEMP 'no_such.json') -Execute } |
            Should -Throw -ExpectedMessage '*未检测到备份*'
    }
    It '不带 -Execute 时为演练，不抛错也不重装' {
        $p = Join-Path $env:TEMP ("mok2_" + [guid]::NewGuid() + '.json')
        '{}' | Set-Content $p -Encoding UTF8
        { Invoke-SystemReset -ManifestPath $p } | Should -Not -Throw
        Remove-Item $p -Force
    }
}
