BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\BackupManager.psm1" -Force
    Import-Module "$PSScriptRoot\..\src\Modules\RestoreManager.psm1" -Force
}
Describe 'Invoke-DesktopRestore' {
    BeforeAll {
        $script:src = Join-Path $env:TEMP ("rsrc_" + [guid]::NewGuid())
        $script:dst = Join-Path $env:TEMP ("rdst_" + [guid]::NewGuid())
        $script:desk = Join-Path $env:TEMP ("rdesk_" + [guid]::NewGuid())
        $script:emptyCommon = Join-Path $env:TEMP ("rcommon_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $script:src, $script:desk, $script:emptyCommon | Out-Null
        Set-Content (Join-Path $script:src 'a.txt') 'AAA' -Encoding UTF8
        $items = @(
            [pscustomobject]@{ Name = 'a.txt'; Type = 'file'; SourcePath = (Join-Path $script:src 'a.txt'); Target = ''; TargetDrive = ''; Status = 'restorable'; SizeBytes = 3; Selected = $true }
        )
        Invoke-DesktopBackup -Items $items -Destination $script:dst
    }
    AfterAll {
        Remove-Item $script:src, $script:dst, $script:desk, $script:emptyCommon -Recurse -Force -ErrorAction SilentlyContinue
    }
    It '把文件还原到目标桌面目录' {
        Invoke-DesktopRestore -Manifest (Join-Path $script:dst 'manifest.json') -DesktopPath $script:desk -CommonDesktopPath $script:emptyCommon
        Test-Path (Join-Path $script:desk 'a.txt') | Should -Be $true
    }
    It '用户桌面已存在同名项时跳过，不重复/不嵌套' {
        $desk2 = Join-Path $env:TEMP ("rdesk2_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $desk2 | Out-Null
        Set-Content (Join-Path $desk2 'a.txt') 'orig' -Encoding UTF8
        $rep = Invoke-DesktopRestore -Manifest (Join-Path $script:dst 'manifest.json') -DesktopPath $desk2 -CommonDesktopPath $script:emptyCommon
        ($rep | Where-Object { $_.Name -eq 'a.txt' }).Restored | Should -Be $false
        (Get-Content (Join-Path $desk2 'a.txt') -Raw).Trim() | Should -Be 'orig'
        Remove-Item $desk2 -Recurse -Force -ErrorAction SilentlyContinue
    }
    It '公共桌面已存在同名项时也跳过(防止复制成重复图标)' {
        $desk3 = Join-Path $env:TEMP ("rdesk3_" + [guid]::NewGuid())
        $common3 = Join-Path $env:TEMP ("rcommon3_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $desk3, $common3 | Out-Null
        Set-Content (Join-Path $common3 'a.txt') 'in-common' -Encoding UTF8
        $rep = Invoke-DesktopRestore -Manifest (Join-Path $script:dst 'manifest.json') -DesktopPath $desk3 -CommonDesktopPath $common3
        ($rep | Where-Object { $_.Name -eq 'a.txt' }).Restored | Should -Be $false
        # 不应把文件拷到用户桌面（否则又重复了）
        Test-Path (Join-Path $desk3 'a.txt') | Should -Be $false
        Remove-Item $desk3, $common3 -Recurse -Force -ErrorAction SilentlyContinue
    }
}
