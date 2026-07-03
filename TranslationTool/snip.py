# -*- coding: utf-8 -*-
"""Screenshot selection helper.

The main app starts this as a child process. After the user drags a region,
the selection stays on screen and a compact toolbar appears below it. The
toolbar action is written to ``<out_path>.json``:

- ``translate``: save the selected PNG and let the main app OCR/translate it.
- ``pin``: save the selected PNG and pin it on screen without OCR.
- cancelled: exit with code 1 and do not save the PNG.
"""
import ctypes
import json
import sys
import os
import time


def child_log(path, msg):
    try:
        import os

        d = os.path.dirname(os.path.abspath(path)) if path else os.getcwd()
        with open(os.path.join(d, "snip_child_debug.log"), "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def run_image_window(path, title="截图", cleanup=True):
    import os
    import tkinter as tk
    from io import BytesIO
    from PIL import Image, ImageTk

    def log(msg):
        try:
            with open(os.path.join(os.path.dirname(os.path.abspath(path)) or ".", "window_debug.log"), "a", encoding="utf-8") as f:
                f.write(msg + "\n")
        except Exception:
            pass

    log(f"open {title} path={path} exists={os.path.exists(path)}")

    region = None
    try:
        with open(path + ".json", encoding="utf-8") as f:
            region = json.load(f).get("box")
    except (OSError, ValueError):
        pass

    img = Image.open(path).convert("RGB")
    root = tk.Tk()
    root.title(title)
    root.attributes("-topmost", True)

    def copy_image():
        try:
            buf = BytesIO()
            img.save(buf, "BMP")
            data = buf.getvalue()[14:]  # CF_DIB wants BMP bytes without BITMAPFILEHEADER.
            buf.close()
            kernel32 = ctypes.windll.kernel32
            user32 = ctypes.windll.user32
            kernel32.GlobalAlloc.restype = ctypes.c_void_p
            kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
            kernel32.GlobalLock.restype = ctypes.c_void_p
            kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
            kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
            kernel32.GlobalFree.argtypes = [ctypes.c_void_p]
            user32.SetClipboardData.restype = ctypes.c_void_p
            user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
            GMEM_MOVEABLE = 0x0002
            CF_DIB = 8
            hglobal = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
            if not hglobal:
                raise OSError("GlobalAlloc failed")
            ptr = kernel32.GlobalLock(hglobal)
            if not ptr:
                kernel32.GlobalFree(hglobal)
                raise OSError("GlobalLock failed")
            ctypes.memmove(ptr, data, len(data))
            kernel32.GlobalUnlock(hglobal)
            if not user32.OpenClipboard(None):
                kernel32.GlobalFree(hglobal)
                raise OSError("OpenClipboard failed")
            try:
                user32.EmptyClipboard()
                if not user32.SetClipboardData(CF_DIB, hglobal):
                    kernel32.GlobalFree(hglobal)
                    raise OSError("SetClipboardData failed")
                hglobal = None
            finally:
                user32.CloseClipboard()
            status_var.set("已复制，可直接粘贴发送")
            root.after(1800, lambda: status_var.set(""))
        except Exception as e:
            status_var.set(f"复制失败：{e}")

    toolbar = tk.Frame(root, bg="#f7f7f8")
    toolbar.pack(fill="x")
    tk.Button(
        toolbar,
        text="复制图片",
        command=copy_image,
        relief="flat",
        bg="#ffffff",
        fg="#242733",
        font=("Microsoft YaHei", 10),
        padx=12,
        pady=4,
    ).pack(side="left", padx=6, pady=5)
    status_var = tk.StringVar(value="")
    tk.Label(toolbar, textvariable=status_var, bg="#f7f7f8", fg="#16a34a",
             font=("Microsoft YaHei", 9)).pack(side="left", padx=8)

    canvas = tk.Canvas(root, highlightthickness=0, bg="#111111")
    canvas.pack(fill="both", expand=True)
    state = {"photo": None, "item": None, "size": (0, 0)}

    def render(event=None):
        cw = max(1, canvas.winfo_width())
        ch = max(1, canvas.winfo_height())
        if state["size"] == (cw, ch):
            return
        state["size"] = (cw, ch)
        scale = min(cw / img.width, ch / img.height)
        if scale <= 0:
            return
        w = max(1, int(img.width * scale))
        h = max(1, int(img.height * scale))
        resized = img if (w == img.width and h == img.height) else img.resize((w, h), Image.LANCZOS)
        state["photo"] = ImageTk.PhotoImage(resized)
        x = (cw - w) // 2
        y = (ch - h) // 2
        if state["item"] is None:
            state["item"] = canvas.create_image(x, y, anchor="nw", image=state["photo"])
        else:
            canvas.coords(state["item"], x, y)
            canvas.itemconfigure(state["item"], image=state["photo"])

    canvas.bind("<Configure>", render)

    if region:
        x, y = int(region[0]), int(region[1])
    else:
        x, y = root.winfo_pointerxy()
    root.geometry(f"{img.width}x{img.height}+{x}+{y}")

    def close():
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", close)
    root.bind("<Control-c>", lambda _e: copy_image())
    root.deiconify()
    root.lift()
    root.focus_force()
    root.after(50, render)

    if cleanup:
        for p in (path, path + ".json"):
            try:
                os.remove(p)
            except OSError:
                pass

    root.mainloop()
    return 0


def run_pin(path):
    return run_image_window(path, "固定截图", cleanup=True)


def run_snip(out_path):
    child_log(out_path, "run_snip start")
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except OSError:
        pass

    import tkinter as tk
    from PIL import ImageGrab, ImageTk

    try:
        img = ImageGrab.grab()
        child_log(out_path, f"grab ok size={img.width}x{img.height}")
    except Exception as e:
        child_log(out_path, f"grab error={e}")
        raise
    root = tk.Tk()
    child_log(out_path, "tk ok")
    root.attributes("-fullscreen", True)
    root.attributes("-topmost", True)
    root.configure(cursor="cross")

    canvas = tk.Canvas(root, highlightthickness=0, cursor="cross")
    canvas.pack(fill="both", expand=True)

    tk_img = ImageTk.PhotoImage(img)
    canvas.create_image(0, 0, anchor="nw", image=tk_img)
    overlay = canvas.create_rectangle(
        0, 0, img.width, img.height, fill="black", stipple="gray25", outline=""
    )
    tip = canvas.create_text(
        img.width // 2,
        60,
        text="拖动鼠标框选区域，松开后可选择：翻译 / 固定。按 Esc 取消",
        fill="white",
        font=("Microsoft YaHei", 14),
    )

    translated_path = out_path + ".translated.png"
    error_path = out_path + ".error.txt"
    state = {
        "x0": 0,
        "y0": 0,
        "rect": None,
        "box": None,
        "action": None,
        "translated": False,
        "busy": None,
        "selection_image": None,
        "selection_photo": None,
        "toolbar": None,
        "translate_btn": None,
        "pin_btn": None,
        "cancel_btn": None,
    }

    def clear_selection():
        for key in ("rect", "toolbar", "translate_btn", "pin_btn", "cancel_btn"):
            item = state.get(key)
            if item:
                canvas.delete(item)
                state[key] = None
        state["box"] = None
        state["action"] = None
        canvas.itemconfigure(overlay, state="normal")
        canvas.itemconfigure(tip, state="normal")
        canvas.configure(cursor="cross")

    def finish(action):
        state["action"] = action
        root.quit()

    def save_selection(action):
        if not state["box"]:
            return False
        img.crop(state["box"]).save(out_path)
        try:
            with open(out_path + ".json", "w", encoding="utf-8") as f:
                json.dump({"box": list(state["box"]), "action": action}, f)
        except OSError:
            pass
        return True

    def set_button_enabled(item, enabled):
        if item:
            canvas.itemconfigure(item, fill=("#9aa0b3" if not enabled else "white"))

    def start_translate():
        if state["translated"] or state["action"] == "translate":
            return
        state["action"] = "translate"
        if not save_selection("translate"):
            finish("cancel")
            return
        if state["busy"] is None and state["box"]:
            x1, y1, x2, _y2 = state["box"]
            state["busy"] = canvas.create_text(
                x1 + 8,
                max(18, y1 - 22),
                text="正在翻译…",
                anchor="nw",
                fill="white",
                font=("Microsoft YaHei", 12, "bold"),
            )
        set_button_enabled(state.get("translate_btn"), False)
        poll_translation()

    def poll_translation():
        if os.path.exists(translated_path):
            show_translated()
            return
        if os.path.exists(error_path):
            try:
                with open(error_path, encoding="utf-8") as f:
                    msg = f.read().strip() or "翻译失败"
            except OSError:
                msg = "翻译失败"
            if state["busy"]:
                canvas.itemconfigure(state["busy"], text=msg, fill="#ffdddd")
            return
        root.after(300, poll_translation)

    def show_translated():
        from PIL import Image

        if state["busy"]:
            canvas.delete(state["busy"])
            state["busy"] = None
        state["translated"] = True
        x1, y1, x2, y2 = state["box"]
        translated = Image.open(translated_path).convert("RGB")
        state["selection_image"] = translated
        state["selection_photo"] = ImageTk.PhotoImage(translated)
        canvas.create_image(x1, y1, anchor="nw", image=state["selection_photo"])
        canvas.lift(state["rect"])
        for key in ("toolbar", "translate_btn", "pin_btn", "cancel_btn"):
            if state.get(key):
                canvas.lift(state[key])
        set_button_enabled(state.get("translate_btn"), False)

    def pin_current():
        if state["action"] == "pin":
            return
        if state["translated"] and os.path.exists(translated_path):
            state["action"] = "pin-translated"
        else:
            state["action"] = "pin"
            save_selection("pin")
        root.quit()

    def toolbar_pos(x1, y1, x2, y2):
        width, height = 320, 46
        x = max(12, min(x2 - width, img.width - width - 12))
        if x < 12:
            x = max(12, min(x1, img.width - width - 12))
        y = y2 + 10
        if y + height > img.height - 12:
            y = max(12, y1 - height - 10)
        return x, y, width, height

    def draw_toolbar():
        x1, y1, x2, y2 = state["box"]
        tx, ty, tw, th = toolbar_pos(x1, y1, x2, y2)
        state["toolbar"] = canvas.create_rectangle(
            tx,
            ty,
            tx + tw,
            ty + th,
            fill="#f7f7f8",
            outline="#d7d8df",
            width=1,
        )
        specs = [
            ("translate_btn", "翻译", "#5b5ce2", "white", lambda _a=None: start_translate(), "translate"),
            ("pin_btn", "固定", "#ffffff", "#242733", lambda _a=None: pin_current(), "pin"),
            ("cancel_btn", "取消", "#ffffff", "#d33", finish, "cancel"),
        ]
        bx = tx + 14
        for key, text, bg, fg, cb, action in specs:
            rect = canvas.create_rectangle(
                bx, ty + 9, bx + 86, ty + 37, fill=bg, outline="#d7d8df", width=1
            )
            label = canvas.create_text(
                bx + 43, ty + 23, text=text, fill=fg, font=("Microsoft YaHei", 10, "bold")
            )
            canvas.tag_bind(rect, "<Button-1>", lambda _e, a=action, fn=cb: fn(a))
            canvas.tag_bind(label, "<Button-1>", lambda _e, a=action, fn=cb: fn(a))
            state[key] = label
            bx += 98
        canvas.configure(cursor="arrow")

    def on_press(e):
        if state["box"]:
            return
        state["x0"], state["y0"] = e.x, e.y
        state["rect"] = canvas.create_rectangle(
            e.x, e.y, e.x, e.y, outline="#21d66b", width=3
        )

    def on_drag(e):
        if state["rect"] and not state["box"]:
            x = max(0, min(img.width, e.x))
            y = max(0, min(img.height, e.y))
            canvas.coords(state["rect"], state["x0"], state["y0"], x, y)

    def on_release(e):
        if state["box"]:
            return
        x1, x2 = sorted((state["x0"], e.x))
        y1, y2 = sorted((state["y0"], e.y))
        x1, x2 = max(0, x1), min(img.width, x2)
        y1, y2 = max(0, y1), min(img.height, y2)
        if x2 - x1 <= 5 or y2 - y1 <= 5:
            clear_selection()
            return
        state["box"] = (x1, y1, x2, y2)
        canvas.coords(state["rect"], x1, y1, x2, y2)
        canvas.itemconfigure(overlay, state="hidden")
        canvas.itemconfigure(tip, state="hidden")
        draw_toolbar()

    def cancel(_e=None):
        finish("cancel")

    canvas.bind("<ButtonPress-1>", on_press)
    canvas.bind("<B1-Motion>", on_drag)
    canvas.bind("<ButtonRelease-1>", on_release)
    root.bind("<Escape>", cancel)
    root.focus_force()
    root.after(100, root.focus_force)
    root.mainloop()
    child_log(out_path, f"mainloop end action={state['action']} box={state['box']}")

    if state["box"] and state["action"] in ("translate", "pin", "pin-translated"):
        if state["action"] == "pin-translated":
            try:
                import shutil

                shutil.copyfile(translated_path, out_path)
                with open(out_path + ".json", "w", encoding="utf-8") as f:
                    json.dump({"box": list(state["box"]), "action": "pin"}, f)
            except OSError:
                pass
        try:
            root.destroy()
        except Exception:
            pass
        return 0
    try:
        root.destroy()
    except Exception:
        pass
    return 1


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--pin":
        sys.exit(run_pin(sys.argv[2]))
    if len(sys.argv) >= 3 and sys.argv[1] == "--image":
        sys.exit(run_image_window(sys.argv[2], "截图翻译", cleanup=True))
    sys.exit(run_snip(sys.argv[1]) if len(sys.argv) > 1 else 1)
