# -*- coding: utf-8 -*-
# 翻译·语音小工具 —— 一键打包脚本
# 双击「一键打包.bat」会调用本脚本，自动完成：检查代码 → 打包 exe → 编译安装包
# 也可命令行无人值守：powershell -File build.ps1 -Yes  或  -Version 1.3.0 -Yes
param([string]$Version = "", [switch]$Yes)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

$py         = Join-Path $root "venv\Scripts\python.exe"
$pyinst     = Join-Path $root "venv\Scripts\pyinstaller.exe"
$spec       = Join-Path $root "TranslationTool.spec"
$iss        = Join-Path $root "installer\setup_release.iss"
$outDir     = Join-Path $root "安装包"
$exe        = Join-Path $outDir "翻译语音小工具-安装包.exe"
$req        = Join-Path $root "requirements.txt"

function Step($n,$m){ Write-Host "`n[$n] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "      √ $m" -ForegroundColor Green }
function Die($m){ Write-Host "`n  ×××  失败：$m" -ForegroundColor Red; if(-not $Yes){ Read-Host "`n按回车退出" }; exit 1 }

Write-Host "`n=====  翻译·语音小工具 · 一键打包  =====" -ForegroundColor Magenta

# 0 环境检查
Step 0 "检查打包环境"
if(-not (Test-Path $py)){
  $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
  $python = Get-Command python.exe -ErrorAction SilentlyContinue
  if($launcher){
    & $launcher.Source -3 -m venv (Join-Path $root "venv")
  } elseif($python) {
    & $python.Source -m venv (Join-Path $root "venv")
  } else {
    Die "没找到 Python。请先安装 Python 3.11+，并勾选 Add Python to PATH"
  }
  if($LASTEXITCODE -ne 0){ Die "创建 venv 失败" }
}
foreach($f in @($py,$spec,$iss,$req)){ if(-not (Test-Path $f)){ Die "缺少必要文件/工具：$f" } }
if(-not (Test-Path $pyinst)){
  & $py -m pip install -U pip
  if($LASTEXITCODE -ne 0){ Die "升级 pip 失败，请检查网络" }
  & $py -m pip install -r $req
  if($LASTEXITCODE -ne 0){ Die "安装 Python 依赖失败，请检查网络" }
}
$isccCmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if(!$isccCmd){
  $commonIscc = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
  )
  foreach($candidate in $commonIscc){
    if(Test-Path $candidate){
      $env:Path = (Split-Path -Parent $candidate) + ";" + $env:Path
      $isccCmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
      break
    }
  }
}
if(!$isccCmd){
  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
  if($winget){
    Write-Host "      未找到 Inno Setup，正在用 winget 安装..." -ForegroundColor Cyan
    & $winget.Source install -e --id JRSoftware.InnoSetup --accept-source-agreements --accept-package-agreements
    if($LASTEXITCODE -ne 0){ Die "Inno Setup 自动安装失败，请手动安装：https://jrsoftware.org/isdl.php" }
    $env:Path = "C:\Program Files (x86)\Inno Setup 6;C:\Program Files\Inno Setup 6;" + $env:Path
    $isccCmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  }
}
if(!$isccCmd){ Die "缺少 Inno Setup 6。请安装后重新运行：https://jrsoftware.org/isdl.php" }
Ok "环境就绪"

# 1 版本号（可选更新）
Step 1 "版本号"
$m = Select-String -Path $iss -Pattern '#define MyVersion "([^"]+)"'
$cur = if($m){ $m.Matches[0].Groups[1].Value } else { "未知" }
Write-Host "      当前版本：$cur"
$want = $Version.Trim()
if(-not $want -and -not $Yes){ $want = (Read-Host "      要改版本号就输入（如 1.3.0），不改直接回车").Trim() }
if($want){
  $c = [System.IO.File]::ReadAllText($iss,[System.Text.Encoding]::UTF8)
  $c = $c -replace '#define MyVersion "[^"]+"', ('#define MyVersion "{0}"' -f $want)
  [System.IO.File]::WriteAllText($iss,$c,(New-Object System.Text.UTF8Encoding($true)))
  Ok "版本号已更新为 $want"
} else { Ok "保持 $cur" }

# 2 代码语法快速检查（提前发现手误，省得打包半天才报错）
Step 2 "检查代码语法"
& $py -m py_compile app.py desktop.py snip.py hotkey.py selection.py bing_translate.py doc_translate.py
if($LASTEXITCODE -ne 0){ Die "代码有语法错误，请先改好再打包" }
Ok "语法没问题"

# 3 关掉正在运行的程序（不然 dist 文件被占用，打包会失败）
Step 3 "关闭正在运行的程序"
Get-Process TranslationTool -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
Ok "已关闭"

# 4 PyInstaller 打包
Step 4 "打包程序（约 1~2 分钟，请耐心等）"
& $pyinst --noconfirm $spec
if($LASTEXITCODE -ne 0){ Die "PyInstaller 打包失败，看上面红字排查" }
Ok "程序已打包到 dist\TranslationTool"

# 5 编译安装包（先确保 iss 是 UTF-8 BOM，防中文乱码）
Step 5 "编译安装包"
# 关掉可能还开着的旧安装程序：它会锁住输出的安装包文件，让 ISCC 写不进去(Error 32)，
# 结果打出半截的损坏包(点开报 corrupted)。这是反复打出坏包的元凶，必须先清掉。
$leaf = [System.IO.Path]::GetFileNameWithoutExtension($exe)
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process $leaf -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 700
# 删掉上次的旧包，确保全新写入；删不掉=还被占用，直接报错让用户先关掉安装程序窗口
if(Test-Path $exe){
  try{ Remove-Item $exe -Force -ErrorAction Stop }
  catch{ Die "旧的安装包删不掉，多半是它正被打开（你之前双击运行过、窗口没关）。请先关掉所有“翻译语音小工具-安装包”的窗口/进程（实在不行重启电脑），再重新打包。`n      文件：$exe" }
}
$c = [System.IO.File]::ReadAllText($iss,[System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($iss,$c,(New-Object System.Text.UTF8Encoding($true)))
Push-Location (Join-Path $root "installer")
& $isccCmd.Source /Q "setup_release.iss"
$code = $LASTEXITCODE
Pop-Location
if($code -ne 0){ Die "安装包编译失败" }
if(-not (Test-Path $exe)){ Die "没找到生成的安装包，编译可能出错了" }
# 成品大小自检：正常约 75MB，明显偏小说明没打全/被杀毒软件改坏（会报 corrupted），直接拦住
$gotMb = (Get-Item $exe).Length/1MB
if($gotMb -lt 60){ Die ("安装包只有 {0} MB，明显偏小（正常约 75MB）。多半是没打全，或被杀毒软件干扰改坏了——这种包点开会报 corrupted（损坏）。请把项目目录 {1} 加进杀毒软件/Windows安全中心的排除项后，重新打包。" -f [math]::Round($gotMb,1), $root) }
Ok "安装包已生成"

# 6 完成
$mb = [math]::Round((Get-Item $exe).Length/1MB)
$ver = (Select-String -Path $iss -Pattern '#define MyVersion "([^"]+)"').Matches[0].Groups[1].Value
Write-Host "`n=====================================================" -ForegroundColor Green
Write-Host "  ✅  打包完成！版本 $ver" -ForegroundColor Green
Write-Host "  安装包：安装包\翻译语音小工具-安装包.exe（$mb MB）" -ForegroundColor Green
Write-Host "  发给别人时，连同同目录的「安装说明-请先看我.html」一起发" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
if(-not $Yes){
  Start-Process $outDir   # 自动打开安装包文件夹
  Read-Host "`n按回车关闭"
}
