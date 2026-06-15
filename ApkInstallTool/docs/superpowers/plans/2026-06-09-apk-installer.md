# APK 一键安装工具 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做一个 Windows 图形界面工具,把 APK 拖进去、选好手机、点一下,通过 ADB 自动把包推送到安卓手机并安装好(支持 USB 和 WiFi 两种连接)。

**Architecture:** 分四个模块——`adb_wrapper`(封装所有 ADB 调用,纯逻辑、可单测)、`error_messages`(把 ADB 错误翻译成中文大白话)、`ui`(CustomTkinter 界面)、`main`(入口)。界面只负责展示和收集输入,干活都委托给 `adb_wrapper`;所有 ADB 命令在后台线程跑,避免界面卡死。

**Tech Stack:** Python 3.12、CustomTkinter(界面)、tkinterdnd2(拖拽)、ADB(随程序打包 adb.exe)、pytest(测试)。开发期可用系统已安装的 adb。

---

## 文件结构

```
FileTransferTools/
├── apk_installer/
│   ├── __init__.py
│   ├── adb_wrapper.py       # 找 adb、列设备、配对、连接、安装;返回结构化结果
│   ├── error_messages.py    # 把 adb 输出/错误码翻译成中文提示
│   ├── ui.py                # CustomTkinter 主窗口
│   └── main.py              # 程序入口
├── tests/
│   ├── __init__.py
│   ├── test_error_messages.py
│   └── test_adb_wrapper.py
├── platform-tools/          # (后续放入随附的 adb.exe,见 Task 8)
├── requirements.txt
├── run.py                   # 双击/命令启动入口
└── README.md
```

**职责边界:**
- `adb_wrapper` 不 import 任何界面代码;所有外部命令通过一个内部 `_run()` 函数走 `subprocess`,方便测试时 mock。
- `error_messages` 是纯函数,输入字符串、输出字符串,零依赖。
- `ui` 只依赖 `adb_wrapper`,通过后台线程调用,用 `queue` + `after()` 把结果安全地刷回界面。

---

### Task 1: 项目骨架与依赖

**Files:**
- Create: `requirements.txt`
- Create: `apk_installer/__init__.py`
- Create: `tests/__init__.py`
- Create: `README.md`

- [ ] **Step 1: 写 requirements.txt**

```
customtkinter>=5.2.0
tkinterdnd2>=0.4.0
pytest>=8.0.0
```

- [ ] **Step 2: 建包占位文件**

`apk_installer/__init__.py`(内容):

```python
"""APK 一键安装工具。"""
```

`tests/__init__.py`(留空文件即可)。

- [ ] **Step 3: 写 README.md**

```markdown
# APK 一键安装工具

Windows 图形界面工具:把 APK 拖进窗口,选好手机,点一下,通过 ADB 自动安装到安卓手机。
支持 USB 数据线 和 WiFi 无线调试两种连接方式。

## 运行(开发期)
```
pip install -r requirements.txt
python run.py
```

设计文档见 `docs/superpowers/specs/2026-06-09-apk-installer-design.md`。
```

- [ ] **Step 4: 安装依赖并确认 pytest 可用**

Run: `pip install -r requirements.txt; python -m pytest --version`
Expected: 打印出 pytest 版本号(如 `pytest 8.x.x`),无报错。

- [ ] **Step 5: Commit**

```bash
git add requirements.txt apk_installer/__init__.py tests/__init__.py README.md
git commit -m "chore: 初始化 APK 安装工具项目骨架"
```

---

### Task 2: error_messages 模块(翻译错误为中文)

**Files:**
- Create: `apk_installer/error_messages.py`
- Test: `tests/test_error_messages.py`

- [ ] **Step 1: 写失败测试**

`tests/test_error_messages.py`:

```python
from apk_installer.error_messages import translate


def test_success():
    assert translate("Performing Streamed Install\nSuccess") == "安装成功"


def test_signature_conflict():
    raw = "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: ...]"
    msg = translate(raw)
    assert "签名" in msg
    assert "卸载" in msg


def test_version_downgrade():
    raw = "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]"
    assert "低版本" in translate(raw)


def test_no_device():
    raw = "adb: no devices/emulators found"
    assert "没有检测到设备" in translate(raw)


def test_unauthorized():
    raw = "adb: device unauthorized."
    assert "授权" in translate(raw)


def test_unknown_failure_keeps_raw():
    raw = "Failure [INSTALL_FAILED_SOMETHING_NEW]"
    msg = translate(raw)
    assert "安装失败" in msg
    assert "INSTALL_FAILED_SOMETHING_NEW" in msg
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m pytest tests/test_error_messages.py -v`
Expected: FAIL,报 `ModuleNotFoundError: No module named 'apk_installer.error_messages'`

- [ ] **Step 3: 写实现**

`apk_installer/error_messages.py`:

```python
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `python -m pytest tests/test_error_messages.py -v`
Expected: PASS,6 个测试全过。

- [ ] **Step 5: Commit**

```bash
git add apk_installer/error_messages.py tests/test_error_messages.py
git commit -m "feat: 新增错误信息中文翻译模块"
```

---

### Task 3: adb_wrapper —— 找 adb 与列设备

**Files:**
- Create: `apk_installer/adb_wrapper.py`
- Test: `tests/test_adb_wrapper.py`

- [ ] **Step 1: 写失败测试**

`tests/test_adb_wrapper.py`:

```python
from unittest.mock import patch
from apk_installer import adb_wrapper
from apk_installer.adb_wrapper import Device


def test_find_adb_prefers_bundled(tmp_path, monkeypatch):
    # 模拟存在随附的 platform-tools/adb.exe
    bundled = tmp_path / "platform-tools"
    bundled.mkdir()
    exe = bundled / "adb.exe"
    exe.write_text("")
    monkeypatch.setattr(adb_wrapper, "_BUNDLED_ADB", exe)
    assert adb_wrapper.find_adb() == str(exe)


def test_find_adb_falls_back_to_path(monkeypatch):
    # 随附的不存在时,回退到 "adb"
    missing = adb_wrapper.Path("does/not/exist/adb.exe")
    monkeypatch.setattr(adb_wrapper, "_BUNDLED_ADB", missing)
    assert adb_wrapper.find_adb() == "adb"


def test_list_devices_parses_output():
    sample = (
        "List of devices attached\n"
        "ABC123    device product:p model:Pixel_5 device:d\n"
        "XYZ789    unauthorized\n"
        "\n"
    )
    with patch.object(adb_wrapper, "_run", return_value=(0, sample, "")):
        devices = adb_wrapper.list_devices()
    assert devices == [
        Device(serial="ABC123", model="Pixel_5", status="device"),
        Device(serial="XYZ789", model="(未授权)", status="unauthorized"),
    ]


def test_list_devices_empty():
    with patch.object(adb_wrapper, "_run", return_value=(0, "List of devices attached\n\n", "")):
        assert adb_wrapper.list_devices() == []
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m pytest tests/test_adb_wrapper.py -v`
Expected: FAIL,报 `ModuleNotFoundError` 或属性不存在。

- [ ] **Step 3: 写实现**

`apk_installer/adb_wrapper.py`:

```python
"""封装所有 ADB 调用,返回结构化结果。不依赖界面代码。"""

import subprocess
from dataclasses import dataclass
from pathlib import Path

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
        devices.append(Device(serial=serial, model=model, status=status))
    return devices
```

- [ ] **Step 4: 运行测试确认通过**

Run: `python -m pytest tests/test_adb_wrapper.py -v`
Expected: PASS,4 个测试全过。

- [ ] **Step 5: Commit**

```bash
git add apk_installer/adb_wrapper.py tests/test_adb_wrapper.py
git commit -m "feat: adb_wrapper 支持查找 adb 与列出设备"
```

---

### Task 4: adb_wrapper —— 安装 APK

**Files:**
- Modify: `apk_installer/adb_wrapper.py`
- Test: `tests/test_adb_wrapper.py`(追加)

- [ ] **Step 1: 追加失败测试**

在 `tests/test_adb_wrapper.py` 末尾追加:

```python
def test_install_apk_success():
    with patch.object(adb_wrapper, "_run", return_value=(0, "Performing Streamed Install\nSuccess\n", "")):
        result = adb_wrapper.install_apk("ABC123", "C:/x/app.apk")
    assert result.ok is True
    assert result.message == "安装成功"


def test_install_apk_failure_translated():
    raw = "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"
    with patch.object(adb_wrapper, "_run", return_value=(1, raw, "")):
        result = adb_wrapper.install_apk("ABC123", "C:/x/app.apk")
    assert result.ok is False
    assert "签名" in result.message


def test_install_apk_builds_correct_command():
    captured = {}

    def fake_run(args, timeout=120):
        captured["args"] = args
        return (0, "Success", "")

    with patch.object(adb_wrapper, "_run", side_effect=fake_run):
        adb_wrapper.install_apk("ABC123", "C:/x/app.apk")
    assert captured["args"] == ["-s", "ABC123", "install", "-r", "C:/x/app.apk"]
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m pytest tests/test_adb_wrapper.py -k install -v`
Expected: FAIL,`AttributeError: module ... has no attribute 'install_apk'`

- [ ] **Step 3: 写实现**

在 `apk_installer/adb_wrapper.py` 顶部 import 区加上:

```python
from apk_installer.error_messages import translate
```

在文件末尾追加:

```python
def install_apk(serial: str, apk_path: str) -> AdbResult:
    """在指定设备上安装(覆盖安装)APK。"""
    code, out, err = _run(["-s", serial, "install", "-r", apk_path])
    raw = (out + "\n" + err).strip()
    message = translate(raw)
    ok = code == 0 and "success" in raw.lower()
    return AdbResult(ok=ok, message=message, raw=raw)
```

- [ ] **Step 4: 运行测试确认通过**

Run: `python -m pytest tests/test_adb_wrapper.py -v`
Expected: PASS,全部测试(含之前的)通过。

- [ ] **Step 5: Commit**

```bash
git add apk_installer/adb_wrapper.py tests/test_adb_wrapper.py
git commit -m "feat: adb_wrapper 支持安装 APK 并翻译结果"
```

---

### Task 5: adb_wrapper —— WiFi 配对与连接

**Files:**
- Modify: `apk_installer/adb_wrapper.py`
- Test: `tests/test_adb_wrapper.py`(追加)

- [ ] **Step 1: 追加失败测试**

在 `tests/test_adb_wrapper.py` 末尾追加:

```python
def test_pair_wifi_success():
    with patch.object(adb_wrapper, "_run", return_value=(0, "Successfully paired to 192.168.1.5:37000", "")):
        result = adb_wrapper.pair_wifi("192.168.1.5", "37000", "123456")
    assert result.ok is True
    assert "配对成功" in result.message


def test_pair_wifi_builds_command():
    captured = {}

    def fake_run(args, timeout=120):
        captured["args"] = args
        return (0, "Successfully paired", "")

    with patch.object(adb_wrapper, "_run", side_effect=fake_run):
        adb_wrapper.pair_wifi("192.168.1.5", "37000", "123456")
    assert captured["args"] == ["pair", "192.168.1.5:37000", "123456"]


def test_connect_wifi_success():
    with patch.object(adb_wrapper, "_run", return_value=(0, "connected to 192.168.1.5:5555", "")):
        result = adb_wrapper.connect_wifi("192.168.1.5", "5555")
    assert result.ok is True
    assert "连接成功" in result.message


def test_connect_wifi_failure():
    with patch.object(adb_wrapper, "_run", return_value=(1, "", "failed to connect to 192.168.1.5:5555")):
        result = adb_wrapper.connect_wifi("192.168.1.5", "5555")
    assert result.ok is False
    assert "连接失败" in result.message
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m pytest tests/test_adb_wrapper.py -k wifi -v`
Expected: FAIL,`AttributeError: ... 'pair_wifi'`

- [ ] **Step 3: 写实现**

在 `apk_installer/adb_wrapper.py` 末尾追加:

```python
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `python -m pytest tests/test_adb_wrapper.py -v`
Expected: PASS,全部测试通过。

- [ ] **Step 5: Commit**

```bash
git add apk_installer/adb_wrapper.py tests/test_adb_wrapper.py
git commit -m "feat: adb_wrapper 支持 WiFi 配对与连接"
```

---

### Task 6: 界面(CustomTkinter 主窗口)

> 界面交互难做自动化单测,采用「写好 + 手动冒烟测试」。逻辑都在已测过的 `adb_wrapper` 里,界面只做编排。

**Files:**
- Create: `apk_installer/ui.py`

- [ ] **Step 1: 写界面实现**

`apk_installer/ui.py`:

```python
"""CustomTkinter 主窗口:连接方式 / 设备 / 选 APK / 安装日志。"""

import queue
import threading

import customtkinter as ctk
from tkinter import filedialog

try:
    from tkinterdnd2 import DND_FILES, TkinterDnD
    _DND_OK = True
except Exception:  # 拖拽库装不上时仍可用"浏览"按钮
    _DND_OK = False

from apk_installer import adb_wrapper


class App:
    def __init__(self):
        ctk.set_appearance_mode("system")
        ctk.set_default_color_theme("blue")
        # 用 TkinterDnD 的根窗口以支持拖拽
        self.root = TkinterDnD.Tk() if _DND_OK else ctk.CTk()
        self.root.title("APK 一键安装工具")
        self.root.geometry("640x640")

        self._msg_queue: queue.Queue = queue.Queue()
        self._apk_path: str | None = None
        self._devices: list[adb_wrapper.Device] = []

        self._build_ui()
        self.root.after(100, self._drain_queue)

    # ---------- 界面搭建 ----------
    def _build_ui(self):
        # 连接方式标签页
        self.tabs = ctk.CTkTabview(self.root, height=140)
        self.tabs.pack(fill="x", padx=16, pady=(16, 8))
        self.tabs.add("USB")
        self.tabs.add("WiFi")

        ctk.CTkLabel(
            self.tabs.tab("USB"),
            text="用数据线连接手机,并开启「开发者选项 → USB 调试」,然后点下方「刷新设备」。",
            wraplength=560, justify="left",
        ).pack(anchor="w", padx=8, pady=8)

        wifi = self.tabs.tab("WiFi")
        ctk.CTkLabel(
            wifi, text="手机「开发者选项 → 无线调试」里查看 IP、端口、配对码,填入后点配对再连接。",
            wraplength=560, justify="left",
        ).pack(anchor="w", padx=8, pady=(8, 4))
        row = ctk.CTkFrame(wifi, fg_color="transparent")
        row.pack(fill="x", padx=8)
        self.ip_entry = ctk.CTkEntry(row, placeholder_text="手机 IP", width=140)
        self.pair_port_entry = ctk.CTkEntry(row, placeholder_text="配对端口", width=90)
        self.pair_code_entry = ctk.CTkEntry(row, placeholder_text="配对码", width=90)
        self.conn_port_entry = ctk.CTkEntry(row, placeholder_text="连接端口", width=90)
        for w in (self.ip_entry, self.pair_port_entry, self.pair_code_entry, self.conn_port_entry):
            w.pack(side="left", padx=3)
        ctk.CTkButton(wifi, text="配对并连接", command=self._on_wifi_connect).pack(anchor="w", padx=8, pady=6)

        # 设备区
        dev_frame = ctk.CTkFrame(self.root)
        dev_frame.pack(fill="x", padx=16, pady=8)
        ctk.CTkButton(dev_frame, text="刷新设备", command=self._on_refresh).pack(side="left", padx=8, pady=8)
        self.device_menu = ctk.CTkOptionMenu(dev_frame, values=["(未检测到设备)"], width=380)
        self.device_menu.pack(side="left", padx=8)

        # APK 选择区
        self.drop_label = ctk.CTkLabel(
            self.root,
            text="把 APK 文件拖到这里\n或点下方「浏览」选择",
            height=110,
            fg_color=("gray85", "gray25"),
            corner_radius=10,
        )
        self.drop_label.pack(fill="x", padx=16, pady=8)
        if _DND_OK:
            self.drop_label.drop_target_register(DND_FILES)
            self.drop_label.dnd_bind("<<Drop>>", self._on_drop)
        ctk.CTkButton(self.root, text="浏览…", command=self._on_browse).pack(padx=16, anchor="w")

        # 操作区
        self.install_btn = ctk.CTkButton(self.root, text="安装", height=40, command=self._on_install)
        self.install_btn.pack(fill="x", padx=16, pady=(12, 6))

        self.log_box = ctk.CTkTextbox(self.root, height=180)
        self.log_box.pack(fill="both", expand=True, padx=16, pady=(0, 16))

    # ---------- 日志与线程 ----------
    def _log(self, text: str):
        self._msg_queue.put(text)

    def _drain_queue(self):
        try:
            while True:
                text = self._msg_queue.get_nowait()
                self.log_box.insert("end", text + "\n")
                self.log_box.see("end")
        except queue.Empty:
            pass
        self.root.after(100, self._drain_queue)

    def _run_bg(self, fn):
        threading.Thread(target=fn, daemon=True).start()

    # ---------- 事件 ----------
    def _on_refresh(self):
        self._log("正在检测设备…")

        def work():
            self._devices = adb_wrapper.list_devices()
            if not self._devices:
                self._log("没检测到设备。USB:检查线和 USB 调试;WiFi:先在上方配对连接。")
                self.device_menu.configure(values=["(未检测到设备)"])
                self.device_menu.set("(未检测到设备)")
                return
            labels = [f"{d.model} [{d.serial}] ({d.status})" for d in self._devices]
            self.device_menu.configure(values=labels)
            self.device_menu.set(labels[0])
            self._log(f"检测到 {len(self._devices)} 台设备。")

        self._run_bg(work)

    def _selected_serial(self) -> str | None:
        label = self.device_menu.get()
        for d in self._devices:
            if d.serial in label:
                return d.serial
        return None

    def _on_wifi_connect(self):
        ip = self.ip_entry.get().strip()
        pport = self.pair_port_entry.get().strip()
        code = self.pair_code_entry.get().strip()
        cport = self.conn_port_entry.get().strip()
        if not (ip and cport):
            self._log("请至少填写手机 IP 和连接端口。")
            return

        def work():
            if pport and code:
                self._log("正在配对…")
                r = adb_wrapper.pair_wifi(ip, pport, code)
                self._log(r.message)
                if not r.ok:
                    return
            self._log("正在连接…")
            r = adb_wrapper.connect_wifi(ip, cport)
            self._log(r.message)
            if r.ok:
                self._on_refresh()

        self._run_bg(work)

    def _on_drop(self, event):
        path = event.data.strip().strip("{}")
        self._set_apk(path)

    def _on_browse(self):
        path = filedialog.askopenfilename(filetypes=[("APK 文件", "*.apk")])
        if path:
            self._set_apk(path)

    def _set_apk(self, path: str):
        if not path.lower().endswith(".apk"):
            self._log("这不是 .apk 文件,请重新选择。")
            return
        self._apk_path = path
        self.drop_label.configure(text=f"已选择:\n{path}")

    def _on_install(self):
        serial = self._selected_serial()
        if not serial:
            self._log("请先「刷新设备」并选择一台手机。")
            return
        if not self._apk_path:
            self._log("请先选择一个 APK 文件。")
            return
        self.install_btn.configure(state="disabled", text="安装中…")
        self._log(f"开始安装到 {serial} …")

        def work():
            r = adb_wrapper.install_apk(serial, self._apk_path)
            self._log(r.message)
            self.install_btn.configure(state="normal", text="安装")

        self._run_bg(work)

    def run(self):
        self.root.mainloop()
```

- [ ] **Step 2: 临时入口手动冒烟测试**

临时建 `run.py`(Task 7 会正式写):

```python
from apk_installer.ui import App
App().run()
```

Run: `python run.py`
Expected(手动检查清单):
- 窗口能打开,有 USB / WiFi 两个标签页。
- 点「刷新设备」:接上一台开了 USB 调试的安卓手机,设备下拉框出现该手机;不接手机则日志提示"没检测到设备"。
- 点「浏览…」选一个 .apk,拖拽区文字变成"已选择:路径"。
- 选好设备 + APK 后点「安装」,日志出现"开始安装…"且按钮变灰,完成后显示"安装成功"或中文失败原因,按钮恢复。
- 安装过程中窗口不卡死(能拖动)。

- [ ] **Step 3: Commit**

```bash
git add apk_installer/ui.py run.py
git commit -m "feat: CustomTkinter 主界面与安装流程"
```

---

### Task 7: 正式入口与依赖兜底

**Files:**
- Create/Overwrite: `run.py`
- Create: `apk_installer/main.py`

- [ ] **Step 1: 写 main 模块(带友好报错)**

`apk_installer/main.py`:

```python
"""程序入口:启动界面,缺依赖时给出中文提示。"""

import sys


def main():
    try:
        from apk_installer.ui import App
    except ModuleNotFoundError as e:
        print("缺少依赖,请先运行:pip install -r requirements.txt")
        print(f"详细:{e}")
        sys.exit(1)
    App().run()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: 写 run.py**

`run.py`(覆盖 Task 6 的临时版):

```python
from apk_installer.main import main

if __name__ == "__main__":
    main()
```

- [ ] **Step 3: 跑一遍确认能起**

Run: `python run.py`
Expected: 界面正常打开(同 Task 6 的冒烟检查)。关闭窗口即可。

- [ ] **Step 4: 跑全部单测确认没回归**

Run: `python -m pytest -v`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add run.py apk_installer/main.py
git commit -m "feat: 正式程序入口与依赖缺失提示"
```

---

### Task 8: 随附 adb.exe 与打包说明

**Files:**
- Create: `platform-tools/README.md`(说明如何放置 adb)
- Modify: `README.md`(补充打包说明)

- [ ] **Step 1: 写 platform-tools 放置说明**

`platform-tools/README.md`:

```markdown
# 放置 adb.exe

从 Google 官方下载 Android SDK Platform-Tools(Windows 版):
https://developer.android.com/tools/releases/platform-tools

解压后,把 `adb.exe`、`AdbWinApi.dll`、`AdbWinUsbApi.dll` 这三个文件放到本目录下。
程序会优先使用这里的 adb;找不到才回退系统 PATH 里的 adb。
```

- [ ] **Step 2: 放入 adb 文件并验证优先级**

手动操作:把官方 `adb.exe` + 两个 dll 放进 `platform-tools/`。

Run: `python -c "from apk_installer.adb_wrapper import find_adb; print(find_adb())"`
Expected: 打印出以 `platform-tools\adb.exe` 结尾的路径(而不是单独的 "adb")。

- [ ] **Step 3: 补充 README 打包说明**

在 `README.md` 末尾追加:

```markdown
## 打包成 exe(可选)
```
pip install pyinstaller
pyinstaller --noconfirm --windowed --name APK安装工具 ^
  --add-data "platform-tools;platform-tools" run.py
```
打包产物在 `dist/APK安装工具/` 下,整个文件夹拷给别人即可双击运行,无需装 Python。
```

- [ ] **Step 4: Commit**

```bash
git add platform-tools/README.md README.md
git commit -m "docs: 随附 adb 放置与打包说明"
```

---

## Self-Review 结果

**Spec 覆盖检查:**
- 全自动安装 → Task 4 `install_apk`(`install -r`)✅
- USB 连接 + 设备检测 → Task 3 `list_devices` + Task 6 USB 标签页 ✅
- WiFi 无线调试(pair/connect)→ Task 5 + Task 6 WiFi 标签页 ✅
- 拖拽选 APK + 浏览 → Task 6(tkinterdnd2,带浏览兜底)✅
- 后台线程不卡界面 → Task 6(`threading` + `queue` + `after`)✅
- 错误翻译成中文 → Task 2 `error_messages` ✅
- adb.exe 随程序打包、优先随附后回退 PATH → Task 3 `find_adb` + Task 8 ✅
- 打包成 exe → Task 8 PyInstaller 说明 ✅
- 范围控制(不做批量/卸载/文件互传/蓝牙)→ 计划未引入,符合 ✅

**占位符扫描:** 无 TBD/TODO,所有代码步骤均给出完整代码。

**类型一致性:** `Device(serial, model, status)`、`AdbResult(ok, message, raw)`、`find_adb()`、`_run()`、`list_devices()`、`install_apk()`、`pair_wifi()`、`connect_wifi()`、`translate()` 在各 Task 间命名一致。
