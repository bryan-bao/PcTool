"""封装所有 ADB 调用,返回结构化结果。不依赖界面代码。"""

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from apk_installer.error_messages import translate

# 随附的 adb.exe 路径:相对本文件所在包的上一级 platform-tools/
_BUNDLED_ADB = Path(__file__).resolve().parent.parent / "platform-tools" / "adb.exe"


@dataclass
class Device:
    serial: str
    model: str
    status: str  # "device" / "unauthorized" / "offline"


@dataclass
class AdbResult:
    ok: bool
    message: str  # 已翻译成中文的提示
    raw: str      # 原始输出,便于排查


@dataclass
class WifiDiscoveryResult:
    discovered: list[str]
    connected: list[str]
    failed: list[str]
    raw: str


def find_adb() -> str:
    """优先用随附的 adb.exe,找不到就回退系统 PATH 中的 'adb'。"""
    if _BUNDLED_ADB.exists():
        return str(_BUNDLED_ADB)
    return "adb"


def _run(args: list[str], timeout: int = 120) -> tuple[int, str, str]:
    """执行 adb 命令,返回 (返回码, stdout, stderr)。args 不含 adb 本身。"""
    cmd = [find_adb()] + args
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),  # Windows 下不弹黑框
    )
    return proc.returncode, proc.stdout or "", proc.stderr or ""


def _getprop(serial: str, prop: str) -> str:
    rc, out, _ = _run(["-s", serial, "shell", "getprop", prop], timeout=10)
    return out.strip() if rc == 0 else ""


def _get_device_model(serial: str) -> str:
    """通过 getprop 查询设备品牌和型号。"""
    market_name = (
        _getprop(serial, "ro.product.marketname")
        or _getprop(serial, "ro.product.vendor.marketname")
        or _getprop(serial, "ro.config.marketing_name")
    )
    manufacturer = _getprop(serial, "ro.product.manufacturer")
    model = _getprop(serial, "ro.product.model")
    if market_name:
        if manufacturer and market_name.lower().startswith(manufacturer.lower()):
            return market_name
        parts = [part for part in (manufacturer, market_name) if part]
        return " ".join(dict.fromkeys(parts))
    parts = [part for part in (manufacturer, model) if part]
    return " ".join(parts)


def list_devices() -> list[Device]:
    """返回当前已连接设备列表。"""
    _, out, _ = _run(["devices", "-l"])
    devices: list[Device] = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("List of devices"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        serial, status = parts[0], parts[1]
        model = "(未授权)" if status == "unauthorized" else "(未知型号)"
        for token in parts[2:]:
            if token.startswith("model:"):
                model = token.split(":", 1)[1]
                break
        if status == "device":
            model = _get_device_model(serial) or model
        devices.append(Device(serial=serial, model=model, status=status))
    return devices


def discover_wifi_targets() -> tuple[list[str], str]:
    """通过 ADB mDNS 发现可直接连接的无线调试地址。"""
    _, out, err = _run(["mdns", "services"], timeout=15)
    raw = (out + "\n" + err).strip()
    targets: list[str] = []
    for line in raw.splitlines():
        if "_adb-tls-connect._tcp" not in line and "_adb._tcp" not in line:
            continue
        match = re.search(r"((?:\d{1,3}\.){3}\d{1,3}:\d+|\[[0-9a-fA-F:]+\]:\d+)$", line.strip())
        if match:
            target = match.group(1)
            if target not in targets:
                targets.append(target)
    return targets, raw


def connect_discovered_wifi_devices() -> WifiDiscoveryResult:
    """连接当前局域网内已配对且可通过 ADB mDNS 发现的无线调试设备。"""
    targets, raw = discover_wifi_targets()
    connected: list[str] = []
    failed: list[str] = []
    for target in targets:
        rc, out, err = _run(["connect", target], timeout=20)
        result = (out + "\n" + err).strip()
        low = result.lower()
        if rc == 0 and ("connected" in low or "already connected" in low) and "cannot" not in low:
            connected.append(target)
        else:
            failed.append(target)
    return WifiDiscoveryResult(discovered=targets, connected=connected, failed=failed, raw=raw)


def install_apk(serial: str, apk_path: str) -> AdbResult:
    """在指定设备上安装(覆盖安装)APK。"""
    code, out, err = _run(["-s", serial, "install", "-r", apk_path])
    raw = (out + "\n" + err).strip()
    message = translate(raw)
    ok = code == 0 and "success" in raw.lower()
    return AdbResult(ok=ok, message=message, raw=raw)


def pair_wifi(host: str, port: str, code: str) -> AdbResult:
    """安卓 11+ 无线调试配对。"""
    rc, out, err = _run(["pair", f"{host}:{port}", code])
    raw = (out + "\n" + err).strip()
    if rc == 0 and "success" in raw.lower():
        return AdbResult(ok=True, message="配对成功", raw=raw)
    return AdbResult(ok=False, message=f"配对失败:请核对 IP、端口和配对码。原始信息:{raw}", raw=raw)


def connect_wifi(host: str, port: str) -> AdbResult:
    """连接已配对的无线调试设备。"""
    rc, out, err = _run(["connect", f"{host}:{port}"])
    raw = (out + "\n" + err).strip()
    if rc == 0 and "connected" in raw.lower() and "cannot" not in raw.lower():
        return AdbResult(ok=True, message="连接成功", raw=raw)
    return AdbResult(ok=False, message=f"连接失败:请确认手机已开启无线调试且在同一 WiFi。原始信息:{raw}", raw=raw)
