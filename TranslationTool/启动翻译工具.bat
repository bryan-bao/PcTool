@echo off
title 翻译·语音小工具
cd /d "%~dp0"
echo 正在启动翻译工具，稍等两秒会自动打开浏览器……
start "" /min cmd /c "timeout /t 2 >nul & start http://127.0.0.1:8765"
venv\Scripts\python.exe app.py
echo.
echo 程序已退出。如果是刚双击就闪到这里，说明启动出错了，请把上面的提示截图。
pause
