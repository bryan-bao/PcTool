BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Analyzer.psm1" -Force
    Import-Module "$PSScriptRoot\..\src\Modules\TempCleaner.psm1" -Force
}

Describe 'Get-TempItems' {
    It '返回的每一项 Category 都是 Temp' {
        $items = Get-TempItems
        foreach ($i in $items) { $i.Category | Should -Be 'Temp' }
    }
    It '每一项有 Path 和 SizeBytes 字段' {
        $i = Get-TempItems | Select-Object -First 1
        if ($i) {
            $i.PSObject.Properties.Name | Should -Contain 'Path'
            $i.PSObject.Properties.Name | Should -Contain 'SizeBytes'
        }
    }
}
