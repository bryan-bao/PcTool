BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Analyzer.psm1"     -Force   # New-LargeFolderItem 用到 Get-FolderSize
    Import-Module "$PSScriptRoot\..\src\Modules\LargeFolders.psm1" -Force
    $script:tmp = Join-Path $env:TEMP ('dcfolder_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    Set-Content -Path (Join-Path $script:tmp 'big.bin') -Value ('x' * 5000)
}
AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-LargeFolderRoots' {
    It '返回的根目录都真实存在，且带 Label / Risk' {
        foreach ($r in (Get-LargeFolderRoots)) {
            Test-Path -LiteralPath $r.Path | Should -BeTrue
            $r.Label | Should -Not -BeNullOrEmpty
            $r.Risk  | Should -BeIn @('User', 'AppData', 'Program')
        }
    }
    It '不报错' { { Get-LargeFolderRoots } | Should -Not -Throw }
}

Describe 'New-LargeFolderItem' {
    It '体积够大时返回 LargeFolder 项（带整个文件夹总大小、路径、位置）' {
        $it = New-LargeFolderItem -Path $script:tmp -RootLabel '测试位置' -RootRisk 'User' -MinBytes 1000
        $it             | Should -Not -BeNullOrEmpty
        $it.Category    | Should -Be 'LargeFolder'
        $it.SizeBytes   | Should -BeGreaterOrEqual 5000
        $it.Path        | Should -Be $script:tmp
        $it.RootLabel   | Should -Be '测试位置'
        $it.RootRisk    | Should -Be 'User'
        $it.DisplayName | Should -Be (Split-Path $script:tmp -Leaf)
    }
    It '没到阈值时返回 null' {
        New-LargeFolderItem -Path $script:tmp -RootLabel 'x' -RootRisk 'User' -MinBytes 1GB | Should -BeNullOrEmpty
    }
    It '不存在的文件夹返回 null' {
        New-LargeFolderItem -Path 'X:\没有这个_folder_zzz' -RootLabel 'x' -RootRisk 'User' -MinBytes 1 | Should -BeNullOrEmpty
    }
}
