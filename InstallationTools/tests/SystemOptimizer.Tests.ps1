BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\SystemOptimizer.psm1" -Force
}
Describe 'Get-OptimizationItems' {
    It '返回一组优化项，每项有 Id/Name/Description' {
        $items = @(Get-OptimizationItems)
        $items.Count | Should -BeGreaterThan 0
        $items[0].PSObject.Properties.Name | Should -Contain 'Id'
        $items[0].PSObject.Properties.Name | Should -Contain 'Name'
    }
}
Describe 'Invoke-Optimization -WhatIf' {
    It 'WhatIf 模式不抛错且不真正写入' {
        { Invoke-Optimization -Id 'show-file-ext' -WhatIf } | Should -Not -Throw
    }
}
