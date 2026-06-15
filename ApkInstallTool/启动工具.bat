@echo off
chcp 65001 >nul
rem 双击运行 APK 一键安装工具(需要本机已装 Python)
cd /d "%~dp0"
start "" pythonw run.py
