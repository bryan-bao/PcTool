BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\DesktopScanner.psm1" -Force
}
Describe 'DesktopScanner 模块加载' {
    It '导出了 Get-DesktopItems' {
        Get-Command Get-DesktopItems -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
Describe 'Get-DesktopItems 扫描结果' {
    BeforeAll {
        $script:tmp = Join-Path $env:TEMP ("desk_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $script:tmp | Out-Null
        Set-Content -Path (Join-Path $script:tmp 'note.txt') -Value 'hello' -Encoding UTF8
        $ws = New-Object -ComObject WScript.Shell
        $lnkC = $ws.CreateShortcut((Join-Path $script:tmp 'appC.lnk'))
        $lnkC.TargetPath = 'C:\Program Files\AppC\appC.exe'; $lnkC.Save()
        $lnkD = $ws.CreateShortcut((Join-Path $script:tmp 'appD.lnk'))
        $lnkD.TargetPath = 'D:\Tools\appD\appD.exe'; $lnkD.Save()
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It '识别普通文件为 file 类型' {
        $items = Get-DesktopItems -Path $script:tmp
        ($items | Where-Object { $_.Name -eq 'note.txt' }).Type | Should -Be 'file'
    }
    It '识别 .lnk 为 shortcut 并解析目标盘符' {
        $items = Get-DesktopItems -Path $script:tmp
        ($items | Where-Object { $_.Name -eq 'appD' }).TargetDrive | Should -Be 'D'
    }
    It 'C 盘本体的快捷方式标为 needreinstall' {
        $items = Get-DesktopItems -Path $script:tmp
        ($items | Where-Object { $_.Name -eq 'appC' }).Status | Should -Be 'needreinstall'
    }
    It 'D 盘本体的快捷方式标为 restorable' {
        $items = Get-DesktopItems -Path $script:tmp
        ($items | Where-Object { $_.Name -eq 'appD' }).Status | Should -Be 'restorable'
    }
}
