# -*- coding: utf-8 -*-
"""桌面版入口：后台线程跑 Flask，再用 pywebview 套一个原生窗口"""
import os
import sys

# --noconsole 打包后 stdout/stderr 是 None，任何打印都会崩，这里兜底（仅 None 时）
sys.stdout = sys.stdout or open(os.devnull, "w", encoding="utf-8", errors="replace")
sys.stderr = sys.stderr or open(os.devnull, "w", encoding="utf-8", errors="replace")

# 截图模式：主程序用 "自己.exe --snip 输出路径" 调起一个截图选区子进程，干完就退
if len(sys.argv) >= 3 and sys.argv[1] == "--snip":
    from snip import run_snip

    sys.exit(run_snip(sys.argv[2]))

import socket
import threading
import time

from app import app, DATA_DIR, load_settings, apply_autostart  # noqa: E402

# 自愈：程序文件夹被移动/改名后注册表里的自启路径会失效，每次启动按当前位置刷新
try:
    if getattr(sys, "frozen", False) and load_settings().get("autostart"):
        apply_autostart(True)
except Exception:
    pass


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def launch_flask(port):
    # threaded=True 必须开：窗口内核会长期占着连接，单线程下其余请求全被堵死
    t = threading.Thread(
        target=lambda: app.run(
            host="127.0.0.1", port=port, debug=False, use_reloader=False, threaded=True
        ),
        daemon=True,
    )
    t.start()
    return t


# 测试时可用环境变量 TT_PORT 固定端口，平时用随机空闲端口；
# 端口存在被抢的小概率（free_port 与 bind 之间的间隙），所以失败就换端口重来
PORT, started = None, False
for _attempt in range(3):
    PORT = int(os.environ.get("TT_PORT") or free_port())
    server = launch_flask(PORT)
    for _ in range(100):
        if not server.is_alive():  # bind 失败线程会死掉，别白等
            break
        try:
            # 用纯 TCP 探测，绝不能走 HTTP 库——系统代理会劫持 127.0.0.1 的请求
            socket.create_connection(("127.0.0.1", PORT), timeout=0.3).close()
            started = True
            break
        except OSError:
            time.sleep(0.1)
    if started:
        break

import webview  # noqa: E402
import app as app_module  # noqa: E402

if started:
    window = webview.create_window(
        "翻译·语音小工具",
        f"http://127.0.0.1:{PORT}",
        width=1000,
        height=800,
        min_size=(720, 560),
    )
    app_module.WEBVIEW_WINDOW = window  # 截图翻译时由后台先把窗口最小化
    # 注册全局快捷键（按下后直接进入截图翻译，软件在后台也有效）
    import hotkey as hotkey_mod

    hotkey_mod.start(lambda: load_settings().get("hotkey"), app_module.hotkey_snip)

    # 预热 OCR 引擎（不然第一次截图要多卡一两秒）
    threading.Thread(
        target=lambda: (time.sleep(2), app_module.get_ocr()), daemon=True
    ).start()

    # 划词翻译：全局监听鼠标划选 → 光标旁弹小按钮 → 点击弹翻译小窗
    try:
        import selection

        selection.configure(
            enabled=lambda: bool(load_settings().get("selection_translate")),
            require_ctrl=lambda: bool(load_settings().get("selection_require_ctrl")),
            translate=lambda t: app_module.translate_text(t),
        )
        selection.start()
        app_module.SELECTION = selection  # 截图就地翻译复用它的小弹窗
    except Exception:
        pass

    # ---- 系统托盘：点窗口关闭 = 收进托盘后台待命，真正退出走托盘菜单 ----
    import pystray
    from PIL import Image

    _icon_file = os.path.join(
        sys._MEIPASS if getattr(sys, "frozen", False) else os.path.dirname(os.path.abspath(__file__)),
        "app.ico",
    )
    _notified_once = {"done": False}
    tray = None

    def on_closing():
        window.hide()
        if not _notified_once["done"]:
            _notified_once["done"] = True
            try:
                tray.notify("我还在后台运行：点托盘图标重新打开，按快捷键随时截图翻译", "翻译·语音小工具")
            except Exception:
                pass
        return False  # 拦下真正的关闭

    window.events.closing += on_closing

    def tray_show(icon=None, item=None):
        try:
            window.show()
            window.restore()
        except Exception:
            pass

    def tray_snip(icon=None, item=None):
        threading.Thread(target=app_module.hotkey_snip, daemon=True).start()

    def tray_quit(icon=None, item=None):
        try:
            tray.stop()
        except Exception:
            pass
        try:
            window.events.closing -= on_closing
            window.destroy()
        except Exception:
            pass
        os._exit(0)

    tray = pystray.Icon(
        "TranslationTool",
        Image.open(_icon_file),
        "翻译·语音小工具",
        menu=pystray.Menu(
            pystray.MenuItem("打开主界面", tray_show, default=True),
            pystray.MenuItem("截图翻译", tray_snip),
            pystray.MenuItem("退出", tray_quit),
        ),
    )
    tray.run_detached()
else:
    webview.create_window(
        "翻译·语音小工具",
        html="<div style='font-family:sans-serif;padding:48px;font-size:16px'>"
        "<h2>启动失败</h2><p>本地服务没能正常开启，请关闭本窗口后重新打开软件。"
        "若反复出现，请重启电脑后再试。</p></div>",
        width=560,
        height=320,
    )
# 浏览器内核的缓存/存储也放在程序自己目录，不写系统目录（用户要求所有文件跟程序走）
webview.start(storage_path=os.path.join(DATA_DIR, "webview_data"), private_mode=False)

# 窗口被真正销毁（托盘退出）后，确保托盘线程和整个进程都收掉
if started:
    try:
        tray.stop()
    except Exception:
        pass
os._exit(0)
