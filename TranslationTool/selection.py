# -*- coding: utf-8 -*-
"""划词翻译：全局监听鼠标划选 → 光标旁弹"译"小按钮 → 点击弹出翻译小窗。
也对外提供 show_result_popup()，给"截图就地翻译"复用同一个小弹窗。

两个线程：① 低级鼠标钩子线程（裸 Windows 消息循环）；② tkinter UI 线程（小按钮 + 小弹窗）。
所有 tkinter 调用都集中在 UI 线程里，钩子线程只往队列里塞信号。"""
import ctypes
import queue
import threading
import time
from ctypes import wintypes

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

LRESULT = ctypes.c_ssize_t
ULONG_PTR = ctypes.c_size_t


class POINT(ctypes.Structure):
    _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]


class MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("pt", POINT), ("mouseData", wintypes.DWORD),
                ("flags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ULONG_PTR)]


HOOKPROC = ctypes.CFUNCTYPE(LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)

WH_MOUSE_LL = 14
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
VK_CONTROL = 0x11
KEYEVENTF_KEYUP = 0x0002

# 设置 ctypes 签名，避免 64 位下指针被截断导致崩溃
user32.SetWindowsHookExW.restype = wintypes.HHOOK
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
user32.CallNextHookEx.restype = LRESULT
user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]
user32.GetForegroundWindow.restype = wintypes.HWND
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetAsyncKeyState.restype = ctypes.c_short
user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
user32.keybd_event.argtypes = [ctypes.c_ubyte, ctypes.c_ubyte, wintypes.DWORD, ULONG_PTR]

# ---- 由 desktop.py 注入的配置/回调 ----
_cfg = {
    "enabled": lambda: False,        # 划词翻译开关
    "require_ctrl": lambda: False,   # 是否要按住 Ctrl 划选才弹按钮
    "translate": None,               # fn(text) -> (ok: bool, 文字或错误)
}
_own_title = "翻译·语音小工具"
_suspended = False  # 截图期间挂起，免得截图里的拖动也触发划词
_ui = None


def configure(enabled, require_ctrl, translate):
    _cfg["enabled"] = enabled
    _cfg["require_ctrl"] = require_ctrl
    _cfg["translate"] = translate


def suspend(flag):
    global _suspended
    _suspended = bool(flag)


def start():
    global _ui
    _ui = _UI()
    _ui.start()
    threading.Thread(target=_hook_loop, daemon=True).start()


def show_result_popup(text):
    """线程安全：在光标处弹出一个翻译结果小窗（给截图就地翻译用）"""
    if _ui:
        _ui.q.put(("resultpopup", text))


def show_overlay(img, region, text=""):
    """线程安全：把"贴好译文的截图"按原屏幕位置整块盖回去（贴图翻译）。
    img: PIL 图；region: [x1,y1,x2,y2] 屏幕物理坐标；text: 右键复制用的全部译文"""
    if _ui:
        _ui.q.put(("overlay", (img, region, text)))


def show_busy(region=None):
    """线程安全：在截图位置上方亮一个"正在翻译"小条"""
    if _ui:
        _ui.q.put(("busy", region))


def hide_busy():
    if _ui:
        _ui.q.put(("hidebusy", None))


# ====================== 鼠标钩子线程 ======================
_down = {"pos": None}
_last_up = {"pos": (0, 0), "t": 0.0}
_hook_proc_ref = None


def _proc(nCode, wParam, lParam):
    if nCode == 0 and _ui is not None:
        if wParam == WM_LBUTTONDOWN:
            st = ctypes.cast(lParam, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
            pos = (st.pt.x, st.pt.y)
            _down["pos"] = pos
            _ui.q.put(("dismiss", pos))  # 点别处就收起已弹出的按钮/弹窗
        elif wParam == WM_LBUTTONUP:
            st = ctypes.cast(lParam, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
            up = (st.pt.x, st.pt.y)
            dn = _down["pos"]
            _down["pos"] = None
            now = time.time()
            if dn and (abs(up[0] - dn[0]) > 4 or abs(up[1] - dn[1]) > 4):
                _maybe_selection()  # 拖动划选
            elif (now - _last_up["t"] < 0.45
                  and abs(up[0] - _last_up["pos"][0]) < 6
                  and abs(up[1] - _last_up["pos"][1]) < 6):
                _maybe_selection()  # 双击选词（两次原地快速点击）
            _last_up["pos"], _last_up["t"] = up, now
    return user32.CallNextHookEx(None, nCode, wParam, lParam)


def _maybe_selection():
    if _suspended or not _cfg["enabled"]():
        return
    if _cfg["require_ctrl"]() and not (user32.GetAsyncKeyState(VK_CONTROL) & 0x8000):
        return
    try:  # 在自己的窗口里划字不弹（避免自己翻自己）
        buf = ctypes.create_unicode_buffer(256)
        user32.GetWindowTextW(user32.GetForegroundWindow(), buf, 256)
        if buf.value == _own_title:
            return
    except Exception:
        pass
    _ui.q.put(("capture", None))


def _hook_loop():
    global _hook_proc_ref
    _hook_proc_ref = HOOKPROC(_proc)  # 必须保留引用，否则被回收会崩
    if not user32.SetWindowsHookExW(WH_MOUSE_LL, _hook_proc_ref, None, 0):
        return
    msg = wintypes.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        user32.TranslateMessage(ctypes.byref(msg))
        user32.DispatchMessageW(ctypes.byref(msg))


def _send_ctrl_c():
    user32.keybd_event(VK_CONTROL, 0, 0, 0)
    user32.keybd_event(0x43, 0, 0, 0)               # C down
    user32.keybd_event(0x43, 0, KEYEVENTF_KEYUP, 0) # C up
    user32.keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)


# ====================== tkinter UI 线程 ======================
class _UI:
    def __init__(self):
        self.q = queue.Queue()
        self.text = ""
        self._old_clip = None
        self._btn_shown = False
        self._popup_shown = False
        self._popup_ignore = False  # 打开弹窗的那一次点击不要把它自己关掉
        self._autohide = None
        self._popuphide = None
        self.ov = None          # 贴图翻译浮窗
        self._ov_photo = None
        self._ov_text = ""
        self._ovhide = None
        self._copy_tries = 0
        self._busyhide = None

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        import tkinter as tk
        self.tk = tk
        try:
            # 让本线程的 tk 按物理像素工作，小按钮才能精准贴在光标旁（不受屏幕缩放影响）
            try:
                user32.SetThreadDpiAwarenessContext(ctypes.c_void_p(-4))
            except Exception:
                pass
            self.root = tk.Tk()
            self.root.withdraw()
            self._build()
            self.root.after(40, self._poll)
            self.root.mainloop()
        except Exception:
            pass

    def _build(self):
        tk = self.tk
        # 光标旁的小"译"按钮
        self.btn = tk.Toplevel(self.root)
        self.btn.withdraw()
        self.btn.overrideredirect(True)
        self.btn.attributes("-topmost", True)
        lbl = tk.Label(self.btn, text="译  翻译", bg="#5b5ce2", fg="white",
                       font=("Microsoft YaHei", 11, "bold"), padx=12, pady=6, cursor="hand2")
        lbl.pack()
        for w in (self.btn, lbl):
            w.bind("<Button-1>", self._on_btn)
        # 翻译结果小弹窗
        self.popup = tk.Toplevel(self.root)
        self.popup.withdraw()
        self.popup.overrideredirect(True)
        self.popup.attributes("-topmost", True)
        border = tk.Frame(self.popup, bg="#5b5ce2", padx=2, pady=2)
        border.pack()
        inner = tk.Frame(border, bg="white")
        inner.pack()
        self.popup_lbl = tk.Label(inner, text="", bg="white", fg="#1f2430",
                                  font=("Microsoft YaHei", 12), justify="left",
                                  wraplength=380, padx=15, pady=12)
        self.popup_lbl.pack()
        tip = tk.Label(inner, text="点这里复制并关闭", bg="white", fg="#9aa0b3",
                       font=("Microsoft YaHei", 9), pady=4)
        tip.pack()
        for w in (self.popup, inner, self.popup_lbl, tip):
            w.bind("<Button-1>", lambda e: self._copy_and_hide())
        # "正在翻译"小条
        self.busy = tk.Toplevel(self.root)
        self.busy.withdraw()
        self.busy.overrideredirect(True)
        self.busy.attributes("-topmost", True)
        tk.Label(self.busy, text="⏳ 正在识别翻译…", bg="#5b5ce2", fg="white",
                 font=("Microsoft YaHei", 10, "bold"), padx=14, pady=6).pack()

    def _poll(self):
        try:
            while True:
                kind, data = self.q.get_nowait()
                if kind == "capture":
                    self._do_capture()
                elif kind == "dismiss":
                    self._dismiss(data)
                elif kind == "showbtn":      # 测试用：直接显示按钮
                    self._show_button()
                elif kind == "resultpopup":
                    self._show_popup(data)
                elif kind == "fill_popup":
                    self._fill_popup(data)
                elif kind == "overlay":
                    self._show_overlay(*data)
                elif kind == "busy":
                    self._show_busy(data)
                elif kind == "hidebusy":
                    self._hide_busy()
        except queue.Empty:
            pass
        self.root.after(40, self._poll)

    # ---- 复制选中文字 ----
    def _do_capture(self):
        try:
            self._old_clip = self.root.clipboard_get()
        except Exception:
            self._old_clip = None
        try:
            self.root.clipboard_clear()
        except Exception:
            pass
        self._copy_tries = 0
        _send_ctrl_c()
        self.root.after(150, self._after_copy)

    def _after_copy(self):
        try:
            txt = self.root.clipboard_get()
        except Exception:
            txt = ""
        if not (txt or "").strip() and self._copy_tries < 3:
            # 有些程序响应 Ctrl+C 比较慢，多等几拍再放弃
            self._copy_tries += 1
            self.root.after(150, self._after_copy)
            return
        try:  # 还原用户原来的剪贴板，不打扰
            self.root.clipboard_clear()
            if self._old_clip:
                self.root.clipboard_append(self._old_clip)
        except Exception:
            pass
        txt = (txt or "").strip()
        if txt:
            self.text = txt
            self._show_button()

    # ---- 小按钮 ----
    def _show_button(self):
        self._hide_popup()  # 新一次划词，先收掉上一个结果窗
        x, y = self.root.winfo_pointerxy()
        self.btn.geometry(f"+{x + 8}+{y + 16}")
        self.btn.deiconify()
        self.btn.lift()
        self.btn.update_idletasks()
        self._btn_shown = True
        if self._autohide:
            self.root.after_cancel(self._autohide)
        self._autohide = self.root.after(4000, self._hide_button)

    def _hide_button(self):
        self.btn.withdraw()
        self._btn_shown = False

    def _on_btn(self, e=None):
        self._hide_button()
        text = self.text
        if not text:
            return
        self._show_popup("翻译中…", from_click=True)

        def work():
            fn = _cfg["translate"]
            try:
                ok, res = fn(text) if fn else (False, "翻译功能不可用")
            except Exception as ex:
                ok, res = False, f"翻译出错（{ex}）"
            self.q.put(("fill_popup", res if ok else "⚠ " + str(res)))

        threading.Thread(target=work, daemon=True).start()

    # ---- 结果弹窗 ----
    def _show_popup(self, text, from_click=False):
        self._hide_busy()
        self.popup_lbl.config(text=text or "")
        # 由点击"译"按钮打开时，要忽略这同一次点击触发的"点别处收起"
        self._popup_ignore = from_click
        x, y = self.root.winfo_pointerxy()
        self.popup.update_idletasks()
        w, h = self.popup.winfo_width(), self.popup.winfo_height()
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        px = min(x + 8, sw - w - 10)
        py = min(y + 16, sh - h - 10)
        self.popup.geometry(f"+{max(0, px)}+{max(0, py)}")
        self.popup.deiconify()
        self.popup.lift()
        self._popup_shown = True
        if self._popuphide:
            self.root.after_cancel(self._popuphide)
        self._popuphide = self.root.after(12000, self._hide_popup)

    def _fill_popup(self, text):
        if self._popup_shown:
            self.popup_lbl.config(text=text or "")
            self.popup.update_idletasks()

    def _hide_popup(self):
        self.popup.withdraw()
        self._popup_shown = False

    def _copy_and_hide(self):
        try:
            t = self.popup_lbl.cget("text")
            if t and not t.startswith("翻译中") and not t.startswith("⚠"):
                self.root.clipboard_clear()
                self.root.clipboard_append(t)
        except Exception:
            pass
        self._hide_popup()

    # ---- "正在翻译"小条 ----
    def _show_busy(self, region):
        try:
            if region:
                x, y = int(region[0]), max(0, int(region[1]) - 42)
            else:
                px, py = self.root.winfo_pointerxy()
                x, y = px + 8, py + 16
            self.busy.geometry(f"+{x}+{y}")
            self.busy.deiconify()
            self.busy.lift()
            if self._busyhide:
                self.root.after_cancel(self._busyhide)
            self._busyhide = self.root.after(60000, self._hide_busy)  # 兜底自动消失
        except Exception:
            pass

    def _hide_busy(self):
        try:
            self.busy.withdraw()
        except Exception:
            pass

    # ---- 贴图翻译浮窗 ----
    def _show_overlay(self, img, region, text):
        self._hide_busy()
        self._hide_overlay()
        try:
            from PIL import ImageTk

            x1, y1 = int(region[0]), int(region[1])
            self._ov_photo = ImageTk.PhotoImage(img)  # 必须保留引用
            self._ov_text = text
            ov = self.tk.Toplevel(self.root)
            ov.withdraw()
            ov.overrideredirect(True)
            ov.attributes("-topmost", True)
            lbl = self.tk.Label(ov, image=self._ov_photo, bd=0,
                                highlightthickness=1, highlightbackground="#5b5ce2")
            lbl.pack()
            ov.geometry(f"+{x1}+{y1}")
            for w in (ov, lbl):
                w.bind("<Button-1>", lambda e: self._hide_overlay())   # 左键点一下关闭
                w.bind("<Button-3>", self._copy_overlay)               # 右键复制译文并关闭
            ov.deiconify()
            ov.lift()
            self.ov = ov
            if self._ovhide:
                self.root.after_cancel(self._ovhide)
            self._ovhide = self.root.after(30000, self._hide_overlay)
        except Exception:
            pass

    def _copy_overlay(self, e=None):
        try:
            if self._ov_text:
                self.root.clipboard_clear()
                self.root.clipboard_append(self._ov_text)
        except Exception:
            pass
        self._hide_overlay()

    def _hide_overlay(self):
        if self.ov is not None:
            try:
                self.ov.destroy()
            except Exception:
                pass
            self.ov = None
            self._ov_photo = None

    # ---- 点别处收起 ----
    def _dismiss(self, pos):
        if self._btn_shown and not self._inside(self.btn, pos):
            self._hide_button()
        if self._popup_shown and not self._inside(self.popup, pos):
            if self._popup_ignore:
                self._popup_ignore = False  # 放过打开弹窗的那一次点击
            else:
                self._hide_popup()

    def _inside(self, win, pos):
        try:
            x, y = pos
            wx, wy = win.winfo_rootx(), win.winfo_rooty()
            return wx <= x <= wx + win.winfo_width() and wy <= y <= wy + win.winfo_height()
        except Exception:
            return False


# 测试用：跳过剪贴板，直接弹按钮
def test_show_button(text):
    if _ui:
        _ui.text = text
        _ui.q.put(("showbtn", None))
