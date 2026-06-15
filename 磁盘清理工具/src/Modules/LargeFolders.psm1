# 大文件夹扫描：只盯「常堆东西的地方」（下载、桌面、文档、AppData、ProgramData、
# Program Files）里那些体积大的整个子文件夹，整个文件夹作为一个清理单位。
# 这样能发现「全是小文件堆起来的大目录」，删的时候连里面所有东西一起清掉，不会只删半截。

# 常堆东西的根目录列表，带友好名和风险等级：
#   User    = 你自己放的东西（下载/桌面/文档），相对好删
#   AppData = 程序的数据/缓存，删了可能要重登、重下、丢设置
#   Program = 已安装程序目录，直接删可能删不干净，建议走「卸载」
function Get-LargeFolderRoots {
    $roots = @()
    $defs = @(
        @{ Path = (Join-Path $env:USERPROFILE 'Downloads'); Label = '下载文件夹';                Risk = 'User' }
        @{ Path = (Join-Path $env:USERPROFILE 'Desktop');   Label = '桌面';                      Risk = 'User' }
        @{ Path = (Join-Path $env:USERPROFILE 'Documents'); Label = '文档';                      Risk = 'User' }
        @{ Path = $env:LOCALAPPDATA;                        Label = '程序数据 (AppData\Local)';   Risk = 'AppData' }
        @{ Path = $env:APPDATA;                             Label = '程序数据 (AppData\Roaming)'; Risk = 'AppData' }
        @{ Path = $env:ProgramData;                         Label = '程序共享数据 (ProgramData)'; Risk = 'AppData' }
        @{ Path = $env:ProgramFiles;                        Label = '已安装程序 (Program Files)'; Risk = 'Program' }
        @{ Path = ${env:ProgramFiles(x86)};                Label = '已安装程序 (Program Files x86)'; Risk = 'Program' }
    )
    foreach ($d in $defs) {
        if ($d.Path -and (Test-Path -LiteralPath $d.Path -PathType Container)) {
            $roots += [PSCustomObject]@{ Path = $d.Path; Label = $d.Label; Risk = $d.Risk }
        }
    }
    return $roots
}

# 给单个子文件夹算总大小，够大就返回一个统一形状的清理项，不够大返回 null。
# Path 就是整个文件夹路径，清理时连里面所有东西一起删。
function New-LargeFolderItem {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootLabel,
        [Parameter(Mandatory)][string]$RootRisk,
        [long]$MinBytes = 100MB
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    $size = Get-FolderSize $Path
    if ($size -lt $MinBytes) { return $null }
    $lw = try { [System.IO.Directory]::GetLastWriteTime($Path) } catch { $null }
    $ct = try { [System.IO.Directory]::GetCreationTime($Path) } catch { $null }
    [PSCustomObject]@{
        Path         = $Path
        DisplayName  = [System.IO.Path]::GetFileName($Path)
        Category     = 'LargeFolder'
        SizeBytes    = $size
        LastUsed     = $lw
        CreationTime = $ct
        RootLabel    = $RootLabel
        RootRisk     = $RootRisk
    }
}

Export-ModuleMember -Function Get-LargeFolderRoots, New-LargeFolderItem
