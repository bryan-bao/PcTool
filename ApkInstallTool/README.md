# APK 一键安装工具

Windows 图形界面工具:把 APK 拖进窗口,选好手机,点一下,通过 ADB 自动安装到安卓手机。
支持 USB 数据线 和 WiFi 无线调试两种连接方式。

## 怎么用

- **本地快速运行**:双击 `启动工具.bat`(需本机装了 Python)。或命令行:
  ```
  pip install -r requirements.txt
  python run.py
  ```
- **打包成 exe 发给别人**:双击 `打包成exe.bat`,完成后成品在 `dist\APK一键安装工具\` 里。
  把整个文件夹拷给别人,双击里面的 `APK一键安装工具.exe` 即可运行——**别人不用装 Python,也不用装 adb**(adb 已打包进去)。

设计文档见 `docs/superpowers/specs/2026-06-09-apk-installer-design.md`。

## 随附 adb(给别人用时建议)

把官方 `adb.exe` 和两个 dll 放进 `platform-tools/` 目录(详见 `platform-tools/README.md`)。
程序会优先用这里的 adb,这样别人不用自己装 adb 也能跑。开发期没放也行,会自动用系统 PATH 里的 adb。

## 打包成 exe(可选)

```
pip install pyinstaller
pyinstaller --noconfirm --windowed --name APK安装工具 --add-data "platform-tools;platform-tools" run.py
```

打包产物在 `dist/APK安装工具/` 下,整个文件夹拷给别人即可双击运行,无需装 Python。
