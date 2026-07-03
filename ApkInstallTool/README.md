# APK 一键安装工具

Windows 图形界面工具：把 APK 拖进窗口，选择手机，点击安装，通过 ADB 自动安装到安卓手机。支持 USB 数据线和 WiFi 无线调试。

## 怎么用

- 本地快速运行：双击 `启动工具.bat`。
- 第一次启动会自动创建 `venv`、安装 `requirements.txt`，并在找不到 adb 时下载 Google 官方 platform-tools 到本地 `platform-tools/`。
- 命令行手动运行：

```powershell
py -3 -m venv venv
.\venv\Scripts\python.exe -m pip install -r requirements.txt
.\venv\Scripts\python.exe run.py
```

## 打包成 exe

双击 `打包成exe.bat`。脚本会先准备 Python 依赖和 adb，再用 PyInstaller 打包。

产物在 `dist\APKInstallTool`，把整个文件夹发给别人，双击里面的 `APKInstallTool.exe` 即可运行。

## ADB

源码仓库不提交 `adb.exe` 和 dll。启动脚本会优先使用 `platform-tools/adb.exe`，没有时使用系统 PATH 里的 adb；两者都没有时，会下载官方 Android SDK Platform-Tools for Windows 并复制 `adb.exe`、`AdbWinApi.dll`、`AdbWinUsbApi.dll` 到 `platform-tools/`。

设计文档见 `docs/superpowers/specs/2026-06-09-apk-installer-design.md`。