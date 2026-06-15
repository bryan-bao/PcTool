@echo off
chcp 65001 >nul
rem 一键把工具打包成独立 exe(自带 adb,发给别人双击即用,无需装 Python)
cd /d "%~dp0"

echo [1/2] 安装/检查 PyInstaller ...
python -m pip install pyinstaller >nul 2>&1

echo [2/2] 开始打包 ...
python -m PyInstaller --noconfirm --clean --windowed ^
  --name "APK一键安装工具" ^
  --add-data "platform-tools;platform-tools" ^
  run.py

echo.
echo 打包完成!成品在 dist\APK一键安装工具\ 文件夹里。
echo 把整个 "APK一键安装工具" 文件夹拷给别人,双击里面的 exe 即可运行。
pause
