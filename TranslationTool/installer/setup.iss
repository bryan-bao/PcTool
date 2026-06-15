; 翻译·语音小工具 安装包配置（Inno Setup 6.5+）
; 编译方法: "E:\chao-tool\TranslationTool\tools\Inno Setup 6\ISCC.exe" setup.iss

[Setup]
AppId={{8C1E7A52-4B3D-4F69-9D2A-6E5F31C0A9B4}
AppName=翻译·语音小工具
AppVersion=1.1.0
AppPublisher=Chao
DefaultDirName={autopf}\翻译·语音小工具
DefaultGroupName=翻译·语音小工具
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\安装包
OutputBaseFilename=翻译语音小工具-安装包-v1.1-可分发
SetupIconFile=..\app.ico
UninstallDisplayIcon={app}\TranslationTool.exe
UninstallDisplayName=翻译·语音小工具
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
DisableProgramGroupPage=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\dist\TranslationTool\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\翻译·语音小工具"; Filename: "{app}\TranslationTool.exe"
Name: "{autodesktop}\翻译·语音小工具"; Filename: "{app}\TranslationTool.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\TranslationTool.exe"; Description: "{cm:LaunchProgram,翻译·语音小工具}"; Flags: nowait postinstall skipifsilent
