"""CustomTkinter 主窗口(深色现代风):连接方式 / 设备 / 选 APK / 安装。"""

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

# ---- 配色(深色现代风 + 亮色点缀)----
BG = "#1b1d22"
CARD = "#262a31"
ACCENT = "#3b82f6"        # 主蓝
ACCENT_HOVER = "#2563eb"
GO = "#22c55e"            # 安装按钮绿
GO_HOVER = "#16a34a"
MUTED = "#9aa4b2"
OK_C = "#22c55e"
WARN_C = "#f59e0b"
ERR_C = "#ef4444"
DOT_OFF = "#5b6472"


class App:
    def __init__(self):
        ctk.set_appearance_mode("dark")
        ctk.set_default_color_theme("blue")
        self.root = TkinterDnD.Tk() if _DND_OK else ctk.CTk()
        self.root.title("APK 一键安装器")
        self.root.geometry("470x780")
        self.root.minsize(440, 720)
        self.root.configure(bg=BG)

        self._msg_queue: queue.Queue = queue.Queue()
        self._apk_path: str | None = None
        self._devices: list[adb_wrapper.Device] = []

        # 字体
        self.f_title = ctk.CTkFont(size=21, weight="bold")
        self.f_sub = ctk.CTkFont(size=12)
        self.f_section = ctk.CTkFont(size=14, weight="bold")
        self.f_btn = ctk.CTkFont(size=16, weight="bold")
        self.f_log = ctk.CTkFont(family="Consolas", size=12)

        self._build_ui()
        self.root.after(100, self._drain_queue)

    # ---------- 通用小卡片 ----------
    def _section(self, title: str) -> ctk.CTkFrame:
        card = ctk.CTkFrame(self.root, corner_radius=14, fg_color=CARD)
        card.pack(fill="x", padx=16, pady=7)
        ctk.CTkLabel(card, text=title, font=self.f_section, anchor="w").pack(
            fill="x", padx=16, pady=(12, 4)
        )
        body = ctk.CTkFrame(card, fg_color="transparent")
        body.pack(fill="x", padx=16, pady=(0, 14))
        return body

    # ---------- 界面搭建 ----------
    def _build_ui(self):
        # 顶部标题横幅
        header = ctk.CTkFrame(self.root, corner_radius=16, fg_color=ACCENT)
        header.pack(fill="x", padx=16, pady=(16, 6))
        ctk.CTkLabel(header, text="📱  APK 一键安装器", font=self.f_title,
                     text_color="#ffffff", anchor="w").pack(fill="x", padx=18, pady=(14, 0))
        ctk.CTkLabel(header, text="拖进就装 · 自动通过 ADB 安装到手机 · 支持 USB / WiFi",
                     font=self.f_sub, text_color="#e5edff", anchor="w").pack(
            fill="x", padx=18, pady=(0, 14))

        # ① 连接方式
        body1 = self._section("①  连接方式")
        self.mode_switch = ctk.CTkSegmentedButton(
            body1, values=["USB", "WiFi"], command=self._on_mode_change,
            font=self.f_section, selected_color=ACCENT, selected_hover_color=ACCENT_HOVER,
        )
        self.mode_switch.set("USB")
        self.mode_switch.pack(fill="x", pady=(0, 8))

        self.conn_holder = ctk.CTkFrame(body1, fg_color="transparent")
        self.conn_holder.pack(fill="x")
        # USB 提示
        self.usb_frame = ctk.CTkFrame(self.conn_holder, fg_color="transparent")
        ctk.CTkLabel(self.usb_frame, text="🔌 用数据线连接手机,开启「开发者选项 → USB 调试」,再点下方刷新。",
                     text_color=MUTED, wraplength=390, justify="left").pack(anchor="w")
        # WiFi 输入
        self.wifi_frame = ctk.CTkFrame(self.conn_holder, fg_color="transparent")
        ctk.CTkLabel(self.wifi_frame, text="📶 在手机「开发者选项 → 无线调试」查看 IP / 端口 / 配对码。",
                     text_color=MUTED, wraplength=390, justify="left").pack(anchor="w", pady=(0, 6))
        grid = ctk.CTkFrame(self.wifi_frame, fg_color="transparent")
        grid.pack(fill="x")
        self.ip_entry = ctk.CTkEntry(grid, placeholder_text="手机 IP", width=150)
        self.pair_port_entry = ctk.CTkEntry(grid, placeholder_text="配对端口", width=95)
        self.pair_code_entry = ctk.CTkEntry(grid, placeholder_text="配对码", width=95)
        self.conn_port_entry = ctk.CTkEntry(grid, placeholder_text="连接端口", width=95)
        self.ip_entry.grid(row=0, column=0, padx=3, pady=3, sticky="w")
        self.pair_port_entry.grid(row=0, column=1, padx=3, pady=3, sticky="w")
        self.pair_code_entry.grid(row=1, column=0, padx=3, pady=3, sticky="w")
        self.conn_port_entry.grid(row=1, column=1, padx=3, pady=3, sticky="w")
        ctk.CTkButton(self.wifi_frame, text="配对并连接", command=self._on_wifi_connect,
                      fg_color=ACCENT, hover_color=ACCENT_HOVER).pack(anchor="w", pady=(6, 0))
        self.usb_frame.pack(fill="x")  # 默认 USB

        # ② 选择设备
        body2 = self._section("②  选择设备")
        row = ctk.CTkFrame(body2, fg_color="transparent")
        row.pack(fill="x")
        ctk.CTkButton(row, text="🔄 刷新", width=80, command=self._on_refresh,
                      fg_color=ACCENT, hover_color=ACCENT_HOVER).pack(side="left")
        self.dot = ctk.CTkLabel(row, text="●", text_color=DOT_OFF, font=self.f_section, width=18)
        self.dot.pack(side="left", padx=(10, 4))
        self.device_menu = ctk.CTkOptionMenu(row, values=["(未检测到设备)"],
                                             fg_color="#30353d", button_color=ACCENT,
                                             button_hover_color=ACCENT_HOVER)
        self.device_menu.pack(side="left", fill="x", expand=True)

        # ③ 选择 APK
        body3 = self._section("③  选择 APK")
        self.drop_area = ctk.CTkFrame(
            body3, height=130, fg_color="#21252b", corner_radius=12,
            border_width=2, border_color="#3a4250",
        )
        self.drop_area.pack(fill="x")
        self.drop_area.pack_propagate(False)
        self.drop_label = ctk.CTkLabel(
            self.drop_area, text="📦\n\n把 APK 文件拖到这里\n或点下方「浏览」选择",
            font=ctk.CTkFont(size=13), text_color=MUTED,
        )
        self.drop_label.pack(expand=True)
        if _DND_OK:
            for w in (self.drop_area, self.drop_label):
                w.drop_target_register(DND_FILES)
                w.dnd_bind("<<Drop>>", self._on_drop)
        ctk.CTkButton(body3, text="📂 浏览…", width=100, command=self._on_browse,
                      fg_color="#30353d", hover_color="#3a4250").pack(anchor="w", pady=(8, 0))

        # ④ 安装按钮
        self.install_btn = ctk.CTkButton(self.root, text="⬇   安  装", height=48, font=self.f_btn,
                                         fg_color=GO, hover_color=GO_HOVER, corner_radius=14,
                                         command=self._on_install)
        self.install_btn.pack(fill="x", padx=16, pady=(10, 4))

        # 状态行 + 日志
        self.status = ctk.CTkLabel(self.root, text="准备就绪", anchor="w",
                                   text_color=MUTED, font=self.f_sub)
        self.status.pack(fill="x", padx=20, pady=(2, 2))
        self.log_box = ctk.CTkTextbox(self.root, height=150, font=self.f_log,
                                      fg_color="#16181d", corner_radius=12)
        self.log_box.pack(fill="both", expand=True, padx=16, pady=(0, 16))

    # ---------- 日志 / 状态 / 线程 ----------
    def _log(self, text: str):
        self._msg_queue.put(("log", text))

    def _set_status(self, text: str, color: str = MUTED):
        self._msg_queue.put(("status", (text, color)))

    def _drain_queue(self):
        try:
            while True:
                kind, payload = self._msg_queue.get_nowait()
                if kind == "log":
                    self.log_box.insert("end", payload + "\n")
                    self.log_box.see("end")
                elif kind == "status":
                    text, color = payload
                    self.status.configure(text=text, text_color=color)
        except queue.Empty:
            pass
        self.root.after(100, self._drain_queue)

    def _run_bg(self, fn):
        threading.Thread(target=fn, daemon=True).start()

    # ---------- 事件 ----------
    def _on_mode_change(self, value):
        self.usb_frame.pack_forget()
        self.wifi_frame.pack_forget()
        (self.usb_frame if value == "USB" else self.wifi_frame).pack(fill="x")

    def _on_refresh(self):
        self._set_status("正在检测设备…", MUTED)
        self._log("正在检测设备…")

        def work():
            self._devices = adb_wrapper.list_devices()
            if not self._devices:
                self.dot.configure(text_color=DOT_OFF)
                self.device_menu.configure(values=["(未检测到设备)"])
                self.device_menu.set("(未检测到设备)")
                self._set_status("没检测到设备", WARN_C)
                self._log("没检测到设备。USB:检查线和 USB 调试;WiFi:先在上方配对连接。")
                return
            labels = [f"{d.model} [{d.serial}] ({d.status})" for d in self._devices]
            self.device_menu.configure(values=labels)
            self.device_menu.set(labels[0])
            first_ok = self._devices[0].status == "device"
            self.dot.configure(text_color=OK_C if first_ok else WARN_C)
            self._set_status(f"已连接 {len(self._devices)} 台设备", OK_C if first_ok else WARN_C)
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
            self._set_status("请填手机 IP 和连接端口", WARN_C)
            self._log("请至少填写手机 IP 和连接端口。")
            return

        def work():
            if pport and code:
                self._set_status("正在配对…", MUTED)
                self._log("正在配对…")
                r = adb_wrapper.pair_wifi(ip, pport, code)
                self._log(r.message)
                if not r.ok:
                    self._set_status("配对失败", ERR_C)
                    return
            self._set_status("正在连接…", MUTED)
            self._log("正在连接…")
            r = adb_wrapper.connect_wifi(ip, cport)
            self._log(r.message)
            if r.ok:
                self._set_status("已连接,正在刷新设备", OK_C)
                self._on_refresh()
            else:
                self._set_status("连接失败", ERR_C)

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
            self._set_status("这不是 .apk 文件", ERR_C)
            self._log("这不是 .apk 文件,请重新选择。")
            return
        self._apk_path = path
        name = path.replace("\\", "/").split("/")[-1]
        self.drop_label.configure(text=f"📦  已选择\n\n{name}", text_color="#d7dde6")
        self.drop_area.configure(border_color=ACCENT)
        self._set_status(f"已选择 APK:{name}", OK_C)

    def _on_install(self):
        serial = self._selected_serial()
        if not serial:
            self._set_status("请先刷新并选择手机", WARN_C)
            self._log("请先「刷新设备」并选择一台手机。")
            return
        if not self._apk_path:
            self._set_status("请先选择 APK 文件", WARN_C)
            self._log("请先选择一个 APK 文件。")
            return
        self.install_btn.configure(state="disabled", text="安装中…")
        self._set_status("正在安装…", MUTED)
        self._log(f"开始安装到 {serial} …")

        def work():
            r = adb_wrapper.install_apk(serial, self._apk_path)
            self._log(r.message)
            self._set_status(("✓ " if r.ok else "✗ ") + r.message,
                             OK_C if r.ok else ERR_C)
            self.install_btn.configure(state="normal", text="⬇   安  装")

        self._run_bg(work)

    def run(self):
        self.root.mainloop()
