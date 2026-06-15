BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\ImageManager.psm1" -Force
}
Describe 'Get-WindowsCatalog' {
    It '返回 4 个版本(Win11/Win10 × 家庭/专业)，含 Title/Major/Edition' {
        $cat = @(Get-WindowsCatalog)
        $cat.Count | Should -Be 4
        $cat[0].PSObject.Properties.Name | Should -Contain 'Major'
        $cat[0].PSObject.Properties.Name | Should -Contain 'Edition'
    }
    It 'Major 只含 10/11，Edition 只含 Home/Pro' {
        $cat = @(Get-WindowsCatalog)
        ($cat.Major | Sort-Object -Unique) | Should -Be @(10, 11)
        ($cat.Edition | Sort-Object -Unique) | Should -Be @('Home', 'Pro')
    }
}
Describe 'Get-WindowsEditionName' {
    It '专业版 EditionID 映射为 专业版' { Get-WindowsEditionName 'Professional' | Should -Be '专业版' }
    It '家庭版 EditionID(Core) 映射为 家庭版' { Get-WindowsEditionName 'Core' | Should -Be '家庭版' }
    It '单语言家庭版 也映射为 家庭版' { Get-WindowsEditionName 'CoreSingleLanguage' | Should -Be '家庭版' }
    It '企业版 映射为 企业版' { Get-WindowsEditionName 'Enterprise' | Should -Be '企业版' }
    It '认不出的原样返回' { Get-WindowsEditionName 'SomethingNew' | Should -Be 'SomethingNew' }
}
Describe 'Get-ReinstallRoute' {
    It '升级+家庭版 → upgrade-exe' { Get-ReinstallRoute -TargetMajor 11 -TargetEdition 'Home' -CurrentMajor 10 | Should -Be 'upgrade-exe' }
    It '升级+专业版 → upgrade-iso' { Get-ReinstallRoute -TargetMajor 11 -TargetEdition 'Pro' -CurrentMajor 10 | Should -Be 'upgrade-iso' }
    It '同版本+家庭版 → reinstall-iso' { Get-ReinstallRoute -TargetMajor 11 -TargetEdition 'Home' -CurrentMajor 11 | Should -Be 'reinstall-iso' }
    It '同版本+专业版 → reinstall-iso' { Get-ReinstallRoute -TargetMajor 10 -TargetEdition 'Pro' -CurrentMajor 10 | Should -Be 'reinstall-iso' }
    It '降级+家庭版 → downgrade-usb' { Get-ReinstallRoute -TargetMajor 10 -TargetEdition 'Home' -CurrentMajor 11 | Should -Be 'downgrade-usb' }
    It '降级+专业版 → downgrade-usb' { Get-ReinstallRoute -TargetMajor 10 -TargetEdition 'Pro' -CurrentMajor 11 | Should -Be 'downgrade-usb' }
}
Describe 'Get-OfficialToolUrl' {
    It '三个 Kind 都返回官方 fwlink' {
        Get-OfficialToolUrl -Kind 'Win11Assistant' | Should -Match 'go\.microsoft\.com/fwlink.*2171764'
        Get-OfficialToolUrl -Kind 'Win11MCT'       | Should -Match 'go\.microsoft\.com/fwlink.*2156295'
        Get-OfficialToolUrl -Kind 'Win10MCT'       | Should -Match 'go\.microsoft\.com/fwlink.*2265055'
    }
    It '未知 Kind 抛错' {
        { Get-OfficialToolUrl -Kind 'Nope' } | Should -Throw -ExpectedMessage '*未知*'
    }
}
Describe 'Get-OfficialToolFileName' {
    It '三个 Kind 各有默认文件名' {
        Get-OfficialToolFileName -Kind 'Win11Assistant' | Should -Be 'Windows11InstallationAssistant.exe'
        Get-OfficialToolFileName -Kind 'Win11MCT'       | Should -Be 'MediaCreationTool_Win11.exe'
        Get-OfficialToolFileName -Kind 'Win10MCT'       | Should -Be 'MediaCreationTool_22H2.exe'
    }
    It '未知 Kind 抛错' {
        { Get-OfficialToolFileName -Kind 'Nope' } | Should -Throw -ExpectedMessage '*未知*'
    }
}
Describe 'Save-OfficialTool' {
    It '本地已有非空文件时直接返回不下载' {
        $dir = Join-Path $env:TEMP ("tool_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $dir | Out-Null
        $f = Join-Path $dir 'Windows11InstallationAssistant.exe'
        Set-Content $f 'fakecontent' -Encoding UTF8
        $r = Save-OfficialTool -Kind 'Win11Assistant' -OutDir $dir
        $r | Should -Be $f
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It '未知 Kind 抛错' {
        { Save-OfficialTool -Kind 'Nope' -OutDir $env:TEMP } | Should -Throw -ExpectedMessage '*未知*'
    }
    It 'OutDir 不存在时自动创建，并把下载结果落到位（mock 下载）' {
        $dir = Join-Path $env:TEMP ("toolnew_" + [guid]::NewGuid())
        try {
            Mock -ModuleName ImageManager Invoke-WebRequest {
                param($Uri, $OutFile)
                Set-Content -Path $OutFile -Value 'downloaded' -Encoding UTF8
            }
            $r = Save-OfficialTool -Kind 'Win10MCT' -OutDir $dir
            Test-Path $dir | Should -Be $true
            $r | Should -Be (Join-Path $dir 'MediaCreationTool_22H2.exe')
            (Get-Item $r).Length | Should -BeGreaterThan 0
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It '下载后文件为空(0字节)视为失败并抛错（mock 下载）' {
        $dir = Join-Path $env:TEMP ("toolempty_" + [guid]::NewGuid())
        try {
            Mock -ModuleName ImageManager Invoke-WebRequest {
                param($Uri, $OutFile)
                New-Item -ItemType File -Path $OutFile -Force | Out-Null  # 真正的 0 字节文件
            }
            { Save-OfficialTool -Kind 'Win10MCT' -OutDir $dir -Retry 1 } | Should -Throw -ExpectedMessage '*下载*'
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Describe 'Find-LocalIso' {
    BeforeAll {
        $script:imgdir = Join-Path $env:TEMP ("img_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $script:imgdir | Out-Null
        Set-Content (Join-Path $script:imgdir 'Win11_24H2_zh-CN_Pro.iso') 'x' -Encoding UTF8
    }
    AfterAll { Remove-Item $script:imgdir -Recurse -Force -ErrorAction SilentlyContinue }
    It '本地有 Win11 时能找到' {
        Find-LocalIso -Major 11 -Path $script:imgdir | Should -Not -BeNullOrEmpty
    }
    It '本地没有 Win10 时返回空' {
        Find-LocalIso -Major 10 -Path $script:imgdir | Should -BeNullOrEmpty
    }
}
Describe 'Get-IsoFiles' {
    BeforeAll {
        $script:dir = Join-Path $env:TEMP ("iso_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force $script:dir | Out-Null
        Set-Content (Join-Path $script:dir 'Win11.iso') 'x' -Encoding UTF8
        Set-Content (Join-Path $script:dir 'Win10.iso') 'x' -Encoding UTF8
        Set-Content (Join-Path $script:dir 'readme.txt') 'x' -Encoding UTF8
    }
    AfterAll { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It '只列出 .iso 文件（忽略其它）' {
        @(Get-IsoFiles -Path $script:dir).Count | Should -Be 2
    }
    It '每个项带 Name/FullName/SizeGB' {
        $one = @(Get-IsoFiles -Path $script:dir)[0]
        $one.PSObject.Properties.Name | Should -Contain 'Name'
        $one.PSObject.Properties.Name | Should -Contain 'SizeGB'
    }
    It '目录不存在时返回空' {
        @(Get-IsoFiles -Path (Join-Path $env:TEMP 'no_such_dir_xyz')).Count | Should -Be 0
    }
}
Describe 'Read-IsoEditions' {
    It 'ISO 文件不存在时抛错' {
        { Read-IsoEditions -IsoPath (Join-Path $env:TEMP 'no_such.iso') } | Should -Throw -ExpectedMessage '*找不到 ISO*'
    }
}
Describe '版本高低判断' {
    It '从"Windows 10 专业版"识别为 10' { Get-WindowsMajorFromName 'Windows 10 专业版' | Should -Be 10 }
    It '从"Windows 11 专业版"识别为 11' { Get-WindowsMajorFromName 'Windows 11 专业版' | Should -Be 11 }
    It '认不出的返回 0' { Get-WindowsMajorFromName 'Ubuntu' | Should -Be 0 }
    It '当前系统返回 10 或 11' { Get-CurrentWindowsMajor | Should -BeIn @(10, 11) }
    It 'Win11 上装 Win10 判为降级' { Test-IsDowngrade -TargetMajor 10 -CurrentMajor 11 | Should -Be $true }
    It 'Win10 上装 Win11 不是降级' { Test-IsDowngrade -TargetMajor 11 -CurrentMajor 10 | Should -Be $false }
    It '同版本不是降级' { Test-IsDowngrade -TargetMajor 11 -CurrentMajor 11 | Should -Be $false }
}
Describe 'Invoke-ImageInstall 守卫' {
    It '没备份时拒绝并抛错' {
        { Invoke-ImageInstall -IsoPath (Join-Path $env:TEMP 'x.iso') -ManifestPath (Join-Path $env:TEMP 'no.json') -Execute } |
            Should -Throw -ExpectedMessage '*未检测到备份*'
    }
    It 'ISO 不存在时抛错' {
        $p = Join-Path $env:TEMP ("m_" + [guid]::NewGuid() + '.json'); '{}' | Set-Content $p
        { Invoke-ImageInstall -IsoPath (Join-Path $env:TEMP 'nope.iso') -ManifestPath $p -Execute } |
            Should -Throw -ExpectedMessage '*找不到 ISO*'
        Remove-Item $p -Force
    }
    It '不带 Execute 为演练，不抛错' {
        $p = Join-Path $env:TEMP ("m2_" + [guid]::NewGuid() + '.json'); '{}' | Set-Content $p
        $iso = Join-Path $env:TEMP ("i_" + [guid]::NewGuid() + '.iso'); 'x' | Set-Content $iso
        { Invoke-ImageInstall -IsoPath $iso -ManifestPath $p } | Should -Not -Throw
        Remove-Item $p, $iso -Force
    }
}
