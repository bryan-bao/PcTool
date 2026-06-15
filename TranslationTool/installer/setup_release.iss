; 翻译·语音小工具 —— 发布版安装包（专门用来发给别人）
; 和开发版用不同的 AppId，互不干扰；装到对方自己的用户目录，免管理员、免 VPN
; 编译: "E:\chao-tool\TranslationTool\tools\Inno Setup 6\ISCC.exe" setup_release.iss

#define MyName "翻译·语音小工具"
#define MyVersion "1.2.0"

[Setup]
AppId={{B2E8A4F1-9C73-4D2A-A6E5-1F8B3C7D9E04}
AppName={#MyName}
AppVersion={#MyVersion}
AppVerName={#MyName} {#MyVersion}
AppPublisher=Chao
DefaultDirName={autopf}\{#MyName}
DefaultGroupName={#MyName}
; lowest = 普通用户即可安装，不弹管理员授权框，自动装到用户自己的程序目录
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
DisableDirPage=auto
OutputDir=..\安装包
OutputBaseFilename=翻译语音小工具-安装包
SetupIconFile=..\app.ico
UninstallDisplayIcon={app}\TranslationTool.exe
UninstallDisplayName={#MyName}
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
WizardStyle=modern
; 安装向导里给一句友好提示
DisableWelcomePage=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
; 桌面图标默认勾选（发给别人，装完桌面就有图标）
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\dist\TranslationTool\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; WebView2 引导安装器：打进包里但不释放到安装目录，只在需要时临时解压
Source: "MicrosoftEdgeWebview2Setup.exe"; Flags: dontcopy

[Icons]
Name: "{group}\{#MyName}"; Filename: "{app}\TranslationTool.exe"
Name: "{group}\卸载 {#MyName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyName}"; Filename: "{app}\TranslationTool.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\TranslationTool.exe"; Description: "{cm:LaunchProgram,{#MyName}}"; Flags: nowait postinstall skipifsilent

; 卸载时一并清掉程序运行后才生成的东西，不留垃圾
[UninstallDelete]
Type: filesandordirs; Name: "{app}\audio_output"
Type: filesandordirs; Name: "{app}\webview_data"
Type: files; Name: "{app}\settings.json"
Type: files; Name: "{app}\snip_*.png"
Type: filesandordirs; Name: "{localappdata}\TranslationTool"

; 卸载时清掉开机自启注册表项（程序运行时才写入，安装时不创建）
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "TranslationTool"; Flags: dontcreatekey uninsdeletevalue

[Code]
{ —— 检测系统是否已装 Edge WebView2 运行时（界面要靠它显示，缺了会白屏）—— }
function WebView2Installed: Boolean;
var v: String;
begin
  Result := False;
  if RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', v) and (v <> '') and (v <> '0.0.0.0') then
    Result := True
  else if RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', v) and (v <> '') and (v <> '0.0.0.0') then
    Result := True
  else if RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', v) and (v <> '') and (v <> '0.0.0.0') then
    Result := True;
end;

{ —— 只支持 64 位 Windows，32 位系统给个看得懂的中文提示再退出 —— }
function InitializeSetup: Boolean;
begin
  Result := True;
  if not IsWin64 then
  begin
    MsgBox('本程序仅支持 64 位 Windows，您当前的系统是 32 位，无法安装。', mbCriticalError, MB_OK);
    Result := False;
  end;
end;

{ —— 读取已装旧版本的卸载命令（同一个 AppId 才算同一个程序）—— }
function GetOldUninstallString(): String;
var s: String;
begin
  s := '';
  { 注意：下面两处大括号里的 GUID 必须和最上面 [Setup] 的 AppId 完全一致；
    以后若改了 AppId，这里也要同步改，否则识别不到旧版本。}
  if not RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{B2E8A4F1-9C73-4D2A-A6E5-1F8B3C7D9E04}_is1', 'UninstallString', s) then
    RegQueryStringValue(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{B2E8A4F1-9C73-4D2A-A6E5-1F8B3C7D9E04}_is1', 'UninstallString', s);
  Result := s;
end;

{ —— 真正开始复制文件前：先把旧版本静默卸载掉，保证干净覆盖、不留旧文件 —— }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  sUnInst: String;
  iCode: Integer;
begin
  Result := '';
  sUnInst := GetOldUninstallString();
  if sUnInst <> '' then
  begin
    WizardForm.StatusLabel.Caption := '检测到旧版本，正在卸载清理，请稍候…';
    sUnInst := RemoveQuotes(sUnInst);
    if Exec(sUnInst, '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES', '', SW_HIDE, ewWaitUntilTerminated, iCode) then
      Sleep(1500);  { 卸载程序会把自己复制到临时目录后台运行，稍等它收尾再继续装 }
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    if not WebView2Installed then
    begin
      { 缺运行时：临时解压微软官方引导器，静默补装（约 2MB，需联网）。隐藏黑框、装完复查、失败给中文提示 }
      WizardForm.StatusLabel.Caption := '正在配置界面组件 WebView2（需要联网，请稍候）…';
      ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
      if (not Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or (not WebView2Installed) then
      begin
        MsgBox('显示界面所需的组件 WebView2 没能装上（通常是安装时没联网）。' + #13#10#13#10 +
               '软件本身已安装完成，但首次打开如果是空白窗口，请按下面任一方式处理：' + #13#10 +
               '① 连接网络后，重新运行一次本安装包；或' + #13#10 +
               '② 到微软官网搜索 “WebView2 Runtime” 手动下载安装。', mbInformation, MB_OK);
      end;
    end;
  end;
end;
