# -*- coding: utf-8 -*-
"""翻译 + 语音工具的后台程序"""
import asyncio
import json
import os
import subprocess
import sys
import threading
import time
import uuid

from flask import Flask, request, jsonify, Response
from deep_translator import GoogleTranslator, MyMemoryTranslator
import edge_tts

import hotkey as hotkey_mod

# 桌面版启动时由 desktop.py 塞进来
WEBVIEW_WINDOW = None
SELECTION = None  # 划词翻译模块（desktop.py 注入），截图就地翻译时复用它的小弹窗

def _pick_data_dir():
    """生成的 MP3 跟着程序自己走：源码模式放项目目录，打包后放 exe 所在目录；
    只有 exe 目录写不进去（比如装进了 Program Files）才退到用户数据目录。"""
    if not getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(__file__))
    exe_dir = os.path.dirname(sys.executable)
    try:
        probe_dir = os.path.join(exe_dir, "audio_output")
        os.makedirs(probe_dir, exist_ok=True)
        probe = os.path.join(probe_dir, ".write_test")
        open(probe, "w").close()
        os.remove(probe)
        return exe_dir
    except OSError:
        return os.path.join(
            os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "TranslationTool"
        )


# 打包成 exe 后界面资源在 _MEIPASS
BASE_DIR = sys._MEIPASS if getattr(sys, "frozen", False) else os.path.dirname(os.path.abspath(__file__))
DATA_DIR = _pick_data_dir()
AUDIO_DIR = os.path.join(DATA_DIR, "audio_output")
os.makedirs(AUDIO_DIR, exist_ok=True)

app = Flask(__name__, static_folder=os.path.join(BASE_DIR, "static"), static_url_path="")

# ---------------- 设置 ----------------
SETTINGS_FILE = os.path.join(DATA_DIR, "settings.json")
DEFAULT_SETTINGS = {
    "target": "en",                      # 默认目标语言
    "voice": "zh-CN-XiaoxiaoNeural",     # 默认声音
    "rate": 0,                           # 默认语速
    "engine": "auto",                    # 翻译引擎：auto / google / bing / mymemory
    "autostart": False,                  # 开机自启
    "hotkey": "ctrl+alt+t",              # 截图翻译全局快捷键（空串=禁用）
    "snip_to_window": True,              # 截图翻译：True 弹到主窗口，False 就地弹小窗
    "selection_translate": False,        # 划词翻译开关
    "selection_require_ctrl": False,     # 划词时是否要按住 Ctrl
    "audio_dir": "",                     # 自定义语音保存目录（空=用程序默认 audio_output）
}


def load_settings():
    settings = dict(DEFAULT_SETTINGS)
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as f:
            saved = json.load(f)
        settings.update({k: saved[k] for k in DEFAULT_SETTINGS if k in saved})
    except (OSError, ValueError):
        pass
    return settings


SETTINGS_LOCK = threading.Lock()  # threaded=True 下防止两个保存请求互相覆盖/写坏文件


def save_settings(settings):
    # 原子写：先写临时文件再替换，任何时刻读到的都是完整文件
    tmp = SETTINGS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
    os.replace(tmp, SETTINGS_FILE)


def current_audio_dir():
    """当前实际用的语音保存目录：设置里指定了就用指定的（不可写则退默认），否则用程序默认。"""
    custom = (load_settings().get("audio_dir") or "").strip()
    if custom:
        try:
            os.makedirs(custom, exist_ok=True)
            return custom
        except OSError:
            pass
    return AUDIO_DIR


def apply_autostart(enable):
    """开机自启 = 注册表当前用户 Run 项。只在打包版操作——
    源码模式不碰注册表，避免误删已安装版本登记的自启项。"""
    if not getattr(sys, "frozen", False):
        return
    import winreg

    key = winreg.OpenKey(
        winreg.HKEY_CURRENT_USER,
        r"Software\Microsoft\Windows\CurrentVersion\Run",
        0,
        winreg.KEY_SET_VALUE,
    )
    try:
        if enable:
            winreg.SetValueEx(key, "TranslationTool", 0, winreg.REG_SZ, f'"{sys.executable}"')
        else:
            try:
                winreg.DeleteValue(key, "TranslationTool")
            except FileNotFoundError:
                pass
    finally:
        winreg.CloseKey(key)


# MyMemory 引擎要求地区化的语言代码
MYMEMORY_CODES = {
    "zh-CN": "zh-CN", "zh-TW": "zh-TW", "en": "en-GB", "ja": "ja-JP",
    "ko": "ko-KR", "fr": "fr-FR", "de": "de-DE", "es": "es-ES",
    "ru": "ru-RU", "pt": "pt-PT", "it": "it-IT", "vi": "vi-VN",
    "th": "th-TH", "ar": "ar-SA",
}


def smart_target(text):
    """划词/截图的默认翻译方向：外语统一翻成中文；中文内容才翻成设置的目标语言"""
    compact = "".join(text.split())
    cjk = sum(1 for ch in compact if "一" <= ch <= "鿿")
    if cjk / max(len(compact), 1) >= 0.25:
        return load_settings().get("target", "en")
    return "zh-CN"


_google_probe = {"t": 0.0, "ok": True}


def google_reachable():
    """探测谷歌翻译当前连不连得上（没开 VPN 时连不上）。结果缓存 2 分钟。"""
    now = time.time()
    if now - _google_probe["t"] < 120:
        return _google_probe["ok"]
    try:
        import requests

        requests.head("https://translate.google.com", timeout=2.5)
        ok = True
    except Exception:
        ok = False
    _google_probe.update(t=now, ok=ok)
    return ok


def _do_google(text, source, target):
    return GoogleTranslator(source=source, target=target).translate(text)


def _do_bing(text, source, target):
    import bing_translate

    return bing_translate.translate(text, source, target)


def translate_text(text, source="auto", target=None, engine=None):
    """统一翻译入口（页面、划词、截图都走这里）。返回 (ok, 译文或错误)。
    target 不传时自动判断：外语→中文，中文→设置的目标语言。
    engine=auto：谷歌连得上用谷歌，连不上自动换必应；单边失败再换另一边。"""
    text = (text or "").strip()
    if not text:
        return False, "没有可翻译的文字"
    s = load_settings()
    target = target or smart_target(text)
    engine = engine or s.get("engine", "auto")
    try:
        if engine == "mymemory":
            if source == "auto":
                # MyMemory 不支持自动检测，用必应顶上（国内也直连）
                return True, _do_bing(text, source, target)
            return True, MyMemoryTranslator(
                source=MYMEMORY_CODES.get(source, source),
                target=MYMEMORY_CODES.get(target, target),
            ).translate(text)
        if engine == "google":
            return True, _do_google(text, source, target)
        if engine == "bing":
            return True, _do_bing(text, source, target)
        # auto：按可达性排个先后，失败自动换另一个
        first, second = (_do_google, _do_bing) if google_reachable() else (_do_bing, _do_google)
        try:
            return True, first(text, source, target)
        except Exception:
            return True, second(text, source, target)
    except Exception as e:
        return False, f"翻译失败，请检查网络（{e}）"

def translate_lines(texts, target):
    """按行批量翻译：分块（防超长被拒）整批请求；行数对不上再并行逐行翻（兜底）"""
    from concurrent.futures import ThreadPoolExecutor

    def one(t):
        ok2, r2 = translate_text(t, target=target)
        return r2 if ok2 else t

    chunks, cur, size = [], [], 0
    for t in texts:
        if cur and size + len(t) + 1 > 4000:  # 谷歌单次约 5000 字上限，留余量
            chunks.append(cur)
            cur, size = [], 0
        cur.append(t)
        size += len(t) + 1
    if cur:
        chunks.append(cur)

    out = []
    for ch in chunks:
        ok, res = translate_text("\n".join(ch), target=target)
        parts = res.split("\n") if ok else []
        if ok and len(parts) == len(ch):
            out.extend(parts)
        else:
            with ThreadPoolExecutor(max_workers=6) as ex:
                out.extend(ex.map(one, ch))
    return out


# ---------------- 贴图翻译：把译文画回截图原位置 ----------------
_overlay_fonts = {}


def _overlay_font(size):
    if size not in _overlay_fonts:
        from PIL import ImageFont

        try:
            _overlay_fonts[size] = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", size)
        except OSError:
            _overlay_fonts[size] = ImageFont.load_default()
    return _overlay_fonts[size]


def _sample_bg(img, x1, y1, x2, y2):
    """估算一行文字的背景色：取该区域里出现最多的颜色（文字像素占少数，众数≈背景）"""
    region = img.crop((x1, y1, x2, y2))
    if region.width * region.height > 1024:
        region = region.resize((64, 16))
    colors = region.getcolors(64 * 16 + 1)
    if colors:
        return max(colors, key=lambda c: c[0])[1]
    return (255, 255, 255)


def build_overlay_image(img, lines, translations):
    """像参考效果那样：每行译文按原文行的坐标"贴"回截图（背景取行内底色、字号自适应）"""
    from PIL import ImageDraw

    img = img.copy()
    draw = ImageDraw.Draw(img)
    for (box, _t), trans in zip(lines, translations):
        trans = (trans or "").strip()
        xs = [int(p[0]) for p in box]
        ys = [int(p[1]) for p in box]
        x1, y1 = max(0, min(xs)), max(0, min(ys))
        x2, y2 = min(img.width, max(xs)), min(img.height, max(ys))
        if not trans or x2 - x1 < 4 or y2 - y1 < 4:
            continue
        bg = _sample_bg(img, x1, y1, x2, y2)
        draw.rectangle([x1, y1, x2, y2], fill=bg)
        lum = 0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]
        fg = (245, 245, 245) if lum < 140 else (18, 18, 18)
        h = y2 - y1
        size = max(9, int(h * 0.72))
        while size > 9 and draw.textlength(trans, font=_overlay_font(size)) > (x2 - x1):
            size -= 1
        draw.text((x1 + 1, y1 + (h - size) // 2 - 1), trans, font=_overlay_font(size), fill=fg)
    return img


_SQUASH_RE = None


def fix_spaces(line):
    """OCR 识别英文经常把单词粘在一起（如 Settingsandprivacy），用词频库拆回来。
    只处理 13 个字母以上的可疑长串，不动标点、数字和正常单词。"""
    global _SQUASH_RE
    import re

    if _SQUASH_RE is None:
        _SQUASH_RE = re.compile(r"[A-Za-z]{13,}")

    def repl(m):
        try:
            import wordninja

            parts = wordninja.split(m.group(0))
            return " ".join(parts) if parts else m.group(0)
        except Exception:
            return m.group(0)

    return _SQUASH_RE.sub(repl, line)


# ---------------- 截图 OCR ----------------
_ocr_engine = None
_ocr_lock = threading.Lock()
SNIP_LOCK = threading.Lock()  # 同一时刻只允许一个截图流程


def get_ocr():
    """文字识别引擎第一次用到才加载（初始化要一两秒），加锁防并发重复初始化"""
    global _ocr_engine
    with _ocr_lock:
        if _ocr_engine is None:
            from rapidocr_onnxruntime import RapidOCR

            _ocr_engine = RapidOCR()
    return _ocr_engine


def ocr_image(path):
    result, _ = get_ocr()(path)
    if not result:
        return ""
    return "\n".join(line[1] for line in result)


def snip_command(out_path):
    if getattr(sys, "frozen", False):
        return [sys.executable, "--snip", out_path]
    return [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "snip.py"), out_path]


@app.route("/")
def index():
    return app.send_static_file("index.html")


@app.route("/api/translate", methods=["POST"])
def translate():
    data = request.get_json(force=True)
    text = (data.get("text") or "").strip()
    if not text:
        return jsonify({"error": "请输入要翻译的内容"}), 400
    source = data.get("source") or "auto"
    target = data.get("target") or "en"
    ok, result = translate_text(text, source=source, target=target)
    if ok:
        return jsonify({"translated": result})
    return jsonify({"error": result}), 500


def _synth_tts(data):
    """根据请求里的 text/voice/rate 合成语音，返回 (音频字节, 错误信息)。
    生成到临时文件读出后立即删掉——朗读/试听不在语音文件夹留任何文件。"""
    text = (data.get("text") or "").strip()
    if not text:
        return None, "请输入要转成语音的内容"
    voice = data.get("voice") or "zh-CN-XiaoxiaoNeural"
    try:
        rate = int(data.get("rate") or 0)
    except (TypeError, ValueError):
        rate = 0
    rate = max(-50, min(100, rate))
    rate_str = f"{'+' if rate >= 0 else ''}{rate}%"

    tmp = os.path.join(DATA_DIR, f"_tts_{uuid.uuid4().hex}.mp3")
    try:
        async def gen():
            await edge_tts.Communicate(text, voice, rate=rate_str).save(tmp)

        asyncio.run(gen())
        with open(tmp, "rb") as f:
            return f.read(), None
    except Exception as e:
        return None, f"生成语音失败，请检查网络后重试（{e}）"
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


@app.route("/api/tts", methods=["POST"])
def tts():
    """朗读/试听：只把音频流回给页面播放，不往语音文件夹写文件。"""
    audio_bytes, err = _synth_tts(request.get_json(force=True))
    if err:
        return jsonify({"error": err}), (400 if err.startswith("请输入") else 500)
    return Response(audio_bytes, mimetype="audio/mpeg")


@app.route("/api/save-tts", methods=["POST"])
def save_tts():
    """点了"下载/保存"才执行：把音频存进当前语音文件夹，返回文件名和所在目录。"""
    audio_bytes, err = _synth_tts(request.get_json(force=True))
    if err:
        return jsonify({"error": err}), (400 if err.startswith("请输入") else 500)
    d = current_audio_dir()
    filename = f"voice_{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}.mp3"
    path = os.path.join(d, filename)
    try:
        os.makedirs(d, exist_ok=True)
        with open(path, "wb") as f:
            f.write(audio_bytes)
        return jsonify({"ok": True, "filename": filename, "dir": d})
    except OSError as e:
        return jsonify({"error": f"保存失败（{e}）"}), 500


@app.route("/api/choose-audio-dir", methods=["POST"])
def choose_audio_dir_api():
    """桌面版弹出"选文件夹"对话框，把选中的目录设为语音保存位置。"""
    win = WEBVIEW_WINDOW
    if win is None:
        return jsonify({"error": "网页版不支持选文件夹，请在桌面版软件里设置"}), 400
    try:
        import webview

        result = win.create_file_dialog(
            webview.FOLDER_DIALOG, directory=current_audio_dir()
        )
    except Exception as e:
        return jsonify({"error": f"打开选择窗口失败（{e}）"}), 500
    if not result:
        return jsonify({"cancelled": True})
    folder = result[0] if isinstance(result, (list, tuple)) else result
    # 校验目录可写，不可写不保存（免得以后存语音全失败）
    try:
        os.makedirs(folder, exist_ok=True)
        probe = os.path.join(folder, ".write_test")
        open(probe, "w").close()
        os.remove(probe)
    except OSError as e:
        return jsonify({"error": f"这个文件夹没法写入，换一个（{e}）"}), 400
    try:
        with SETTINGS_LOCK:
            s = load_settings()
            s["audio_dir"] = folder
            save_settings(s)
    except OSError as e:
        return jsonify({"error": f"保存设置失败（{e}）"}), 500
    return jsonify({"ok": True, "dir": folder})


def _snip_and_ocr(restore=True):
    """跑一次 最小化→截图选区→OCR。
    返回 dict：ok / cancelled / error / text / lines[(框,文字)…] / region[屏幕坐标] / img(PIL)"""
    res = {"ok": False, "cancelled": False, "error": "",
           "text": "", "lines": [], "region": None, "img": None}
    tmp_png = os.path.join(DATA_DIR, f"snip_{uuid.uuid4().hex}.png")
    win = WEBVIEW_WINDOW
    if SELECTION:
        try:
            SELECTION.suspend(True)  # 截图选区时挂起划词，免得拖框被当成划词
        except Exception:
            pass
    if win:
        try:
            win.minimize()
            time.sleep(0.4)  # 等最小化动画结束再抓屏
        except Exception:
            pass
    try:
        proc = subprocess.run(snip_command(tmp_png), timeout=180)
    except Exception as e:
        res["error"] = f"截图工具启动失败（{e}）"
        return res
    finally:
        if SELECTION:
            try:
                SELECTION.suspend(False)
            except Exception:
                pass
        if win and restore:
            try:
                win.restore()
            except Exception:
                pass
    if proc.returncode != 0 or not os.path.exists(tmp_png):
        res["cancelled"] = True
        return res
    try:
        from PIL import Image as PILImage
        import numpy as np

        with PILImage.open(tmp_png) as im:
            res["img"] = im.convert("RGB")
        try:
            with open(tmp_png + ".json", encoding="utf-8") as f:
                res["region"] = json.load(f).get("box")
        except (OSError, ValueError):
            pass
        if SELECTION:  # 框选已完成，立刻在截图位置提示"正在翻译"
            try:
                SELECTION.show_busy(res["region"])
            except Exception:
                pass
        # 小图先放大 2 倍再识别（屏幕小字直接识别容易丢），识别完坐标缩回原尺度
        ocr_img, scale = res["img"], 1
        if max(ocr_img.width, ocr_img.height) < 1100:
            scale = 2
            ocr_img = ocr_img.resize((ocr_img.width * 2, ocr_img.height * 2), PILImage.LANCZOS)
        arr = np.ascontiguousarray(np.array(ocr_img)[:, :, ::-1])  # RGB→BGR
        ocr_result, _ = get_ocr()(arr)
        res["lines"] = [
            ([[p[0] / scale, p[1] / scale] for p in line[0]], fix_spaces(line[1]))
            for line in (ocr_result or [])
        ]
        res["text"] = "\n".join(t for _, t in res["lines"])
    except Exception as e:
        res["error"] = f"文字识别失败（{e}）"
        return res
    finally:
        for p in (tmp_png, tmp_png + ".json"):
            try:
                os.remove(p)
            except OSError:
                pass
    if not res["text"].strip():
        res["error"] = "没识别到文字，请框选更清晰的文字区域"
    else:
        res["ok"] = True
    return res


def _hide_busy():
    if SELECTION:
        try:
            SELECTION.hide_busy()
        except Exception:
            pass


def _inplace_translate_overlay(res):
    """就地贴图翻译：译文按行贴回截图原位置，整块浮窗精准盖在原区域上"""
    target = smart_target(res["text"])
    trans = translate_lines([t for _, t in res["lines"]], target)
    if res["img"] is not None and res["region"]:
        overlay = build_overlay_image(res["img"], res["lines"], trans)
        SELECTION.show_overlay(overlay, res["region"], "\n".join(trans))
    else:
        SELECTION.show_result_popup("\n".join(trans))


@app.route("/api/snip", methods=["POST"])
def snip():
    """界面按钮触发的截图翻译。同一时刻只允许一个截图流程。
    按设置 snip_to_window 决定：True 把原文交给页面在窗口里翻译；False 就地贴图翻译。"""
    if not SNIP_LOCK.acquire(blocking=False):
        return jsonify({"error": "已经有一个截图在进行中"}), 409
    try:
        to_window = load_settings().get("snip_to_window", True)
        res = _snip_and_ocr(restore=True)
        if res["cancelled"]:
            return jsonify({"cancelled": True})
        if not res["ok"]:
            _hide_busy()
            status = 400 if res["error"].startswith("没识别到") else 500
            return jsonify({"error": res["error"]}), status
        if not to_window and SELECTION:
            _inplace_translate_overlay(res)
            return jsonify({"inplace": True})
        _hide_busy()
        return jsonify({"text": res["text"]})
    finally:
        _hide_busy()
        SNIP_LOCK.release()


def _bring_window_front(win):
    try:
        win.show()  # 窗口可能收在托盘里（隐藏状态），先显示出来
        win.restore()
        win.on_top = True
        time.sleep(0.2)
        win.on_top = False
    except Exception:
        pass


def hotkey_snip():
    """全局快捷键触发的截图翻译。按设置决定弹到主窗口还是就地贴图翻译。"""
    if not SNIP_LOCK.acquire(blocking=False):
        return
    try:
        res = _snip_and_ocr(restore=False)
        if res["cancelled"]:
            return  # 用户取消：什么都不打扰
        to_window = load_settings().get("snip_to_window", True)
        win = WEBVIEW_WINDOW

        if not res["ok"]:  # 识别失败/没识别到文字
            _hide_busy()
            if to_window and win:
                _bring_window_front(win)
                win.evaluate_js(f"window.snipHotkeyError({json.dumps(res['error'])})")
            elif SELECTION and res["error"]:
                SELECTION.show_result_popup("⚠ " + res["error"])
            return

        if to_window and win:
            # 弹到主窗口：填进翻译页并自动翻译
            _hide_busy()
            _bring_window_front(win)
            win.evaluate_js(f"window.snipFromHotkey({json.dumps(res['text'])})")
        elif SELECTION:
            _inplace_translate_overlay(res)
    except Exception:
        pass
    finally:
        _hide_busy()
        SNIP_LOCK.release()


VALID_ENGINES = {"auto", "google", "bing", "mymemory"}
VALID_TARGETS = set(MYMEMORY_CODES)  # 即支持的 14 种语言代码
VALID_VOICES = {
    "zh-CN-XiaoxiaoNeural", "zh-CN-XiaoyiNeural", "zh-CN-YunxiNeural", "zh-CN-YunjianNeural",
    "zh-TW-HsiaoChenNeural", "zh-HK-HiuMaanNeural",
    "en-US-AriaNeural", "en-US-GuyNeural", "en-GB-SoniaNeural",
    "ja-JP-NanamiNeural", "ko-KR-SunHiNeural", "fr-FR-DeniseNeural",
    "de-DE-KatjaNeural", "es-ES-ElviraNeural", "ru-RU-SvetlanaNeural",
}


@app.route("/api/settings", methods=["GET", "POST"])
def settings_api():
    if request.method == "GET":
        s = load_settings()
        s["audio_dir_effective"] = current_audio_dir()  # 前端显示"语音实际存哪"
        return jsonify(s)
    data = request.get_json(force=True)

    # 逐项校验，坏值一律 400，绝不落盘（落盘的坏值每次启动都会复现）
    validated = {}
    if "target" in data:
        if data["target"] not in VALID_TARGETS:
            return jsonify({"error": "目标语言不在支持列表里"}), 400
        validated["target"] = data["target"]
    if "engine" in data:
        if data["engine"] not in VALID_ENGINES:
            return jsonify({"error": "翻译引擎不在支持列表里"}), 400
        validated["engine"] = data["engine"]
    if "voice" in data:
        if data["voice"] not in VALID_VOICES:
            return jsonify({"error": "声音不在支持列表里"}), 400
        validated["voice"] = data["voice"]
    if "rate" in data:
        try:
            validated["rate"] = max(-50, min(100, int(data["rate"])))
        except (TypeError, ValueError):
            return jsonify({"error": "语速必须是数字"}), 400
    for bkey, bname in (("autostart", "开机自启"), ("snip_to_window", "截图弹窗方式"),
                        ("selection_translate", "划词翻译"), ("selection_require_ctrl", "划词按住Ctrl")):
        if bkey in data:
            if not isinstance(data[bkey], bool):
                return jsonify({"error": f"{bname}的值必须是开/关"}), 400
            validated[bkey] = data[bkey]
    if "hotkey" in data:
        hk = data["hotkey"]
        if not isinstance(hk, str):
            return jsonify({"error": "快捷键格式不对"}), 400
        hk = hk.strip().lower()
        if hk:
            try:
                hotkey_mod.parse_hotkey(hk)
            except ValueError as e:
                return jsonify({"error": f"快捷键格式不对（{e}）"}), 400
            if not hotkey_mod.test_available(hk):
                return jsonify({"error": "这个快捷键被其他软件占用了，换一个试试"}), 400
        validated["hotkey"] = hk
    if "audio_dir" in data:
        if not isinstance(data["audio_dir"], str):
            return jsonify({"error": "语音保存位置格式不对"}), 400
        validated["audio_dir"] = data["audio_dir"].strip()

    try:
        with SETTINGS_LOCK:
            settings = load_settings()
            settings.update(validated)
            save_settings(settings)
    except OSError as e:
        return jsonify({"error": f"保存设置失败（{e}）"}), 500

    # 注册表失败不算保存失败：文件已落盘，只提示自启没设置上
    note = ""
    try:
        apply_autostart(bool(settings.get("autostart")))
    except OSError as e:
        note = f"设置已保存，但开机自启没设置成功（{e}）"
    if settings.get("autostart") and not getattr(sys, "frozen", False):
        note = "开机自启只对安装版生效（当前是源码模式）"
    if "hotkey" in validated:
        hotkey_mod.reregister()
        if validated["hotkey"] and not hotkey_mod.is_running():
            note = (note + "；" if note else "") + "快捷键在桌面版软件里生效（网页版不支持）"
    return jsonify({"ok": True, "note": note})


@app.route("/api/open-audio-dir", methods=["POST"])
def open_audio_dir():
    try:
        d = current_audio_dir()
        os.makedirs(d, exist_ok=True)
        os.startfile(d)
        return jsonify({"ok": True})
    except OSError as e:
        return jsonify({"error": f"打开文件夹失败（{e}）"}), 500


if __name__ == "__main__":
    print("翻译工具已启动，请在浏览器打开 http://127.0.0.1:8765")
    app.run(host="127.0.0.1", port=8765, threaded=True)
