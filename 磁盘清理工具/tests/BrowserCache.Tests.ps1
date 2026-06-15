BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Analyzer.psm1" -Force
    Import-Module "$PSScriptRoot\..\src\Modules\BrowserCache.psm1" -Force
}

Describe 'Get-BrowserCacheItems' {
    It '返回项的 Category 都是 BrowserCache' {
        foreach ($i in Get-BrowserCacheItems) { $i.Category | Should -Be 'BrowserCache' }
    }
    It '不报错地返回（可能为空）' {
        { Get-BrowserCacheItems } | Should -Not -Throw
    }
}
