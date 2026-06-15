BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\RecycleBin.psm1" -Force
}

Describe 'Get-RecycleBinItem' {
    It '返回单个汇总项，Category 为 RecycleBin' {
        $r = Get-RecycleBinItem
        if ($r) { $r.Category | Should -Be 'RecycleBin' }
    }
    It '不报错' { { Get-RecycleBinItem } | Should -Not -Throw }
}
