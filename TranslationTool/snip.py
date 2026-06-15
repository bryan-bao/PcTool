# -*- coding: utf-8 -*-
"""截图选区小工具：全屏展示当前屏幕截图，鼠标拖一个框，把框内区域存成 PNG，
同时把选区屏幕坐标写到 同名.json（贴图翻译要按原位置回贴）。
以子进程方式运行（桌面版由 TranslationTool.exe --snip 调起），选区成功退出码 0，取消退出码 1。"""
import ctypes
import json
import sys


def run_snip(out_path):
    # 必须先声明 DPI 感知，否则在 125%/150% 缩放屏幕上鼠标坐标和截图像素对不上
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except OSError:
        pass

    import tkinter as tk
    from PIL import ImageGrab, ImageTk

    img = ImageGrab.grab()  # 抓主屏（物理像素）

    root = tk.Tk()
    root.attributes("-fullscreen", True)
    root.attributes("-topmost", True)
    root.configure(cursor="cross")

    canvas = tk.Canvas(root, highlightthickness=0, cursor="cross")
    canvas.pack(fill="both", expand=True)
    # 屏幕截图垫底再压一层半透明遮罩，看起来像微信截图
    tk_img = ImageTk.PhotoImage(img)
    canvas.create_image(0, 0, anchor="nw", image=tk_img)
    canvas.create_rectangle(0, 0, img.width, img.height, fill="black", stipple="gray25", outline="")
    canvas.create_text(
        img.width // 2, 60, text="拖动鼠标框选要翻译的文字区域，按 Esc 取消",
        fill="white", font=("Microsoft YaHei", 14),
    )

    state = {"x0": 0, "y0": 0, "rect": None, "box": None}

    def on_press(e):
        state["x0"], state["y0"] = e.x, e.y
        state["rect"] = canvas.create_rectangle(e.x, e.y, e.x, e.y, outline="#7c6cff", width=2)

    def on_drag(e):
        if state["rect"]:
            canvas.coords(state["rect"], state["x0"], state["y0"], e.x, e.y)

    def on_release(e):
        x1, x2 = sorted((state["x0"], e.x))
        y1, y2 = sorted((state["y0"], e.y))
        # 鼠标可能拖出屏幕边缘，坐标夹紧到截图范围内，避免裁出黑边喂给识别引擎
        x1, x2 = max(0, x1), min(img.width, x2)
        y1, y2 = max(0, y1), min(img.height, y2)
        if x2 - x1 > 5 and y2 - y1 > 5:
            state["box"] = (x1, y1, x2, y2)
            root.destroy()
        else:
            # 只是点了一下没拖出框：清掉这次的框让用户重新拖，不直接退出
            if state["rect"]:
                canvas.delete(state["rect"])
                state["rect"] = None

    canvas.bind("<ButtonPress-1>", on_press)
    canvas.bind("<B1-Motion>", on_drag)
    canvas.bind("<ButtonRelease-1>", on_release)
    root.bind("<Escape>", lambda e: root.destroy())
    # 由后台子进程弹出的窗口可能拿不到键盘焦点（Esc 会失灵），强制抢两次焦点
    root.focus_force()
    root.after(100, root.focus_force)
    root.mainloop()

    if state["box"]:
        img.crop(state["box"]).save(out_path)
        try:
            with open(out_path + ".json", "w", encoding="utf-8") as f:
                json.dump({"box": list(state["box"])}, f)
        except OSError:
            pass
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(run_snip(sys.argv[1]) if len(sys.argv) > 1 else 1)
