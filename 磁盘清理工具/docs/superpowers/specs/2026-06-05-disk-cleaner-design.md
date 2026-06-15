# 磁盘清理工具 — 设计方案

- 日期：2026-06-05
- 形态：纯 PowerShell + WPF 界面，绿色免安装，一键启动
- 参考：`E:\InstallationTools`（同款架构与界面风格）

## 1. 目标与背景

做一个 Windows 桌面磁盘清理工具，帮用户找出并清理占空间的垃圾文件。核心诉求：

- **有界面**：双击就能用，看得见每样东西占多少空间，点按钮清理。
- **绿色免安装**：用 Windows 自带的 PowerShell 写，对方电脑啥都不用装，**整个文件夹发过去就能用**。
- **聪明**：不光列文件，还帮用户判断「能不能删、多久没碰过」，在界面上用颜色标记出来。
- **安全**：绝不自动乱删。一律「扫描 → 预览 → 勾选 → 确认 → 删除」，删除走回收站兜底。

## 2. 技术形态

- 语言：PowerShell（Windows 自带，无需安装运行时）。
- 界面：WPF（`Add-Type -AssemblyName PresentationFramework`）+ XAML，与 `InstallationTools` 同风格（微软雅黑字体、蓝色主按钮、浅色背景 `#F5F7FA`）。
- 启动：`一键启动.bat` 用 `powershell -NoProfile -ExecutionPolicy Bypass`，并以管理员权限（RunAs）启动，因为清理系统临时文件、回收站需要权限。
- 测试：Pester（与 `InstallationTools` 一致），覆盖各扫描/分析模块的纯逻辑部分。

## 3. 文件结构

```
磁盘清理工具/
├── 一键启动.bat              # 双击启动，自动提管理员权限
├── src/
│   ├── Start.ps1             # 入口：检查权限后打开界面
│   ├── UI/
│   │   └── MainWindow.ps1    # WPF 主界面（XAML）+ 事件逻辑
│   └── Modules/
│       ├── DiskScanner.psm1     # 列出磁盘盘符、总量/可用量
│       ├── TempCleaner.psm1     # 系统临时文件扫描
│       ├── RecycleBin.psm1      # 回收站扫描/清空
│       ├── BrowserCache.psm1    # 浏览器缓存扫描
│       ├── LargeFiles.psm1      # 大文件查找
│       └── Analyzer.psm1        # 安全标记 + 多久没用 判断
├── tests/                    # Pester 测试
├── docs/                     # 方案文档
└── README.md                # 使用说明
```

**模块原则**：每个模块只干一件事；「扫描」与「删除」分开；模块返回纯数据对象（不直接操作界面），界面层负责展示与勾选。这样好测、好查问题。

## 4. 功能模块

每个扫描模块统一返回一组「清理项」对象，字段约定：

| 字段 | 含义 |
|------|------|
| `Path` | 文件/文件夹路径 |
| `DisplayName` | 界面上显示的友好名字（如「Chrome 缓存」） |
| `Category` | 类别：Temp / RecycleBin / BrowserCache / LargeFile |
| `SizeBytes` | 占用字节数 |
| `LastUsed` | 最后修改/访问时间（用于判断多久没用） |
| `Safety` | 安全档：Green / Yellow / Red |
| `Reason` | 给用户看的说明（如「系统垃圾」「8个月没动过」） |

### 4.1 DiskScanner — 磁盘列表
- 用 `Get-PSDrive -PSProvider FileSystem` 或 `Get-CimInstance Win32_LogicalDisk` 列出所有盘符。
- 提供每个盘的总容量、可用空间，供界面顶部「选哪个盘」勾选。

### 4.2 TempCleaner — 系统临时文件
- 扫描位置：`$env:TEMP`、`$env:windir\Temp`、`C:\Windows\Prefetch` 等公认临时目录。
- 全部标记为 🟢 Green，Reason「系统垃圾」。
- 正被占用、删不掉的文件跳过并忽略报错。

### 4.3 RecycleBin — 回收站
- 用 Shell COM（`(New-Object -ComObject Shell.Application).NameSpace(0xA)`）统计各盘回收站占用。
- 清理动作：调用 `Clear-RecycleBin`（按用户勾选的盘）。
- 标记 🟢 Green，Reason「回收站」。

### 4.4 BrowserCache — 浏览器缓存
- 覆盖 Chrome、Edge（基于 Chromium，缓存路径结构相同）：
  - `%LocalAppData%\Google\Chrome\User Data\*\Cache`
  - `%LocalAppData%\Microsoft\Edge\User Data\*\Cache`
- 标记 🟢 Green，Reason「浏览器缓存」。
- 注意：只删缓存目录，不碰书签、密码、历史等用户数据。

### 4.5 LargeFiles — 大文件查找
- 在用户勾选的盘上，扫描大于阈值（默认 100MB）的文件。
- 按大小排序。这里是「建议」性质，交给用户判断，不默认勾选。
- 交给 Analyzer 打安全标记。

### 4.6 Analyzer — 安全标记 + 多久没用
判断规则：

- **🟢 Green（可放心删）**：Temp / RecycleBin / BrowserCache 这类公认垃圾，默认勾选。
- **🟡 Yellow（建议确认）**：大文件，且 `LastUsed` 距今 ≥ 3 个月。Reason 形如「8个月没动过」。**默认不勾选**，但建议可删。
- **🔴 Red（谨慎）**：大文件，但 `LastUsed` 距今 < 7 天（最近还动过）。Reason「最近还用过」。**默认不勾选**，提醒别误删。
- 介于其间（7天～3个月）的大文件：🟡 Yellow，Reason「X个月没动过」，默认不勾选。
- 「多久没用」= 当前时间 − `LastUsed`，换算成「X 天 / X 个月」显示。
- 大文件列表支持按「最久没用」排序，把「占地方又早忘了」的排前面。

## 5. 删除策略（安全第一）

- 流程：选盘 → 勾选扫描类型 → 开始扫描 → 结果列表（带标记）→ 用户勾选 → 点「清理选中项」→ 弹窗二次确认（显示将释放多少空间）→ 执行删除。
- **删除走回收站兜底**：普通文件用 Shell 的「删到回收站」方式（`Microsoft.VisualBasic.FileIO.FileSystem::DeleteFile` 带 `RecycleBin` 选项），误删可找回。
- 例外：回收站本身的清理直接调 `Clear-RecycleBin`（本来就是要彻底清空）。
- 删除过程逐项处理，单个失败（被占用/无权限）只跳过并记录，不中断整体。
- 删除完成后给汇总：成功删了几项、释放多少空间、跳过几项。

## 6. 界面布局（WPF）

```
┌──────────────────────────────────────────────┐
│   🧹 磁盘清理工具                              │
├──────────────────────────────────────────────┤
│  选哪个盘:  ☑C:  ☐D:  ☐E:  ☐F:              │
│  扫描类型:  ☑系统临时  ☑回收站                │
│             ☑浏览器缓存 ☑大文件(>100MB)       │
│              [ 开始扫描 ]   ▓▓▓░░ 进度        │
├──────────────────────────────────────────────┤
│  扫描结果（勾选要删的）：                      │
│   ☑ 🟢可放心删 C:\Windows\Temp ..... 1.2 GB   │
│   ☑ 🟢可放心删 Chrome 缓存 ......... 456 MB   │
│   ☐ 🟡建议确认 E:\下载\安装包.zip .. 800 MB   │
│                            （8个月没动过）     │
│   ☐ 🔴谨慎    E:\工作\报告.docx ...... 5 MB   │
│                            （最近还用过）      │
│  已选 1.6 GB              [ 清理选中项 ]       │
└──────────────────────────────────────────────┘
```

- 顶部：磁盘勾选 + 扫描类型勾选 + 「开始扫描」按钮 + 进度条。
- 中部：结果列表（DataGrid 或 ListView），每行带勾选框、颜色标记、名称、大小、说明。
- 底部：实时显示「已勾选总大小」+「清理选中项」按钮。
- 扫描耗时操作放后台线程/Runspace，避免界面卡死（进度条转起来）。

## 7. 测试策略

- Pester 单元测试，针对模块的**纯逻辑**：
  - Analyzer 的标记规则（给定大小/时间 → 预期 Green/Yellow/Red + Reason 文案）。
  - 字节数 → 友好显示（KB/MB/GB）换算。
  - 「多久没用」时间差换算。
- 涉及真实文件系统的扫描，用临时目录造测试数据验证。
- 删除类操作用 mock 或临时目录，**绝不在测试里碰真实系统目录**。

## 8. 非目标（YAGNI，先不做）

- 不做打包成 exe（PowerShell 已经免安装；将来真需要再说）。
- 不做定时/自动后台清理（先做手动界面版）。
- 不做注册表清理（风险高、收益小）。
- 不做 Firefox 等非 Chromium 浏览器（先覆盖 Chrome/Edge，后续可加）。
- 不做云同步、设置中心等附加功能。

## 9. 开放问题 / 待定

- 暂无。设计已与用户确认。
