BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\BackupManager.psm1" -Force
}
Describe 'Invoke-DesktopBackup' {
    BeforeAll {
        $script:src = Join-Path $env:TEMP ("bsrc_" + [guid]::NewGuid())
        $script:dst = Join-Path $env:TEMP ("bdst_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $script:src | Out-Null
        Set-Content (Join-Path $script:src 'a.txt') 'AAA' -Encoding UTF8
        $script:items = @(
            [pscustomobject]@{ Name = 'a.txt'; Type = 'file'; SourcePath = (Join-Path $script:src 'a.txt'); Target = ''; TargetDrive = ''; Status = 'restorable'; SizeBytes = 3; Selected = $true }
            [pscustomobject]@{ Name = 'skip'; Type = 'file'; SourcePath = (Join-Path $script:src 'a.txt'); Target = ''; TargetDrive = ''; Status = 'restorable'; SizeBytes = 3; Selected = $false }
        )
    }
    AfterAll {
        Remove-Item $script:src -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:dst -Recurse -Force -ErrorAction SilentlyContinue
    }
    It '生成清单 JSON 文件' {
        Invoke-DesktopBackup -Items $script:items -Destination $script:dst
        Test-Path (Join-Path $script:dst 'manifest.json') | Should -Be $true
    }
    It '只拷贝 Selected=true 的项' {
        Test-Path (Join-Path $script:dst 'files\a.txt') | Should -Be $true
    }
    It '清单里记录了 1 个被选中的项' {
        $m = Get-Content (Join-Path $script:dst 'manifest.json') -Raw | ConvertFrom-Json
        @($m.Items | Where-Object { $_.Selected }).Count | Should -Be 1
    }
}
