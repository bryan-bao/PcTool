# 项目根：模块在 src\Modules，上两级即项目根。整个项目挪到哪都能算对。
$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Get-IsoFiles {
    <#
      .SYNOPSIS 扫描镜像目录，列出所有 .iso 文件。
      .PARAMETER Path 镜像目录，默认项目下的 images。
    #>
    [CmdletBinding()]
    param([string]$Path = (Join-Path $script:ProjectRoot 'images'))

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    Get-ChildItem -LiteralPath $Path -Filter *.iso -File -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            FullName = $_.FullName
            SizeGB   = [math]::Round($_.Length / 1GB, 2)
        }
    }
}

function Read-IsoEditions {
    <#
      .SYNOPSIS 挂载一个 ISO，读出里面 install.wim/esd 的版本列表，然后卸载。
      .PARAMETER IsoPath ISO 文件完整路径。
      .NOTES 需要真实 ISO；自动化测试只覆盖“文件不存在抛错”，真镜像读取靠集成验证。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IsoPath)

    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "找不到 ISO：$IsoPath" }

    $mounted = $false
    try {
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $mounted = $true
        $letter = ($img | Get-Volume).DriveLetter
        if (-not $letter) { throw '挂载成功但拿不到盘符' }
        $root = "$letter`:"
        $wim = Join-Path $root 'sources\install.wim'
        $esd = Join-Path $root 'sources\install.esd'
        $imagePath = if (Test-Path $wim) { $wim } elseif (Test-Path $esd) { $esd } else { $null }
        if (-not $imagePath) { throw '镜像里找不到 sources\install.wim 或 install.esd' }

        $editions = Get-WindowsImage -ImagePath $imagePath -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Index    = $_.ImageIndex
                Edition  = $_.ImageName
                SizeGB   = [math]::Round($_.ImageSize / 1GB, 2)
                IsoPath  = $IsoPath
                ImageFmt = [System.IO.Path]::GetExtension($imagePath).TrimStart('.')
            }
        }
        return $editions
    }
    finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null }
    }
}

function Get-AllImageEditions {
    <#
      .SYNOPSIS 扫描镜像目录里所有 ISO，逐个读出版本，汇总成一张可供界面选择的清单。
      .PARAMETER Path 镜像目录。
    #>
    [CmdletBinding()]
    param([string]$Path = (Join-Path $script:ProjectRoot 'images'))

    $all = New-Object System.Collections.Generic.List[object]
    foreach ($iso in (Get-IsoFiles -Path $Path)) {
        try {
            foreach ($ed in (Read-IsoEditions -IsoPath $iso.FullName)) {
                $all.Add([pscustomobject]@{
                        IsoName = $iso.Name
                        Index   = $ed.Index
                        Edition = $ed.Edition
                        SizeGB  = $ed.SizeGB
                        IsoPath = $iso.FullName
                    })
            }
        }
        catch {
            $all.Add([pscustomobject]@{
                    IsoName = $iso.Name
                    Index   = $null
                    Edition = "读取失败：$($_.Exception.Message)"
                    SizeGB  = $iso.SizeGB
                    IsoPath = $iso.FullName
                })
        }
    }
    return $all
}

function Invoke-ImageInstall {
    <#
      .SYNOPSIS 挂载所选 ISO 并启动官方 setup.exe 安装（路线A）。带备份守卫 + Execute 守卫。
      .PARAMETER IsoPath 要安装的 ISO。
      .PARAMETER ManifestPath 备份清单，必须已存在才允许装机。
      .PARAMETER Execute 真正执行的开关；不带则只演练，不挂载不启动。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [switch]$Execute
    )
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw '未检测到备份清单，已阻止装机。请先完成“备份桌面”。'
    }
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "找不到 ISO：$IsoPath" }
    if (-not $Execute) {
        Write-Host "[演练] 将挂载 $IsoPath 并启动 setup.exe。加 -Execute 才会真正开始装机。" -ForegroundColor Yellow
        return $false
    }
    $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    $letter = ($img | Get-Volume).DriveLetter
    $setup = "$letter`:\setup.exe"
    if (-not (Test-Path -LiteralPath $setup)) {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
        throw '镜像里找不到 setup.exe'
    }
    Write-Host "正在启动安装程序：$setup" -ForegroundColor Cyan
    Start-Process -FilePath $setup -ErrorAction Stop
    return $true
}

function Get-WindowsMajorFromName {
    <# .SYNOPSIS 从版本名(如"Windows 10 专业版")识别主版本号，返回 10 / 11 / 0。 #>
    [CmdletBinding()] param([string]$Name)
    if ($Name -match 'Windows\s*11') { return 11 }
    if ($Name -match 'Windows\s*10') { return 10 }
    return 0
}

function Get-CurrentWindowsMajor {
    <# .SYNOPSIS 判断当前系统是 Win10 还是 Win11（按 Build 号，>=22000 即 Win11）。 #>
    [CmdletBinding()] param()
    $build = 0
    try { $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber } catch { }
    if ($build -ge 22000) { return 11 } else { return 10 }
}

function Get-WindowsEditionName {
    <# .SYNOPSIS 把注册表 EditionID 翻成中文版次名(认不出就原样返回)。 #>
    [CmdletBinding()] param([string]$EditionId)
    switch -Regex ($EditionId) {
        '^(Core|CoreN|CoreSingleLanguage|CoreCountrySpecific)$' { return '家庭版' }
        '^Professional' { return '专业版' }
        '^Enterprise' { return '企业版' }
        '^Education' { return '教育版' }
        default { return $EditionId }
    }
}

function Get-CurrentWindowsName {
    <# .SYNOPSIS 当前系统的友好名，如"Windows 11 专业版"。读不到版次就只给主版本。 #>
    [CmdletBinding()] param()
    $major = Get-CurrentWindowsMajor
    $edId = ''
    try { $edId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID } catch { }
    $ed = if ($edId) { Get-WindowsEditionName $edId } else { '' }
    return ("Windows $major $ed").Trim()
}

function Test-IsDowngrade {
    <# .SYNOPSIS 目标版本是否比当前系统低（即降级，系统内装不了，需 U 盘）。 #>
    [CmdletBinding()] param([Parameter(Mandatory)][int]$TargetMajor, [int]$CurrentMajor = (Get-CurrentWindowsMajor))
    return ($TargetMajor -gt 0 -and $TargetMajor -lt $CurrentMajor)
}

function Get-WindowsCatalog {
    <# .SYNOPSIS 返回可供选择的微软系统版本目录：Win11/Win10 × 家庭版/专业版。 #>
    [CmdletBinding()] param()
    return @(
        [pscustomobject]@{ Title = 'Windows 11 家庭版（最新）'; Major = 11; Edition = 'Home' }
        [pscustomobject]@{ Title = 'Windows 11 专业版（最新）'; Major = 11; Edition = 'Pro' }
        [pscustomobject]@{ Title = 'Windows 10 家庭版（最新）'; Major = 10; Edition = 'Home' }
        [pscustomobject]@{ Title = 'Windows 10 专业版（最新）'; Major = 10; Edition = 'Pro' }
    )
}

function Find-LocalIso {
    <# .SYNOPSIS 在镜像目录里找文件名匹配该主版本的 ISO，返回完整路径或 $null。 #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Major, [string]$Path = (Join-Path $script:ProjectRoot 'images'))
    foreach ($iso in (Get-IsoFiles -Path $Path)) {
        if ($iso.Name -match "win(dows)?[\s_]*$Major") { return $iso.FullName }
    }
    return $null
}

function Get-ReinstallRoute {
    <#
      .SYNOPSIS 按"目标版本 vs 当前系统"判断装机路线。
      .OUTPUTS 'upgrade-exe' | 'upgrade-iso' | 'reinstall-iso' | 'downgrade-usb'
      .NOTES 升级=目标主版本更高；家庭版走官方易升 exe(原地升级)、专业版走本地 ISO；
             同版本=ISO 重装；降级=易升装不了，走官方制盘 U 盘。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$TargetMajor,
        [Parameter(Mandatory)][ValidateSet('Home', 'Pro')][string]$TargetEdition,
        [int]$CurrentMajor = (Get-CurrentWindowsMajor)
    )
    if ($TargetMajor -gt $CurrentMajor) {
        if ($TargetEdition -eq 'Home') { return 'upgrade-exe' } else { return 'upgrade-iso' }
    }
    elseif ($TargetMajor -eq $CurrentMajor) { return 'reinstall-iso' }
    else { return 'downgrade-usb' }
}

function Get-OfficialToolUrl {
    <#
      .SYNOPSIS 返回微软官方工具的下载直链(fwlink)。链接已于 2026-06-05 联网核实。
      .PARAMETER Kind Win11Assistant=Win11易升; Win11MCT=Win11制盘工具; Win10MCT=Win10制盘工具22H2
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        'Win11Assistant' { return 'https://go.microsoft.com/fwlink/?linkid=2171764' }
        'Win11MCT' { return 'https://go.microsoft.com/fwlink/?linkid=2156295' }
        'Win10MCT' { return 'https://go.microsoft.com/fwlink/?LinkId=2265055' }
        default { throw "未知的官方工具 Kind：$Kind（可选 Win11Assistant / Win11MCT / Win10MCT）" }
    }
}

function Get-OfficialToolFileName {
    <# .SYNOPSIS 各官方工具的默认保存文件名。 #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        'Win11Assistant' { return 'Windows11InstallationAssistant.exe' }
        'Win11MCT' { return 'MediaCreationTool_Win11.exe' }
        'Win10MCT' { return 'MediaCreationTool_22H2.exe' }
        default { throw "未知的官方工具 Kind：$Kind（可选 Win11Assistant / Win11MCT / Win10MCT）" }
    }
}

function Save-OfficialTool {
    <#
      .SYNOPSIS 稳妥地把官方工具下载到本地：先找本地、缺了才下；TLS1.2 + 跟随跳转 + 重试 + 校验。
      .PARAMETER Kind   工具种类，见 Get-OfficialToolUrl。
      .PARAMETER OutDir 保存目录(不存在自动创建)，默认 tools 目录。
      .PARAMETER FileName 覆盖默认文件名(可选)。
      .PARAMETER Force  强制重新下载，忽略本地已有。
      .OUTPUTS 下载好的文件完整路径。
      .NOTES 真实下载需联网；自动化测试用 mock 覆盖，真链路靠手动验证。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [string]$OutDir = (Join-Path $script:ProjectRoot 'tools'),
        [string]$FileName,
        [switch]$Force,
        [int]$Retry = 3
    )
    $url = Get-OfficialToolUrl -Kind $Kind   # 未知 Kind 会在这里抛错
    if (-not $FileName) { $FileName = Get-OfficialToolFileName -Kind $Kind }

    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    }
    $dest = Join-Path $OutDir $FileName

    # 先找本地：已存在且非空且未强制 → 直接复用
    if (-not $Force -and (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) {
        return $dest
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    $lastErr = $null
    for ($i = 1; $i -le $Retry; $i++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -UserAgent $ua -MaximumRedirection 5 -ErrorAction Stop
            if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) {
                return $dest
            }
            $lastErr = "下载得到空文件"
        }
        catch {
            $lastErr = $_.Exception.Message
        }
        Start-Sleep -Seconds ($i * 2)
    }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
    throw "下载失败（已重试 $Retry 次）：$lastErr`n可手动打开官网下载：$url"
}

Export-ModuleMember -Function Get-IsoFiles, Read-IsoEditions, Get-AllImageEditions, Invoke-ImageInstall, Get-WindowsMajorFromName, Get-CurrentWindowsMajor, Test-IsDowngrade, Get-WindowsCatalog, Find-LocalIso, Get-ReinstallRoute, Get-OfficialToolUrl, Get-OfficialToolFileName, Save-OfficialTool, Get-WindowsEditionName, Get-CurrentWindowsName
