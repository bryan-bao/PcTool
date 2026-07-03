# TranslationTool

Windows translation, screenshot OCR, selected-text translation, TTS, and document translation tool.

## Run From Source

1. Install Python 3.11+.
2. Double-click `启动翻译工具.bat`.

On first run, the script creates `venv`, installs `requirements.txt`, starts the local server, and opens the browser.

Manual commands:

```powershell
py -3 -m venv venv
.\venv\Scripts\python.exe -m pip install -r requirements.txt
.\venv\Scripts\python.exe app.py
```

Desktop entry:

```powershell
.\venv\Scripts\python.exe desktop.py
```

## Build

1. Install Python 3.11+.
2. Install Inno Setup 6, or let `build.ps1` install it with `winget`.
3. Double-click `一键打包.bat`, or run:

```powershell
.\build.ps1 -Yes
```

`TranslationTool.spec` is tracked. Build output, installers, `venv`, logs, uploads, and installed-program folders are intentionally ignored.
