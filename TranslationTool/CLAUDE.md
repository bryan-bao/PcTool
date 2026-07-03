# 翻译·语音桌面软件（TranslationTool）

## 项目是什么
给非技术用户做的 Windows 桌面工具：14 语种文字翻译 + 截图翻译（框选屏幕 OCR）+ 翻译结果朗读 + 文字转语音（15 种声音可选、语速可调、生成 MP3）+ 设置页。翻译/语音用免费云服务（谷歌 + 微软 edge-tts）需联网；截图 OCR 用 RapidOCR 本地离线。

界面：三页签布局（📝 翻译 = 左右双栏对照 + ✂️截图翻译按钮；🎙️ 文字转语音；⚙️ 设置），一屏放下不滚动；URL 带 `#tts` / `#set` 直接开对应页签（测试截图用）。用户对界面美观敏感，改 UI 后务必无头截图各页签确认效果再交付。

**完整方案/路线图见 `项目方案.html`（同目录）。状态有变化时要同步更新该文档和本文件。**

## 当前状态（2026-06-12）
- ✅ 阶段 1 网页版原型：`app.py`（Flask）+ `static/index.html`，实测通过
- ✅ 阶段 2 桌面窗口：`desktop.py`（pywebview，随机端口 + 失败换端口重试），实测通过
- ✅ 阶段 3 打包 exe：`TranslationTool.spec`（onedir，31MB），打包版翻译/TTS/路径全部实测通过
- ✅ 阶段 4 安装包：`installer/setup.iss` → `安装包/翻译语音小工具-安装包-v1.1.exe`（中文向导）；已装到 `安装好的程序\`（桌面有快捷方式）
- ✅ v1.1（2026-06-12）：新增 ✂️截图翻译（snip.py 全屏选区子进程 + RapidOCR 离线识别，实测中英文通过）和 ⚙️设置页签（默认语言/声音/语速、引擎切换 google/mymemory、开机自启注册表 Run 项，存 DATA_DIR/settings.json）
- ✅ v1.1 追加：全局快捷键截图翻译（hotkey.py，RegisterHotKey 消息循环线程，默认 ctrl+alt+t，设置页可改/可禁用；触发后 hotkey_snip() → evaluate_js 回填页面并自动翻译；模拟按键+拖框实测全链路通过）。审查修复：snip/settings 双锁防并发、settings 原子写+严格校验、snip.py 焦点/坐标夹紧/误点重拖、录快捷键用 e.code 不用 e.key
- ✅ v1.1 追加：关闭按钮 = 收进系统托盘后台运行（pystray；window.events.closing 返回 False 拦截 + hide）；托盘菜单：打开主界面/截图翻译/退出（退出 os._exit(0) 兜底）；hotkey_snip 弹窗前先 win.show()。WM_CLOSE 实测：窗口隐藏、进程活、服务 200。app.ico 已加进 spec datas（托盘图标要用）
- ✅ v1.1 追加：划词翻译（selection.py）。全局低级鼠标钩子（WH_MOUSE_LL，裸消息循环线程）检测划选→tkinter UI 线程（SetThreadDpiAwarenessContext(-4) 保证按物理像素贴光标）在光标旁弹"译"小按钮→点击 Ctrl+C 复制选中文字→翻译→紫框小弹窗。设置开关：selection_translate、selection_require_ctrl（按住Ctrl才弹）。截图期 selection.suspend() 挂起免误触；前台是自己窗口时跳过。截图设置 snip_to_window：True 弹主窗口，False 就地用 selection 的小弹窗显示译文。translate_text() 是划词/就地翻译的统一入口（mymemory+auto 退回 google）。
  - 实测：selection 模块导入/钩子安装/UI 线程无崩溃；译按钮+结果弹窗渲染正常；设置读写正常；自己窗口跳过逻辑生效。"真实跨程序划选弹按钮"因测试环境窗口焦点难自动化，未端到端截图确认——改代码后建议让用户在浏览器里实测划词。
  - ⚠ 划词只在桌面版（desktop.py 启动 selection）；网页版没有。三个 GUI 循环共存：pywebview(主线程)+pystray(detached)+selection tk(独立线程)+hotkey/hook(消息循环线程)。
- ✅ v1.1 追加（用户参考贴图效果图后定型）：
  - **智能翻译方向**：划词/截图默认"外语→中文，中文→设置的目标语言"（后端 smart_target()，前端 smartTargetFor()，阈值 CJK 占比 0.25）
  - **贴图翻译**：snip_to_window=False 时，译文按 OCR 行坐标"贴"回截图原位置（build_overlay_image：背景=区域众数色、亮度选黑/白字、字号自适应宽度），整块由 selection 的 tk 浮窗按 snip 写的 region json（屏幕物理坐标）原位覆盖显示；左键关、右键复制译文、30 秒自动关。实测端到端通过（英文板→框选→中文贴回原位）
  - **提速**：desktop.py 启动 2 秒后后台预热 get_ocr()；translate_lines 分块（4000 字防超限）整批请求（行数不匹配才并行逐行）
  - **精度三件套（用户反馈"很多翻译不出来"后加）**：① 截图 <1100px 先放大 2 倍再 OCR（小字识别率大增，坐标 /scale 缩回）；② **fix_spaces()+wordninja 拆 OCR 粘连英文**（"Settingsandprivacy"→"Settings and privacy"，这是英文截图翻译烂的元凶；只动 ≥13 字母长串；spec 要 collect_data_files('wordninja')）；③ 划词剪贴板重试 3 次 + 支持双击选词（钩子里两次原地快速点击判定）
  - **"正在翻译"小条**：框选完成立即在截图位置上方显示紫色 busy 条（selection.show_busy/hide_busy），结果出来自动消失
  - 划词弹窗误关 bug 已修（_popup_ignore 放过打开弹窗的那次点击）；✂️按钮和快捷键都走 snip_to_window 设置
- ✅ v1.1 追加（2026-06-15，用户提的 4 个优化点）：
  - **译文可手动选中复制**：译文区 `.result` 加 `user-select:text`+文字光标+选中高亮，可拖蓝复制部分译文（不止"📋 复制"全文）
  - **可改语音保存位置**：设置页"语音保存位置"行显示当前目录+「📁修改保存位置」（桌面版 `WEBVIEW_WINDOW.create_file_dialog(FOLDER_DIALOG)` 选文件夹，网页版返回 400 提示用桌面版）+「📂打开文件夹」。新设置项 `audio_dir`（空=默认 audio_output）；`current_audio_dir()` 统一取有效目录（不可写则退默认）；settings GET 附 `audio_dir_effective` 给前端显示
  - **朗读/试听不落盘，点下载才存**（用户嫌试听 mp3 堆满文件夹）：`/api/tts` 改成生成到临时文件→读字节→删临时文件→`Response(mimetype=audio/mpeg)` 流回前端 blob 播放，**不在语音文件夹留任何文件**；新 `/api/save-tts` 才真正存到 `current_audio_dir()`；前端 `playTts()` blob 播放+`lastTts` 记参数，点「⬇️下载 MP3」调 save-tts。删了旧 `/audio/<fname>` 路由（不再有持久 url）
  - **语音输入**：实测确认——网页版浏览器按钮在（内核有 webkitSpeechRecognition），但识别靠浏览器在线服务需联网+麦克风+连得上（Chrome 走谷歌国内要 VPN，Edge 走微软一般可用），"说话出字"无法自动化测需用户本人试；桌面版 WebView2 服务不通（坑#3），用户决定**保持现状**（点了失败才隐藏+提示一次），不改
- ✅ v1.2 文档翻译页签（2026-06-15）：新页签「📄 文档翻译」，桌面版用系统对话框选文件(多选)/文件夹(自动列出支持的文档)，翻 txt/docx/xlsx/pdf，**翻译后在原文件旁生成带语言后缀的新文件**（报告.docx→报告_en.docx）；pdf 抠文字另存 .docx（保不住排版）。核心模块 `doc_translate.py`；接口 `/api/doc-pick`(选文件，网页版无真实路径故返回400)、`/api/doc-translate`(批量翻，复用 translate_lines)；前端逐文件翻译(进度可见)、换语言可重译(记 doneTarget)。translate_lines 改返回 `(译文列表, 没翻成行数)`——调用方 app.py:544(snip)、doc_translate 都已适配。经多智能体审查(workflow)+对抗验证修了6个真问题，全部单元/端到端/打包后实测通过。
  - **依赖**(已装进 venv，pip 缓存 D:\pip-cache)：`python-docx`(Word)、`openpyxl`(Excel)、`pypdf`(PDF抠字)+连带 lxml/et_xmlfile。openpyxl/pypdf 纯 py 无需 spec datas。
  - **spec 硬要求**：必须 `collect_data_files('docx')`（已加），否则打包后建/存 Word（含 pdf→docx）报 FileNotFoundError 缺 templates/default.docx（同 rapidocr 坑）。验证：`dir dist\TranslationTool\_internal\docx\templates\default.docx`。
  - **防"假翻译"**(最重要)：断网/限流时 translate_lines 会静默把原文当译文退回，旧逻辑会生成一份"✓成功"但没翻的文件。现在 translate_lines 回报"没翻成行数"，doc_translate **整篇全没翻成→报错删半成品(不留假文件)，部分没翻成→保留但前端黄色警告**(⚠ N段没翻成)。
  - **已知局限**：docx 含超链接的段落翻译后会丢链接(保译文文字、不重复损坏)；页眉页脚/文本框/图片里的文字翻不到；xlsx 跳过公式不翻；pdf 扫描件(图片)无文字会提示用截图翻译。
- 💤 阶段 5 可选：300+ 全量声音列表、翻译历史、桌面版语音输入替代方案（Vosk/whisper）、副屏截图支持等

## 发布版（发给别人，2026-06-15）
- 交付物在 `安装包\`：**翻译语音小工具-安装包.exe**（75MB，发给别人的）+ **安装说明-请先看我.html**（给收件人的图文指引，无本机路径）。两个一起发。
- 发布版配置 `installer\setup_release.iss`（独立 AppId B2E8A4F1，不碰开发版 8C1E7A52）：DefaultDirName={autopf}（lowest→落用户 LocalAppData\Programs，可写）；带 WebView2 在线引导器兜底（dontcopy+ExtractTemporaryFile，ssPostInstall 检测注册表缺失则静默装，SW_HIDE+失败弹中文提示）；[UninstallDelete] 清 audio_output/webview_data/settings.json/snip_*.png + {localappdata}\TranslationTool；[Registry] uninsdeletevalue 清自启项；InitializeSetup 挡 32 位给中文提示。编译：`cd installer; "..\tools\Inno Setup 6\ISCC.exe" /Q setup_release.iss`（中文 iss 必须 UTF-8 BOM）。
- 已用 /DIR 全新装到 D 盘临时目录端到端实测：装上→桌面图标→必应翻译（无VPN）→TTS→卸载零残留，全通过。
- ✅ 升级自动卸载旧版（2026-06-15）：setup_release.iss [Code] 加 `PrepareToInstall`——装前读注册表同 AppId（B2E8A4F1）的 `..._is1\UninstallString`（先 HKCU 后 HKLM），`/VERYSILENT /NORESTART /SUPPRESSMSGBOXES` 静默卸载旧版、Sleep 1.5s 等收尾，再装新版，旧文件不残留。实测确认生效（装旧版→在 {app}\audio_output 放 mytest.mp3→再装新版→mytest.mp3 被 [UninstallDelete] 清掉=卸载真的跑了）。⚠ 副作用：卸载旧版会触发 [UninstallDelete] 连带清掉旧版 settings.json + audio_output（用户设置和已生成的语音），升级后是全新状态——在乎语音的要先备份。⚠ 只认同 AppId（用发布版安装包装的）旧版；开发版(8C1E7A52)/手动复制的文件夹识别不到、不会被动。注册表里硬编码的 GUID 必须和 [Setup] AppId 一致，改 AppId 要同步改 [Code] 两处。
- ⚠ WebView2 用的是在线引导器（需联网补装），绝大多数 Win10/11 自带不触发；若要支持完全离线机器需换 150MB 离线运行时包（用户未要求，暂不做）。
- ⚠ 别把项目里的 使用说明.txt 发给别人（含本机 E:\ 路径）；发 HTML 那个。未签名→对方首次有 SmartScreen/杀软提示，HTML 里已教怎么过。

## 一键打包（2026-06-15，首选）
- **双击 `一键打包.bat`**：检查环境→可选改版本号→py_compile 语法检查→关进程→PyInstaller→ISCC 编译发布版安装包，全程中文进度，完成自动打开 安装包 文件夹。
- 逻辑在 `build.ps1`（必须 UTF-8 **BOM**，否则 PS 5.1 中文乱码）。无人值守：`powershell -File build.ps1 -Yes`；改版本：加 `-Version 1.3.0`。
- 本机自己用的版本（`安装好的程序\`，开发版 AppId 8C1E7A52）更新法：`Copy-Item dist\TranslationTool\* 安装好的程序\ -Recurse -Force`（dist 不含 audio_output/webview_data/settings.json，不会动你的数据）。
- ⚠ **wordninja 打包坑（2026-06-15 修复）**：wordninja 2.0.0 = 单文件 wordninja.py + 同目录 wordninja\wordninja_words.txt.gz 词库，import 时即加载词库。collect_data_files 收不到（warning「not a package」）→ 打包版 import wordninja 直接 FileNotFoundError、fix_spaces 静默退化（英文不拆词、之前一直没发现）。spec 已显式打词库到 wordninja\ 子目录。验证：`python -c "import sys;sys.path.insert(0,r'dist\TranslationTool\_internal');import wordninja;print(wordninja.split('Settingsandprivacy'))"`。

## 旧构建命令（手动，一键打包已涵盖）
- 重打 exe：`venv\Scripts\pyinstaller.exe --noconfirm TranslationTool.spec` → `dist\TranslationTool\`
- 重编发布版安装包：`cd installer; "..\tools\Inno Setup 6\ISCC.exe" /Q setup_release.iss` → `安装包\`
- 图标：`venv\Scripts\python.exe make_icon.py` → `app.ico`
- 测试桌面版：环境变量 `TT_PORT` 可固定端口（默认随机）

## 技术决策（2026-06-12 调研定案，勿轻易推翻）
- 桌面窗口 **pywebview**（Win11 自带 WebView2）；否决 Electron/Tauri/Flet
- 打包 **PyInstaller onedir**，禁 onefile/UPX；安装包 **Inno Setup 6.5**（装在项目 `tools\Inno Setup 6`）+ ChineseSimplified.isl（installer/ 目录内），.iss 必须 UTF-8 带 BOM
- 翻译引擎四选一（settings.engine，默认 auto）：**auto**=google_reachable() 探测（requests.head translate.google.com 2.5s 超时，结果缓存 2 分钟）谷歌优先、失败/不可达自动换必应；**bing**=自写 bing_translate.py（必应网页接口，免费免key国内直连：解析 translator 页 IG/IID/params_AbusePreventionHelper token → POST ttranslatev3，token 8 分钟自动刷新，单次 900 字分块）；google / mymemory（mymemory+auto源 退必应）。语音 edge-tts（保持最新，旧版 403）。**没 VPN 时：翻译走必应、TTS/OCR 不受影响**

## OCR 依赖（v1.1，有硬性版本要求）
- `rapidocr_onnxruntime==1.4.4`（老包老 API：`result, elapse = engine(img)`，每项 [框, 文本, 分数]；别照新包 rapidocr 2.x/3.x 的 API 写）
- **onnxruntime 必须 pin 1.20.1**：1.22+ 在 Python 3.11-3.13 上被 PyInstaller 打包后 DLL 初始化必崩（onnxruntime issue #25193），升级前先查该 issue 是否修复
- 用 `opencv-python-headless` 代替 opencv-python（省几十 MB；pip 会报 rapidocr 依赖冲突警告，无视即可）
- spec 里必须 `collect_data_files('rapidocr_onnxruntime')`，否则打包后 OCR 报 FileNotFoundError: config.yaml

## 实测踩过的坑（重要，别再踩）
1. **Flask 必须 `threaded=True`**：WebView2 会长期占住连接，单线程下其他请求全被堵死（连接被重置）
2. **探测本地服务只能用纯 TCP（socket.create_connection），不能用 urllib/HTTP 库**：用户开着系统代理，127.0.0.1 的 HTTP 请求会被代理劫持（502/重置）
3. **WebView2 有 webkitSpeechRecognition 构造器但服务不可用**：桌面版语音输入会静默失败，已在 onerror 里处理（network/service-not-allowed → 隐藏按钮并提示一次）
4. 沙箱里起的本地端口会留拦截残留，测试时换新端口；GUI exe 用 PowerShell 启动会立即返回（detached），验证靠接口探测 + 截图
4b. **PowerShell 管道往 python stdin 传中文会全变问号**：含中文的测试脚本要用 Write 工具写成 UTF-8 .py 文件再跑，别用 heredoc 管道
4d. **打包反复打出损坏的安装包（点开报 "The setup files are corrupted"）的真凶 = 上次双击运行过的安装程序进程没退出、锁着输出 exe（2026-06-15）**：用户双击 `安装包\翻译语音小工具-安装包.exe`，报 corrupted 后点确定，那个安装程序进程（名字就叫"翻译语音小工具-安装包"）常卡在后台不退出，独占锁住这个 exe 文件。下次打包 ISCC 要覆盖写它时 `Error 32: 另一个程序正在使用此文件` → 要么中止、要么只写一半 → 又是损坏包 → 再点开还 corrupted → 死循环。dist 是好的（227MB 完整）、磁盘空间够、跟杀毒软件无关（一度误判成杀软，其实是文件占用）。判断技巧：好包压缩约 42 秒/75MB，坏包十几秒/36MB。修法：`build.ps1` Step5 编译前已加——先 `Stop-Process` 杀掉占用输出 exe 的进程（按 Path 匹配 + 按进程名匹配）、删掉旧包（删不掉=仍被占用就 `Die` 提示用户先关安装程序窗口），再 ISCC；编译后还有"成品 <60MB 报警"双保险。
4c. **.bat 含中文必须存 GBK/ANSI 编码，不能 UTF-8（2026-06-15 修 `启动翻译工具.bat` 双击起不来）**：cmd.exe 在中文 Windows 下按 GBK 读 bat，UTF-8 无 BOM 的中文行（如 `title 翻译·语音小工具`）末字节会在 GBK 下吃掉行尾 `\r`，把下一行 `cd /d "%~dp0"` 并进上一行 → cd 不执行 → cwd 不对 → `venv\Scripts\python.exe app.py` 相对路径找不到 → 闪退/起不来。修法：bat 用 GBK 编码（python `open(...,encoding="gbk",newline="\r\n")` 写最稳），并去掉 `chcp 65001`（GBK 文件配 936 控制台中文正常，chcp 65001 反而让 echo 中文乱码）。注意：`.bat` 用 GBK，`.ps1`/`.iss` 仍要 UTF-8 BOM（PS 5.1/Inno）——别搞混。`一键打包.bat` 是纯 ASCII 不受影响。
5. `--noconsole` 下 stdout/stderr 兜底要带 `encoding="utf-8"`；TTS 文件名带 uuid 防并发碰撞；写文件前 makedirs 兜底
6. **项目相关一切只放项目目录下（用户强要求，2026-06-12 两次强调，"记住"）**：装好的程序在 `安装好的程序\`、工具在 `tools\`、MP3 在 exe 同目录 audio_output、webview 缓存经 `webview.start(storage_path=...)` 指到 exe 同目录 webview_data。仅当 exe 目录不可写才退 `%LOCALAPPDATA%`。绝不把数据写到 C 盘 AppData、不把东西装到项目外

## 运行 / 调试
- 网页版：`venv\Scripts\python.exe app.py` → http://127.0.0.1:8765
- 桌面版（源码）：`venv\Scripts\python.exe desktop.py`
- 接口：`POST /api/translate` {text, source, target}；`POST /api/tts` {text, voice, rate}；`POST /api/open-audio-dir`
- 依赖在项目 venv；pip 缓存指 `D:\pip-cache`

## 用户约定
- 非技术用户：回复永远用简体中文大白话，术语要跟通俗解释
- 安装落盘默认 D/E 盘，严禁随意写 C 盘；装东西前先报完整路径
