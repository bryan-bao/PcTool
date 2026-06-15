# 磁盘清理工具 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做一个 PowerShell + WPF 的 Windows 磁盘清理工具，绿色免安装，扫描垃圾、按三档安全标记提示、勾选确认后删除（走回收站兜底）。

**Architecture:** 分层。`src/Modules/*.psm1` 是干活的纯逻辑模块（扫描返回数据对象、不碰界面）；`src/UI/MainWindow.ps1` 是 WPF 界面层（负责展示/勾选/调用模块）；`Start.ps1` 是入口；`一键启动.bat` 双击启动并提权。每个模块单一职责，扫描与删除分开。

**Tech Stack:** Windows PowerShell 5.1（系统自带，无需安装）、WPF（PresentationFramework + XAML）、Pester 5（仅开发期测试用）、Microsoft.VisualBasic.FileIO（删到回收站）。

---

## 约定：清理项数据对象

所有扫描模块统一返回 `PSCustomObject` 数组，字段固定：

```powershell
[PSCustomObject]@{
    Path        = 'C:\Windows\Temp'   # 文件/文件夹路径
    DisplayName = '系统临时文件'        # 界面显示的友好名
    Category    = 'Temp'              # Temp / RecycleBin / BrowserCache / LargeFile
    SizeBytes   = 1288490188          # [long] 占用字节
    LastUsed    = [datetime]'2025-10-01'  # 最后修改时间；无意义时为 $null
    Safety      = 'Green'             # Green / Yellow / Red（由 Analyzer 填）
    Reason      = '系统垃圾'           # 给用户看的说明（由 Analyzer 填）
    DefaultChecked = $true            # 默认是否勾选（由 Analyzer 填）
}
```

`Category` 取值在所有模块和 Analyzer 中保持一致：`Temp`、`RecycleBin`、`BrowserCache`、`LargeFile`。

---

## 开发环境准备（一次性）

Pester 5 仅用于开发期跑测试，不影响最终工具的免安装特性。

运行：
```powershell
powershell -Command "Get-Module -ListAvailable Pester | Select-Object Version"
```
若版本低于 5，运行：
```powershell
powershell -Command "Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck"
```

跑全部测试的命令（后续任务统一用它）：
```powershell
powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests' -Output Detailed"
```

---

## Task 0: 项目骨架与版本控制

**Files:**
- Create: `E:\超-工具\磁盘清理工具\.gitignore`
- Create: `E:\超-工具\磁盘清理工具\README.md`

- [ ] **Step 1: 初始化 git 仓库**

```powershell
git -C "E:\超-工具\磁盘清理工具" init
```

- [ ] **Step 2: 写 .gitignore**

Create `E:\超-工具\磁盘清理工具\.gitignore`：
```
.omc/
*.log
```

- [ ] **Step 3: 写 README.md 占位**

Create `E:\超-工具\磁盘清理工具\README.md`：
```markdown
# 磁盘清理工具

Windows 桌面磁盘清理工具，PowerShell + WPF 编写，绿色免安装。

## 使用方法

双击 `一键启动.bat` 即可（会请求管理员权限）。

## 功能

- 系统临时文件清理
- 回收站清理
- 浏览器缓存清理（Chrome / Edge）
- 大文件查找（带「多久没用」提示）

删除一律「扫描 → 勾选 → 确认」，普通文件删到回收站可找回。
```

- [ ] **Step 4: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add .gitignore README.md
git -C "E:\超-工具\磁盘清理工具" commit -m "chore: 初始化项目骨架"
```

---

## Task 1: Analyzer 模块 — 字节数友好显示

最纯的逻辑，先做，建立 TDD 节奏。

**Files:**
- Create: `src/Modules/Analyzer.psm1`
- Test: `tests/Analyzer.Tests.ps1`

- [ ] **Step 1: 写失败测试**

Create `tests/Analyzer.Tests.ps1`：
```powershell
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Analyzer.Tests.ps1' -Output Detailed"`
Expected: FAIL，提示 `Format-Size` 命令找不到。

- [ ] **Step 3: 写最小实现**

Create `src/Modules/Analyzer.psm1`：
```powershell
function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    elseif ($Bytes -lt 1MB) { return ('{0:0.0} KB' -f ($Bytes / 1KB)) }
    elseif ($Bytes -lt 1GB) { return ('{0:0.0} MB' -f ($Bytes / 1MB)) }
    else { return ('{0:0.0} GB' -f ($Bytes / 1GB)) }
}

Export-ModuleMember -Function Format-Size
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Analyzer.Tests.ps1' -Output Detailed"`
Expected: PASS，5 个测试全绿。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/Analyzer.psm1 tests/Analyzer.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(analyzer): 字节数友好显示 Format-Size"
```

---

## Task 2: Analyzer 模块 — 「多久没用」描述

**Files:**
- Modify: `src/Modules/Analyzer.psm1`
- Test: `tests/Analyzer.Tests.ps1`

- [ ] **Step 1: 追加失败测试**

在 `tests/Analyzer.Tests.ps1` 末尾追加：
```powershell
Describe 'Get-IdleDescription' {
    $now = [datetime]'2026-06-05'
    It '7 天内算最近还用过' {
        Get-IdleDescription ([datetime]'2026-06-01') $now | Should -Be '最近还用过'
    }
    It '不到一个月按天显示' {
        Get-IdleDescription ([datetime]'2026-05-20') $now | Should -Be '16天没动过'
    }
    It '超过一个月按月显示' {
        Get-IdleDescription ([datetime]'2025-10-05') $now | Should -Be '8个月没动过'
    }
    It 'LastUsed 为 null 返回空串' {
        Get-IdleDescription $null $now | Should -Be ''
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Analyzer.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Get-IdleDescription` 找不到。

- [ ] **Step 3: 写实现**

在 `src/Modules/Analyzer.psm1` 中，`Export-ModuleMember` 之前追加：
```powershell
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
```

并把导出行改为：
```powershell
Export-ModuleMember -Function Format-Size, Get-IdleDescription
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Analyzer.Tests.ps1' -Output Detailed"`
Expected: PASS，全部通过。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/Analyzer.psm1 tests/Analyzer.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(analyzer): 多久没用描述 Get-IdleDescription"
```

---

## Task 3: Analyzer 模块 — 三档安全标记

**Files:**
- Modify: `src/Modules/Analyzer.psm1`
- Test: `tests/Analyzer.Tests.ps1`

- [ ] **Step 1: 追加失败测试**

在 `tests/Analyzer.Tests.ps1` 末尾追加：
```powershell
Describe 'Set-SafetyMark' {
    $now = [datetime]'2026-06-05'

    It '系统临时文件标绿、默认勾选' {
        $item = [PSCustomObject]@{ Category='Temp'; LastUsed=$null }
        $r = Set-SafetyMark $item $now
        $r.Safety | Should -Be 'Green'
        $r.Reason | Should -Be '系统垃圾'
        $r.DefaultChecked | Should -BeTrue
    }
    It '浏览器缓存标绿' {
        $item = [PSCustomObject]@{ Category='BrowserCache'; LastUsed=$null }
        (Set-SafetyMark $item $now).Safety | Should -Be 'Green'
    }
    It '回收站标绿' {
        $item = [PSCustomObject]@{ Category='RecycleBin'; LastUsed=$null }
        (Set-SafetyMark $item $now).Safety | Should -Be 'Green'
    }
    It '大文件最近用过标红、不默认勾选' {
        $item = [PSCustomObject]@{ Category='LargeFile'; LastUsed=[datetime]'2026-06-02' }
        $r = Set-SafetyMark $item $now
        $r.Safety | Should -Be 'Red'
        $r.Reason | Should -Be '最近还用过'
        $r.DefaultChecked | Should -BeFalse
    }
    It '大文件很久没用标黄' {
        $item = [PSCustomObject]@{ Category='LargeFile'; LastUsed=[datetime]'2025-10-05' }
        $r = Set-SafetyMark $item $now
        $r.Safety | Should -Be 'Yellow'
        $r.Reason | Should -Be '8个月没动过'
        $r.DefaultChecked | Should -BeFalse
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Analyzer.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Set-SafetyMark` 找不到。

- [ ] **Step 3: 写实现**

在 `src/Modules/Analyzer.psm1` 的 `Export-ModuleMember` 之前追加：
```powershell
function Set-SafetyMark {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [datetime]$Now
    )
    switch ($Item.Category) {
        'Temp'         { $safety='Green'; $reason='系统垃圾';   $checked=$true }
        'RecycleBin'   { $safety='Green'; $reason='回收站';     $checked=$true }
        'BrowserCache' { $safety='Green'; $reason='浏览器缓存'; $checked=$true }
        'LargeFile'    {
            $checked = $false
            $days = if ($null -ne $Item.LastUsed) { ($Now - $Item.LastUsed).TotalDays } else { 9999 }
            if ($days -lt 7) { $safety='Red' } else { $safety='Yellow' }
            $reason = Get-IdleDescription $Item.LastUsed $Now
        }
        default        { $safety='Yellow'; $reason=''; $checked=$false }
    }
    $Item | Add-Member -NotePropertyName Safety -NotePropertyValue $safety -Force
    $Item | Add-Member -NotePropertyName Reason -NotePropertyValue $reason -Force
    $Item | Add-Member -NotePropertyName DefaultChecked -NotePropertyValue $checked -Force
    return $Item
}
```

并把导出行改为：
```powershell
Export-ModuleMember -Function Format-Size, Get-IdleDescription, Set-SafetyMark
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Analyzer.Tests.ps1' -Output Detailed"`
Expected: PASS，全部通过。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/Analyzer.psm1 tests/Analyzer.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(analyzer): 三档安全标记 Set-SafetyMark"
```

---

## Task 4: DiskScanner 模块 — 列出磁盘

**Files:**
- Create: `src/Modules/DiskScanner.psm1`
- Test: `tests/DiskScanner.Tests.ps1`

- [ ] **Step 1: 写失败测试**

Create `tests/DiskScanner.Tests.ps1`：
```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\DiskScanner.psm1" -Force
}

Describe 'Get-DiskList' {
    It '至少返回一个盘' {
        $disks = Get-DiskList
        $disks.Count | Should -BeGreaterThan 0
    }
    It '每个盘有盘符、总量、可用量字段' {
        $d = Get-DiskList | Select-Object -First 1
        $d.Drive    | Should -Match '^[A-Z]:$'
        $d.TotalBytes | Should -BeGreaterThan 0
        $d.PSObject.Properties.Name | Should -Contain 'FreeBytes'
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\DiskScanner.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Get-DiskList` 找不到。

- [ ] **Step 3: 写实现**

Create `src/Modules/DiskScanner.psm1`：
```powershell
function Get-DiskList {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [PSCustomObject]@{
            Drive     = $_.DeviceID            # 形如 'C:'
            TotalBytes = [long]$_.Size
            FreeBytes  = [long]$_.FreeSpace
        }
    }
}

Export-ModuleMember -Function Get-DiskList
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\DiskScanner.Tests.ps1' -Output Detailed"`
Expected: PASS。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/DiskScanner.psm1 tests/DiskScanner.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(disk): 列出本机磁盘 Get-DiskList"
```

---

## Task 5: 公共工具 — 目录大小统计

多个扫描模块都要算「某文件夹有多大」，抽成共享函数放进 Analyzer 模块（已被各处导入），避免重复。

**Files:**
- Modify: `src/Modules/Analyzer.psm1`
- Test: `tests/Analyzer.Tests.ps1`

- [ ] **Step 1: 追加失败测试**

在 `tests/Analyzer.Tests.ps1` 末尾追加：
```powershell
Describe 'Get-FolderSize' {
    BeforeAll {
        $tmp = Join-Path $env:TEMP ('dctest_' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Set-Content -Path (Join-Path $tmp 'a.txt') -Value ('x' * 1000)
        Set-Content -Path (Join-Path $tmp 'b.txt') -Value ('y' * 2000)
    }
    AfterAll { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It '统计文件夹内所有文件字节之和' {
        Get-FolderSize $tmp | Should -BeGreaterOrEqual 3000
    }
    It '不存在的路径返回 0' {
        Get-FolderSize 'X:\不存在的路径_abc' | Should -Be 0
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Analyzer.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Get-FolderSize` 找不到。

- [ ] **Step 3: 写实现**

在 `src/Modules/Analyzer.psm1` 的 `Export-ModuleMember` 之前追加：
```powershell
function Get-FolderSize {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}
```

并把导出行改为：
```powershell
Export-ModuleMember -Function Format-Size, Get-IdleDescription, Set-SafetyMark, Get-FolderSize
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Analyzer.Tests.ps1' -Output Detailed"`
Expected: PASS。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/Analyzer.psm1 tests/Analyzer.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(analyzer): 目录大小统计 Get-FolderSize"
```

---

## Task 6: TempCleaner 模块 — 系统临时文件扫描

**Files:**
- Create: `src/Modules/TempCleaner.psm1`
- Test: `tests/TempCleaner.Tests.ps1`

- [ ] **Step 1: 写失败测试**

Create `tests/TempCleaner.Tests.ps1`：
```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Analyzer.psm1" -Force
    Import-Module "$PSScriptRoot\..\src\Modules\TempCleaner.psm1" -Force
}

Describe 'Get-TempItems' {
    It '返回的每一项 Category 都是 Temp' {
        $items = Get-TempItems
        foreach ($i in $items) { $i.Category | Should -Be 'Temp' }
    }
    It '每一项有 Path 和 SizeBytes 字段' {
        $i = Get-TempItems | Select-Object -First 1
        if ($i) {
            $i.PSObject.Properties.Name | Should -Contain 'Path'
            $i.PSObject.Properties.Name | Should -Contain 'SizeBytes'
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\TempCleaner.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Get-TempItems` 找不到。

- [ ] **Step 3: 写实现**

Create `src/Modules/TempCleaner.psm1`：
```powershell
function Get-TempItems {
    $targets = @(
        @{ Path = $env:TEMP;                       Name = '用户临时文件' }
        @{ Path = (Join-Path $env:windir 'Temp');  Name = 'Windows 临时文件' }
        @{ Path = (Join-Path $env:windir 'Prefetch'); Name = '预读取文件 (Prefetch)' }
    )
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Path)) { continue }
        $size = Get-FolderSize $t.Path
        if ($size -le 0) { continue }
        [PSCustomObject]@{
            Path        = $t.Path
            DisplayName = $t.Name
            Category    = 'Temp'
            SizeBytes   = $size
            LastUsed    = $null
        }
    }
}

Export-ModuleMember -Function Get-TempItems
```

> 说明：`Get-FolderSize` 来自 Analyzer 模块，测试与 MainWindow 都会先 Import Analyzer。

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\TempCleaner.Tests.ps1' -Output Detailed"`
Expected: PASS。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/TempCleaner.psm1 tests/TempCleaner.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(temp): 系统临时文件扫描 Get-TempItems"
```

---

## Task 7: BrowserCache 模块 — 浏览器缓存扫描

**Files:**
- Create: `src/Modules/BrowserCache.psm1`
- Test: `tests/BrowserCache.Tests.ps1`

- [ ] **Step 1: 写失败测试**

Create `tests/BrowserCache.Tests.ps1`：
```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Analyzer.psm1" -Force
    Import-Module "$PSScriptRoot\..\src\Modules\BrowserCache.psm1" -Force
}

Describe 'Get-BrowserCacheItems' {
    It '返回项的 Category 都是 BrowserCache' {
        foreach ($i in Get-BrowserCacheItems) { $i.Category | Should -Be 'BrowserCache' }
    }
    It '不报错地返回数组（可能为空）' {
        { Get-BrowserCacheItems } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\BrowserCache.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Get-BrowserCacheItems` 找不到。

- [ ] **Step 3: 写实现**

Create `src/Modules/BrowserCache.psm1`：
```powershell
function Get-BrowserCacheItems {
    $local = $env:LOCALAPPDATA
    $browsers = @(
        @{ Name = 'Chrome 缓存'; Base = "$local\Google\Chrome\User Data" }
        @{ Name = 'Edge 缓存';   Base = "$local\Microsoft\Edge\User Data" }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path -LiteralPath $b.Base)) { continue }
        # 各用户配置（Default、Profile 1...）下的 Cache 目录
        $cacheDirs = Get-ChildItem -LiteralPath $b.Base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
            ForEach-Object { Join-Path $_.FullName 'Cache' } |
            Where-Object { Test-Path -LiteralPath $_ }
        $total = 0
        foreach ($c in $cacheDirs) { $total += Get-FolderSize $c }
        if ($total -le 0) { continue }
        [PSCustomObject]@{
            Path        = $b.Base
            DisplayName = $b.Name
            Category    = 'BrowserCache'
            SizeBytes   = [long]$total
            LastUsed    = $null
            CacheDirs   = $cacheDirs   # 删除时用：只删这些 Cache 子目录
        }
    }
}

Export-ModuleMember -Function Get-BrowserCacheItems
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\BrowserCache.Tests.ps1' -Output Detailed"`
Expected: PASS。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/BrowserCache.psm1 tests/BrowserCache.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(browser): 浏览器缓存扫描 Get-BrowserCacheItems"
```

---

## Task 8: RecycleBin 模块 — 回收站

**Files:**
- Create: `src/Modules/RecycleBin.psm1`
- Test: `tests/RecycleBin.Tests.ps1`

- [ ] **Step 1: 写失败测试**

Create `tests/RecycleBin.Tests.ps1`：
```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\RecycleBin.psm1" -Force
}

Describe 'Get-RecycleBinItem' {
    It '返回单个汇总项，Category 为 RecycleBin' {
        $r = Get-RecycleBinItem
        if ($r) { $r.Category | Should -Be 'RecycleBin' }
    }
    It '不报错' { { Get-RecycleBinItem } | Should -Not -Throw }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\RecycleBin.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Get-RecycleBinItem` 找不到。

- [ ] **Step 3: 写实现**

Create `src/Modules/RecycleBin.psm1`：
```powershell
function Get-RecycleBinItem {
    # 用 Shell COM 枚举回收站，累加占用大小
    $shell = New-Object -ComObject Shell.Application
    $bin = $shell.NameSpace(0xA)   # ssfBITBUCKET = 回收站
    if ($null -eq $bin) { return $null }
    $total = 0
    foreach ($it in $bin.Items()) {
        try { $total += [long]$it.Size } catch { }
    }
    if ($total -le 0) { return $null }
    [PSCustomObject]@{
        Path        = '回收站'
        DisplayName = '回收站'
        Category    = 'RecycleBin'
        SizeBytes   = [long]$total
        LastUsed    = $null
    }
}

function Clear-AllRecycleBin {
    # 彻底清空所有盘回收站（回收站本就是要清空的）
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-RecycleBinItem, Clear-AllRecycleBin
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\RecycleBin.Tests.ps1' -Output Detailed"`
Expected: PASS。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/RecycleBin.psm1 tests/RecycleBin.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(recyclebin): 回收站统计与清空"
```

---

## Task 9: LargeFiles 模块 — 大文件查找

**Files:**
- Create: `src/Modules/LargeFiles.psm1`
- Test: `tests/LargeFiles.Tests.ps1`

- [ ] **Step 1: 写失败测试**

Create `tests/LargeFiles.Tests.ps1`：
```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\LargeFiles.psm1" -Force
    $script:tmp = Join-Path $env:TEMP ('dclarge_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    # 造一个 2MB 的大文件、一个 10 字节的小文件
    $fs = [System.IO.File]::Create((Join-Path $script:tmp 'big.bin'))
    $fs.SetLength(2MB); $fs.Close()
    Set-Content -Path (Join-Path $script:tmp 'small.txt') -Value 'tiny'
}
AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-LargeFiles' {
    It '只返回超过阈值的文件' {
        $items = Get-LargeFiles -Roots @($script:tmp) -MinBytes 1MB
        $items.Count | Should -Be 1
        $items[0].DisplayName | Should -Match 'big\.bin'
    }
    It '返回项 Category 为 LargeFile，带 LastUsed' {
        $i = (Get-LargeFiles -Roots @($script:tmp) -MinBytes 1MB)[0]
        $i.Category | Should -Be 'LargeFile'
        $i.LastUsed | Should -BeOfType ([datetime])
    }
    It '按大小降序' {
        $fs = [System.IO.File]::Create((Join-Path $script:tmp 'big2.bin'))
        $fs.SetLength(3MB); $fs.Close()
        $items = Get-LargeFiles -Roots @($script:tmp) -MinBytes 1MB
        $items[0].SizeBytes | Should -BeGreaterOrEqual $items[1].SizeBytes
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\LargeFiles.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Get-LargeFiles` 找不到。

- [ ] **Step 3: 写实现**

Create `src/Modules/LargeFiles.psm1`：
```powershell
function Get-LargeFiles {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [long]$MinBytes = 100MB
    )
    $results = foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge $MinBytes } |
            ForEach-Object {
                [PSCustomObject]@{
                    Path        = $_.FullName
                    DisplayName = $_.FullName
                    Category    = 'LargeFile'
                    SizeBytes   = [long]$_.Length
                    LastUsed    = $_.LastWriteTime
                }
            }
    }
    $results | Sort-Object SizeBytes -Descending
}

Export-ModuleMember -Function Get-LargeFiles
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\LargeFiles.Tests.ps1' -Output Detailed"`
Expected: PASS。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/LargeFiles.psm1 tests/LargeFiles.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(large): 大文件查找 Get-LargeFiles"
```

---

## Task 10: Remover 模块 — 删除（走回收站兜底）

**Files:**
- Create: `src/Modules/Remover.psm1`
- Test: `tests/Remover.Tests.ps1`

- [ ] **Step 1: 写失败测试**

Create `tests/Remover.Tests.ps1`：
```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\Modules\Remover.psm1" -Force
    $script:tmp = Join-Path $env:TEMP ('dcrm_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
}
AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Remove-ToRecycleBin' {
    It '能删掉一个文件并返回成功' {
        $f = Join-Path $script:tmp 'del1.txt'
        Set-Content -Path $f -Value 'bye'
        $r = Remove-ToRecycleBin $f
        $r.Success | Should -BeTrue
        Test-Path $f | Should -BeFalse
    }
    It '删不存在的文件返回失败但不抛异常' {
        $r = Remove-ToRecycleBin (Join-Path $script:tmp '不存在.txt')
        $r.Success | Should -BeFalse
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Remover.Tests.ps1' -Output Detailed"`
Expected: FAIL，`Remove-ToRecycleBin` 找不到。

- [ ] **Step 3: 写实现**

Create `src/Modules/Remover.psm1`：
```powershell
Add-Type -AssemblyName Microsoft.VisualBasic

function Remove-ToRecycleBin {
    # 把文件/文件夹删到回收站，可找回。返回 @{ Success; Path; Error }
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Success=$false; Path=$Path; Error='路径不存在' }
    }
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
        return [PSCustomObject]@{ Success=$true; Path=$Path; Error=$null }
    } catch {
        return [PSCustomObject]@{ Success=$false; Path=$Path; Error=$_.Exception.Message }
    }
}

Export-ModuleMember -Function Remove-ToRecycleBin
```

- [ ] **Step 4: 跑测试确认通过**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests\Remover.Tests.ps1' -Output Detailed"`
Expected: PASS。注意：删到回收站后 `Test-Path` 为 false，测试结束 AfterAll 清理临时目录。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/Modules/Remover.psm1 tests/Remover.Tests.ps1
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(remover): 删除到回收站 Remove-ToRecycleBin"
```

---

## Task 11: WPF 主界面

界面层难做自动化单元测试，采用「手动验证 + 冒烟脚本」。先把界面骨架跑起来，再接模块。

**Files:**
- Create: `src/UI/MainWindow.ps1`
- Create: `src/Start.ps1`
- Create: `一键启动.bat`

- [ ] **Step 1: 写主界面 XAML + 逻辑**

Create `src/UI/MainWindow.ps1`：
```powershell
Add-Type -AssemblyName PresentationFramework

$mod = Join-Path $PSScriptRoot '..\Modules'
'Analyzer','DiskScanner','TempCleaner','BrowserCache','RecycleBin','LargeFiles','Remover' |
    ForEach-Object { Import-Module (Join-Path $mod "$_.psm1") -Force }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="磁盘清理工具" Height="640" Width="820"
        WindowStartupLocation="CenterScreen" Background="#F5F7FA" FontFamily="Microsoft YaHei">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="🧹 磁盘清理工具" FontSize="20" FontWeight="Bold" Foreground="#1F2933" Margin="0,0,0,10"/>
    <WrapPanel Grid.Row="1" x:Name="DiskPanel" Margin="0,0,0,8"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,8">
      <CheckBox x:Name="CbTemp" Content="系统临时" IsChecked="True" Margin="0,0,12,0"/>
      <CheckBox x:Name="CbRecycle" Content="回收站" IsChecked="True" Margin="0,0,12,0"/>
      <CheckBox x:Name="CbBrowser" Content="浏览器缓存" IsChecked="True" Margin="0,0,12,0"/>
      <CheckBox x:Name="CbLarge" Content="大文件(>100MB)" IsChecked="True" Margin="0,0,12,0"/>
      <Button x:Name="BtnScan" Content="开始扫描" Width="100" Height="30" Background="#2563EB" Foreground="White" BorderThickness="0" Cursor="Hand"/>
      <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Margin="12,0,0,0" Foreground="#6B7280"/>
    </StackPanel>
    <DataGrid Grid.Row="3" x:Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal">
      <DataGrid.Columns>
        <DataGridCheckBoxColumn Header="" Binding="{Binding Checked, Mode=TwoWay}" Width="36"/>
        <DataGridTextColumn Header="标记" Binding="{Binding Mark}" Width="90"/>
        <DataGridTextColumn Header="名称" Binding="{Binding DisplayName}" Width="*"/>
        <DataGridTextColumn Header="大小" Binding="{Binding SizeText}" Width="90"/>
        <DataGridTextColumn Header="说明" Binding="{Binding Reason}" Width="120"/>
      </DataGrid.Columns>
    </DataGrid>
    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <TextBlock x:Name="TxtSelected" VerticalAlignment="Center" Margin="0,0,16,0" Foreground="#1F2933"/>
      <Button x:Name="BtnClean" Content="清理选中项" Width="120" Height="34" Background="#DC2626" Foreground="White" BorderThickness="0" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)

$diskPanel = $win.FindName('DiskPanel')
$grid      = $win.FindName('Grid')
$txtStatus = $win.FindName('TxtStatus')
$txtSel    = $win.FindName('TxtSelected')

# 顶部磁盘勾选框
$script:diskChecks = @()
foreach ($d in (Get-DiskList)) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = "$($d.Drive) ($(Format-Size $d.FreeBytes) 可用)"
    $cb.Margin = '0,0,12,0'
    $cb.Tag = $d.Drive
    if ($d.Drive -eq 'C:') { $cb.IsChecked = $true }
    $diskPanel.AddChild($cb)
    $script:diskChecks += $cb
}

$script:rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$grid.ItemsSource = $script:rows

function Update-SelectedTotal {
    $sum = 0
    foreach ($r in $script:rows) { if ($r.Checked) { $sum += $r.SizeBytes } }
    $txtSel.Text = "已选 $(Format-Size $sum)"
}

function Convert-ToRow {
    param($item)
    Set-SafetyMark $item ([datetime]::Now) | Out-Null
    $mark = switch ($item.Safety) { 'Green' {'🟢可放心删'} 'Yellow' {'🟡建议确认'} 'Red' {'🔴谨慎'} default {''} }
    [PSCustomObject]@{
        Checked     = [bool]$item.DefaultChecked
        Mark        = $mark
        DisplayName = $item.DisplayName
        SizeText    = Format-Size $item.SizeBytes
        Reason      = $item.Reason
        SizeBytes   = $item.SizeBytes
        Source      = $item   # 保留原始对象，删除时用
    }
}

$win.FindName('BtnScan').Add_Click({
    $script:rows.Clear()
    $txtStatus.Text = '扫描中...'
    $selectedDrives = $script:diskChecks | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag }

    $items = @()
    if ($win.FindName('CbTemp').IsChecked)    { $items += Get-TempItems }
    if ($win.FindName('CbRecycle').IsChecked) { $r = Get-RecycleBinItem; if ($r) { $items += $r } }
    if ($win.FindName('CbBrowser').IsChecked) { $items += Get-BrowserCacheItems }
    if ($win.FindName('CbLarge').IsChecked -and $selectedDrives) {
        $roots = $selectedDrives | ForEach-Object { "$_\" }
        $items += Get-LargeFiles -Roots $roots -MinBytes 100MB
    }
    foreach ($it in $items) { $script:rows.Add((Convert-ToRow $it)) }
    Update-SelectedTotal
    $txtStatus.Text = "扫描完成，共 $($script:rows.Count) 项"
})

$win.FindName('BtnClean').Add_Click({
    $checked = @($script:rows | Where-Object { $_.Checked })
    if ($checked.Count -eq 0) { [System.Windows.MessageBox]::Show('没有勾选任何项'); return }
    $sum = ($checked | Measure-Object -Property SizeBytes -Sum).Sum
    $ans = [System.Windows.MessageBox]::Show(
        "将清理 $($checked.Count) 项，释放约 $(Format-Size ([long]$sum))。`n普通文件删到回收站可找回，确定吗？",
        '确认清理', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    $ok = 0; $freed = 0
    foreach ($row in $checked) {
        $src = $row.Source
        switch ($src.Category) {
            'RecycleBin'   { Clear-AllRecycleBin; $ok++; $freed += $src.SizeBytes }
            'BrowserCache' { foreach ($c in $src.CacheDirs) { (Remove-ToRecycleBin $c) | Out-Null }; $ok++; $freed += $src.SizeBytes }
            default        { $res = Remove-ToRecycleBin $src.Path; if ($res.Success) { $ok++; $freed += $src.SizeBytes } }
        }
    }
    [System.Windows.MessageBox]::Show("清理完成：成功 $ok 项，释放约 $(Format-Size ([long]$freed))。")
    $win.FindName('BtnScan').RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
})

$grid.Add_CellEditEnding({ $win.Dispatcher.BeginInvoke([action]{ Update-SelectedTotal }, 'Background') })

$win.ShowDialog() | Out-Null
```

- [ ] **Step 2: 写入口 Start.ps1**

Create `src/Start.ps1`：
```powershell
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning '建议以管理员身份运行（清理系统临时文件/回收站需要）。'
}
& (Join-Path $PSScriptRoot 'UI\MainWindow.ps1')
```

- [ ] **Step 3: 写一键启动.bat**

Create `E:\超-工具\磁盘清理工具\一键启动.bat`：
```bat
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -STA -File \"%~dp0src\Start.ps1\"'"
```

> 用 `%~dp0` 取 bat 所在目录，这样整个文件夹拷到任何地方都能用（不写死路径）。

- [ ] **Step 4: 冒烟验证（手动）**

双击 `一键启动.bat`：
- Expected: 弹出 UAC 提权 → 出现「磁盘清理工具」窗口，顶部能看到本机磁盘勾选框。
- 勾选「系统临时」「回收站」「浏览器缓存」，点「开始扫描」→ 列表出现带 🟢 标记的项、各自大小。
- 勾选「大文件」+ 某个盘，再扫描 → 出现 🟡/🔴 标记的大文件，带「X个月没动过」。
- 勾掉部分项，底部「已选」数字随之变化。
- 点「清理选中项」→ 弹确认框 → 选「是」→ 弹完成汇总 → 列表自动重新扫描。

- [ ] **Step 5: 提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add src/UI/MainWindow.ps1 src/Start.ps1 "一键启动.bat"
git -C "E:\超-工具\磁盘清理工具" commit -m "feat(ui): WPF 主界面与一键启动"
```

---

## Task 12: 全量回归与收尾

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 跑全部测试**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path 'E:\超-工具\磁盘清理工具\tests' -Output Detailed"`
Expected: 所有 Describe 全绿，无失败。

- [ ] **Step 2: 补全 README 使用说明**

在 `README.md` 末尾追加「常见问题」一节：
```markdown
## 常见问题

- **杀毒/SmartScreen 拦截 bat？** 选择"仍要运行"。脚本是纯文本，可右键编辑查看。
- **没有管理员权限？** 仍可清理浏览器缓存和用户临时文件；系统级目录可能跳过。
- **删错了怎么办？** 普通文件在回收站里，去回收站还原即可（除非你又清空了回收站）。
```

- [ ] **Step 3: 最终提交**

```powershell
git -C "E:\超-工具\磁盘清理工具" add README.md
git -C "E:\超-工具\磁盘清理工具" commit -m "docs: 补全使用说明与常见问题"
```

---

## 自查对照（Spec 覆盖）

- 系统临时文件 → Task 6 ✓
- 回收站 → Task 8 ✓
- 浏览器缓存（Chrome/Edge）→ Task 7 ✓
- 大文件查找 → Task 9 ✓
- 🟢🟡🔴 三档安全标记 + 多久没用 → Task 2、3（界面接入 Task 11）✓
- 选磁盘 → Task 4 + 界面 Task 11 ✓
- 预览+勾选+确认才删 → 界面 Task 11 的确认框 ✓
- 删除走回收站兜底 → Task 10 ✓
- 绿色免安装 / 一键启动.bat / 提权 → Task 11 ✓
- 测试 → 各模块 Task 均含 Pester 测试，Task 12 全量回归 ✓
