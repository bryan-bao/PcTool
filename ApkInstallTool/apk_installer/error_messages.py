"""把 ADB 的英文输出/错误码翻译成中文大白话。"""

# 已知错误码 -> 中文提示
_KNOWN = {
    "INSTALL_FAILED_UPDATE_INCOMPATIBLE": "签名不一致:手机上已装的同款应用签名不同,请先在手机上卸载旧版本再装。",
    "INSTALL_FAILED_VERSION_DOWNGRADE": "不能安装更低版本:手机上已装的版本更高,请先卸载旧版本。",
    "INSTALL_FAILED_INSUFFICIENT_STORAGE": "手机存储空间不足,清理后再试。",
    "INSTALL_FAILED_ALREADY_EXISTS": "应用已存在:可勾选覆盖安装后重试。",
    "INSTALL_FAILED_INVALID_APK": "这个 APK 文件无效或已损坏。",
    "INSTALL_FAILED_NO_MATCHING_ABIS": "这个 APK 不支持当前手机的 CPU 架构。",
}


def translate(raw: str) -> str:
    """输入 adb 原始输出,返回一句中文提示。"""
    text = (raw or "").strip()
    low = text.lower()

    if "success" in low:
        return "安装成功"
    if "no devices" in low or "no devices/emulators found" in low:
        return "没有检测到设备:请检查数据线/无线连接,并确认手机已开启调试。"
    if "unauthorized" in low:
        return "设备未授权:请在手机屏幕上点击「允许此电脑调试」后重试。"
    if "device offline" in low or "offline" in low:
        return "设备离线:请重新插拔数据线或重新连接 WiFi 调试。"

    for code, msg in _KNOWN.items():
        if code in text:
            return msg

    # 未知失败:给通用提示,但保留原始信息便于排查
    if "failure" in low or "error" in low or "failed" in low:
        return f"安装失败。原始信息:{text}"
    return text or "未知结果"
