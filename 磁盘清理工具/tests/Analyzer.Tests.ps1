BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Analyzer.psm1" -Force
}

Describe 'Format-Size' {
    It '0 字节显示 0 B' { Format-Size 0 | Should -Be '0 B' }
    It '小于 1KB 显示字节' { Format-Size 512 | Should -Be '512 B' }
    It '1024 字节显示 1.0 KB' { Format-Size 1024 | Should -Be '1.0 KB' }
    It '兆字节正确' { Format-Size (5 * 1MB) | Should -Be '5.0 MB' }
    It '吉字节保留一位小数' { Format-Size ([long](1.2 * 1GB)) | Should -Be '1.2 GB' }
}

Describe 'Get-IdleDescription' {
    BeforeAll { $script:now = [datetime]'2026-06-05' }
    It '7 天内算最近还用过' {
        Get-IdleDescription ([datetime]'2026-06-01') $script:now | Should -Be '最近还用过'
    }
    It '不到一个月按天显示' {
        Get-IdleDescription ([datetime]'2026-05-20') $script:now | Should -Be '16天没动过'
    }
    It '超过一个月按月显示' {
        Get-IdleDescription ([datetime]'2025-10-05') $script:now | Should -Be '8个月没动过'
    }
    It 'LastUsed 为 null 返回空串' {
        Get-IdleDescription $null $script:now | Should -Be ''
    }
}

Describe 'Set-SafetyMark' {
    BeforeAll { $script:now = [datetime]'2026-06-05' }
    It '系统临时文件标绿、默认勾选' {
        $item = [PSCustomObject]@{ Category='Temp'; LastUsed=$null }
        $r = Set-SafetyMark $item $script:now
        $r.Safety | Should -Be 'Green'
        $r.Reason | Should -Be '系统垃圾'
        $r.DefaultChecked | Should -BeTrue
    }
    It '浏览器缓存标绿' {
        $item = [PSCustomObject]@{ Category='BrowserCache'; LastUsed=$null }
        (Set-SafetyMark $item $script:now).Safety | Should -Be 'Green'
    }
    It '回收站标绿' {
        $item = [PSCustomObject]@{ Category='RecycleBin'; LastUsed=$null }
        (Set-SafetyMark $item $script:now).Safety | Should -Be 'Green'
    }
    It '大文件最近用过标红、不默认勾选' {
        $item = [PSCustomObject]@{ Category='LargeFile'; LastUsed=[datetime]'2026-06-02' }
        $r = Set-SafetyMark $item $script:now
        $r.Safety | Should -Be 'Red'
        $r.Reason | Should -Be '最近还用过'
        $r.DefaultChecked | Should -BeFalse
    }
    It '大文件很久没用标黄' {
        $item = [PSCustomObject]@{ Category='LargeFile'; LastUsed=[datetime]'2025-10-05' }
        $r = Set-SafetyMark $item $script:now
        $r.Safety | Should -Be 'Yellow'
        $r.Reason | Should -Be '8个月没动过'
        $r.DefaultChecked | Should -BeFalse
    }
    It '大文件夹·Program Files 标红、不默认勾选' {
        $item = [PSCustomObject]@{ Category='LargeFolder'; RootRisk='Program'; LastUsed=$null }
        $r = Set-SafetyMark $item $script:now
        $r.Safety | Should -Be 'Red'
        $r.DefaultChecked | Should -BeFalse
    }
    It '大文件夹·AppData 标黄' {
        $item = [PSCustomObject]@{ Category='LargeFolder'; RootRisk='AppData'; LastUsed=$null }
        (Set-SafetyMark $item $script:now).Safety | Should -Be 'Yellow'
    }
    It '大文件夹·用户目录标黄、reason 用闲置描述' {
        $item = [PSCustomObject]@{ Category='LargeFolder'; RootRisk='User'; LastUsed=[datetime]'2025-10-05' }
        $r = Set-SafetyMark $item $script:now
        $r.Safety | Should -Be 'Yellow'
        $r.Reason | Should -Be '8个月没动过'
    }
}

Describe 'Get-FolderSize' {
    BeforeAll {
        $script:tmp = Join-Path $env:TEMP ('dctest_' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
        Set-Content -Path (Join-Path $script:tmp 'a.txt') -Value ('x' * 1000)
        Set-Content -Path (Join-Path $script:tmp 'b.txt') -Value ('y' * 2000)
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It '统计文件夹内所有文件字节之和' {
        Get-FolderSize $script:tmp | Should -BeGreaterOrEqual 3000
    }
    It '不存在的路径返回 0' {
        Get-FolderSize 'X:\不存在的路径_abc' | Should -Be 0
    }
}

Describe 'Get-FileKind' {
    It '按扩展名认出视频' { Get-FileKind 'C:\a\b.mp4' | Should -Be '视频文件' }
    It '认出压缩包'       { Get-FileKind 'C:\a\b.zip' | Should -Be '压缩包' }
    It '认出安装程序'     { Get-FileKind 'C:\a\setup.exe' | Should -Be '安装程序 / 可执行文件' }
    It '没扩展名兜底为文件' { Get-FileKind 'C:\a\noext' | Should -Be '文件' }
    It '不认识的扩展名按「xxx 文件」显示' { Get-FileKind 'C:\a\b.xyz' | Should -Be 'xyz 文件' }
}

Describe 'Get-FilePurpose' {
    It '下载文件夹的识别成下载来的' {
        Get-FilePurpose -Path 'C:\Users\me\Downloads\setup.exe' -Kind '安装程序' | Should -Match '下载'
    }
    It '桌面的识别成桌面' {
        Get-FilePurpose -Path 'C:\Users\me\Desktop\a.mp4' -Kind '视频文件' | Should -Match '桌面'
    }
    It 'AppData 里能猜出是哪个程序的数据' {
        $r = Get-FilePurpose -Path 'C:\Users\me\AppData\Local\WeChat\cache\x.dat' -Kind '文件'
        $r | Should -Match 'WeChat'
        $r | Should -Match 'AppData'
    }
    It 'Program Files 里能猜出是哪个程序' {
        Get-FilePurpose -Path 'C:\Program Files\Adobe\big.bin' -Kind '文件' | Should -Match 'Adobe'
    }
    It '认不出位置时只回退到类型本身' {
        Get-FilePurpose -Path 'D:\随便\一个\地方\b.bin' -Kind '压缩包' | Should -Be '压缩包'
    }
}

Describe 'Get-FileTip' {
    BeforeAll { $script:now = [datetime]'2026-06-05' }
    It '把类型/用途/路径/大小/时间都拼进去' {
        $item = [PSCustomObject]@{
            Path           = 'C:\Users\me\Downloads\movie.mp4'
            SizeBytes      = [long](700 * 1MB)
            LastUsed       = [datetime]'2025-10-05'
            CreationTime   = [datetime]'2025-10-01'
            LastAccessTime = [datetime]'2025-10-06'
            InUse          = $false
        }
        $tip = Get-FileTip $item $script:now
        $tip | Should -Match '视频文件'
        $tip | Should -Match '下载'
        $tip | Should -Match 'movie.mp4'
        $tip | Should -Match '700.0 MB'
        $tip | Should -Match '2025-10-01'   # 创建
        $tip | Should -Match '8个月没动过'   # 修改 + 闲置描述
        $tip | Should -Match '没被占用'
    }
    It '被占用时给出占用提示' {
        $item = [PSCustomObject]@{
            Path = 'C:\Users\me\Downloads\a.iso'; SizeBytes = [long]1GB
            LastUsed = $script:now; CreationTime = $script:now; LastAccessTime = $script:now; InUse = $true
        }
        Get-FileTip $item $script:now | Should -Match '正被某个程序'
    }
    It '占用状态未知时不显示占用那行' {
        $item = [PSCustomObject]@{
            Path = 'C:\Users\me\Downloads\a.iso'; SizeBytes = [long]1GB
            LastUsed = $script:now; CreationTime = $script:now; LastAccessTime = $script:now; InUse = $null
        }
        Get-FileTip $item $script:now | Should -Not -Match '占用'
    }
}
