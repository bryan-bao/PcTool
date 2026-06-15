function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    elseif ($Bytes -lt 1MB) { return ('{0:0.0} KB' -f ($Bytes / 1KB)) }
    elseif ($Bytes -lt 1GB) { return ('{0:0.0} MB' -f ($Bytes / 1MB)) }
    else { return ('{0:0.0} GB' -f ($Bytes / 1GB)) }
}

function Get-IdleDescription {
    param(
        [Nullable[datetime]]$LastUsed,
        [datetime]$Now
    )
    if ($null -eq $LastUsed) { return '' }
    $days = [int][math]::Floor(($Now - $LastUsed).TotalDays)
    if ($days -lt 7) { return '最近还用过' }
    elseif ($days -lt 30) { return "${days}天没动过" }
    else {
        $months = [int][math]::Floor($days / 30)
        return "${months}个月没动过"
    }
}

function Set-SafetyMark {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [datetime]$Now
    )
    switch ($Item.Category) {
        'Temp'         { $safety='Green'; $reason='系统垃圾';   $checked=$true }
        'RecycleBin'   { $safety='Green'; $reason='回收站';     $checked=$true }
        'BrowserCache' { $safety='Green'; $reason='浏览器缓存'; $checked=$true }
        'WinUpdate'    { $safety='Green'; $reason='更新缓存';   $checked=$true }
        'CrashDump'    { $safety='Green'; $reason='崩溃转储';   $checked=$true }
        'Thumbnails'   { $safety='Green'; $reason='缩略图缓存'; $checked=$true }
        'SysLog'       { $safety='Green'; $reason='系统日志';   $checked=$true }
        'WindowsOld'   { $safety='Yellow'; $reason='旧系统·删了不能回退'; $checked=$false }
        'LargeFile'    {
            $checked = $false
            $days = if ($null -ne $Item.LastUsed) { ($Now - $Item.LastUsed).TotalDays } else { 9999 }
            if ($days -lt 7) { $safety='Red' } else { $safety='Yellow' }
            $reason = Get-IdleDescription $Item.LastUsed $Now
        }
        'LargeFolder'  {
            # 整个文件夹删除较重，一律默认不勾，按所在位置给风险等级
            $checked = $false
            switch ($Item.RootRisk) {
                'Program' { $safety='Red';    $reason='已安装程序·建议走卸载' }
                'AppData' { $safety='Yellow'; $reason='程序数据·删了可能要重下/重登' }
                default   { $safety='Yellow'; $reason=(Get-IdleDescription $Item.LastUsed $Now) }
            }
        }
        default        { $safety='Yellow'; $reason=''; $checked=$false }
    }
    $Item | Add-Member -NotePropertyName Safety -NotePropertyValue $safety -Force
    $Item | Add-Member -NotePropertyName Reason -NotePropertyValue $reason -Force
    $Item | Add-Member -NotePropertyName DefaultChecked -NotePropertyValue $checked -Force
    return $Item
}

function Get-FolderSize {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

# 按扩展名猜文件大类，给大文件的悬停说明用
function Get-FileKind {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension([string]$Path).ToLower()
    switch -Regex ($ext) {
        '^\.(mp4|mkv|avi|mov|wmv|flv|m4v)$'    { '视频文件'; break }
        '^\.(mp3|wav|flac|aac|wma)$'           { '音频文件'; break }
        '^\.(jpg|jpeg|png|gif|bmp|tiff|webp)$' { '图片文件'; break }
        '^\.(zip|rar|7z|tar|gz|cab)$'          { '压缩包'; break }
        '^\.(iso|img)$'                        { '光盘镜像'; break }
        '^\.(exe|msi)$'                        { '安装程序 / 可执行文件'; break }
        '^\.(vhd|vhdx|vmdk)$'                  { '虚拟磁盘文件'; break }
        '^\.(bak|old)$'                        { '备份文件'; break }
        '^\.log$'                              { '日志文件'; break }
        '^\.(tmp|temp)$'                       { '临时文件'; break }
        '^\.pdf$'                              { 'PDF 文档'; break }
        '^\.(doc|docx)$'                       { 'Word 文档'; break }
        '^\.(xls|xlsx)$'                       { 'Excel 表格'; break }
        '^\.(ppt|pptx)$'                       { 'PPT 演示'; break }
        '^\.psd$'                              { 'Photoshop 文件'; break }
        '^\.(dll|sys)$'                        { '系统 / 程序组件（一般别动）'; break }
        default { if ($ext) { "$($ext.TrimStart('.')) 文件" } else { '文件' } }
    }
}

# 私有：在路径分段里，找到某个标记段后面紧跟的那一段（比如 AppData\Local\【微信】）
function Get-PathSegmentAfter {
    param([string[]]$Segments, [string[]]$Markers)
    for ($i = 0; $i -lt $Segments.Count - 1; $i++) {
        foreach ($m in $Markers) { if ($Segments[$i] -ieq $m) { return $Segments[$i + 1] } }
    }
    return $null
}

# 按文件所在位置 + 类型，猜它大概是干嘛用的、能不能删，给悬停说明用
function Get-FilePurpose {
    param([Parameter(Mandatory)][string]$Path, [string]$Kind = '文件')
    $segs = @(($Path -split '[\\/]') | Where-Object { $_ -ne '' })
    $low  = $Path.ToLower()

    if ($low -match '\\downloads\\')            { return "放在「下载」文件夹里，多半是你从网上下载的$Kind，用完一般可以删" }
    if ($low -match '\\desktop\\')              { return "桌面上的$Kind" }
    if ($low -match '\\documents\\|\\我的文档\\') { return "「文档」里的$Kind" }
    if ($low -match '\\pictures\\')             { return "「图片」库里的$Kind" }
    if ($low -match '\\videos\\')               { return "「视频」库里的$Kind" }
    if ($low -match '\\music\\')                { return "「音乐」库里的$Kind" }
    if ($low -match '\\onedrive')               { return "OneDrive 同步文件夹里的$Kind，删了云端那份也可能跟着删，注意" }
    if ($low -match '\\\$recycle\.bin\\')       { return "回收站里的$Kind" }
    if ($low -match '\\node_modules\\')         { return "某个开发项目的依赖包（node_modules），重新安装就能恢复" }
    if ($low -match '\\appdata\\') {
        $soft = Get-PathSegmentAfter $segs @('Local', 'Roaming', 'LocalLow')
        if ($soft) { return "「$soft」这个程序存在 AppData 里的数据/缓存，删了它可能要重新登录、重下数据或丢设置" }
        return "某个程序存在 AppData 里的数据/缓存，删了对应程序可能要重新下数据或丢设置"
    }
    if ($low -match '\\programdata\\') {
        $soft = Get-PathSegmentAfter $segs @('ProgramData')
        if ($soft) { return "「$soft」程序的共享数据（ProgramData），删了该程序可能出问题" }
        return "某程序的共享数据（ProgramData），删了对应程序可能出问题"
    }
    if ($low -match '\\program files( \(x86\))?\\') {
        $soft = Get-PathSegmentAfter $segs @('Program Files', 'Program Files (x86)')
        if ($soft) { return "已安装程序「$soft」的文件，删了这个程序可能用不了" }
        return "已安装程序的文件，删了对应程序可能用不了"
    }
    if ($low -match '\\windows\\')              { return "Windows 系统目录里的$Kind，可能是系统文件，删之前务必确认" }
    return $Kind
}

# 拼出大文件那行的详细悬停说明：类型、用途、路径、大小、三个时间、占用状态、提醒
function Get-FileTip {
    param([Parameter(Mandatory)]$Item, [datetime]$Now = [datetime]::Now)
    $kind    = Get-FileKind $Item.Path
    $purpose = Get-FilePurpose -Path $Item.Path -Kind $kind
    $created = if ($Item.CreationTime)   { ([datetime]$Item.CreationTime).ToString('yyyy-MM-dd') }   else { '—' }
    $opened  = if ($Item.LastAccessTime) { ([datetime]$Item.LastAccessTime).ToString('yyyy-MM-dd') } else { '—' }
    $modified= if ($Item.LastUsed)       { ([datetime]$Item.LastUsed).ToString('yyyy-MM-dd') }       else { '—' }
    $idle    = Get-IdleDescription $Item.LastUsed $Now
    if ($idle) { $modified = "$modified（$idle）" }

    $occ = switch ($Item.InUse) {
        $true   { '🔒 占用：正被某个程序打开/占用着，可能删不掉（清理时会尝试自动关掉占用它的程序）' }
        $false  { '🔓 占用：当前没被占用，可以删' }
        default { '' }
    }

    $lines = @(
        "📦 大文件（$kind）"
        "🔍 用途：$purpose"
        "📂 路径：$($Item.Path)"
        "📦 大小：$(Format-Size ([long]$Item.SizeBytes))"
        "🕒 创建 $created　修改 $modified　最后打开 $opened"
    )
    if ($occ) { $lines += $occ }
    $lines += '⚠ 这是你自己的文件，确认不用了再删；删后可在回收站找回。'
    return ($lines -join "`n")
}

Export-ModuleMember -Function Format-Size, Get-IdleDescription, Set-SafetyMark, Get-FolderSize, Get-FileKind, Get-FilePurpose, Get-FileTip
