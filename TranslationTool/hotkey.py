# -*- coding: utf-8 -*-
"""全局快捷键：用 Windows 原生 RegisterHotKey 实现，软件在后台也能响应。
独立消息循环线程持有热键；设置改了之后用 PostThreadMessage 通知它重新注册。"""
import ctypes
import threading
from ctypes import wintypes

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

MODS = {"ctrl": 0x0002, "alt": 0x0001, "shift": 0x0004, "win": 0x0008}
MOD_NOREPEAT = 0x4000
WM_HOTKEY = 0x0312
WM_APP_REREGISTER = 0x8001
HOTKEY_ID = 1
TEST_ID = 99

_thread_id = None
_get_combo = None
_callback = None
state = {"combo": "", "ok": True}


def parse_hotkey(combo):
    """'ctrl+alt+t' -> (修饰键位掩码, 虚拟键码)；格式不对抛 ValueError"""
    parts = [p.strip().lower() for p in combo.split("+") if p.strip()]
    mods, vk = 0, None
    for p in parts:
        if p in MODS:
            mods |= MODS[p]
        elif vk is None:
            vk = _vk_of(p)
        else:
            raise ValueError("只能有一个主键")
    if vk is None or mods == 0:
        raise ValueError("必须是 Ctrl/Alt/Shift 加一个键的组合")
    return mods, vk


def _vk_of(key):
    if len(key) == 1 and (key.isascii() and (key.isalpha() or key.isdigit())):
        return ord(key.upper())
    if key.startswith("f") and key[1:].isdigit() and 1 <= int(key[1:]) <= 12:
        return 0x6F + int(key[1:])
    raise ValueError(f"不支持的按键: {key}")


def _register():
    combo = (_get_combo() or "").strip().lower()
    state["combo"] = combo
    state["ok"] = True
    if not combo:
        return
    try:
        mods, vk = parse_hotkey(combo)
    except ValueError:
        state["ok"] = False
        return
    state["ok"] = bool(user32.RegisterHotKey(None, HOTKEY_ID, mods | MOD_NOREPEAT, vk))


def _loop():
    global _thread_id
    _thread_id = kernel32.GetCurrentThreadId()
    msg = wintypes.MSG()
    # 先逼系统给本线程建好消息队列，再注册，保证之后 PostThreadMessage 不丢
    user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 0)
    _register()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
        if msg.message == WM_HOTKEY and msg.wParam == HOTKEY_ID:
            cb = _callback
            if cb:
                threading.Thread(target=cb, daemon=True).start()
        elif msg.message == WM_APP_REREGISTER:
            user32.UnregisterHotKey(None, HOTKEY_ID)
            _register()


def start(get_combo, callback):
    """get_combo: 无参函数，返回设置里当前的快捷键字符串；callback: 热键按下时调用"""
    global _get_combo, _callback
    _get_combo = get_combo
    _callback = callback
    threading.Thread(target=_loop, daemon=True).start()


def is_running():
    return _thread_id is not None


def reregister():
    """设置变更后让热键线程重新注册"""
    if _thread_id:
        user32.PostThreadMessageW(_thread_id, WM_APP_REREGISTER, 0, 0)


def test_available(combo):
    """试注册一下看组合键是否被别的软件占用（自己当前用的组合不算占用）"""
    combo = (combo or "").strip().lower()
    if not combo or combo == state["combo"]:
        return True
    try:
        mods, vk = parse_hotkey(combo)
    except ValueError:
        return False
    if user32.RegisterHotKey(None, TEST_ID, mods | MOD_NOREPEAT, vk):
        user32.UnregisterHotKey(None, TEST_ID)
        return True
    return False
