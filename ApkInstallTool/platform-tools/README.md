# 放置 adb.exe

从 Google 官方下载 Android SDK Platform-Tools(Windows 版):
https://developer.android.com/tools/releases/platform-tools

解压后,把 `adb.exe`、`AdbWinApi.dll`、`AdbWinUsbApi.dll` 这三个文件放到本目录下。
程序会优先使用这里的 adb;找不到才回退系统 PATH 里的 adb。
