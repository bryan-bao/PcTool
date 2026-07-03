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
import doc_translate

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
DOC_UPLOAD_DIR = os.path.join(DATA_DIR, "doc_uploads")
os.makedirs(AUDIO_DIR, exist_ok=True)
os.makedirs(DOC_UPLOAD_DIR, exist_ok=True)

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


def debug_log(msg):
    try:
        with open(os.path.join(DATA_DIR, "debug_snip.log"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


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


def smart_screenshot_target(text):
    """Screenshots often contain mixed Chinese comments plus English UI/code.
    If there is clear English content, prefer translating the screenshot to Chinese.
    """
    compact = "".join((text or "").split())
    latin = sum(1 for ch in compact if ("A" <= ch <= "Z") or ("a" <= ch <= "z"))
    cjk = sum(1 for ch in compact if "一" <= ch <= "鿿")
    if latin >= 8 and latin >= cjk * 0.25:
        return "zh-CN"
    return smart_target(text)


_google_probe = {"t": 0.0, "ok": True}
_google_fail = {"t": 0.0}


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


def _google_recently_failed():
    return time.time() - _google_fail["t"] < 120


def _mark_google_failed():
    _google_fail["t"] = time.time()


def translate_text_raw(text, source="auto", target=None, engine=None, prefer_quality=True):
    """Low-level network translation entry. Returns (ok, text_or_error).
    Higher-level user actions should call translate_text for accuracy fixes.
    """
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
        # Natural-language quality is better with Google; fall back to Bing when
        # Google fails or was recently unavailable.
        first, second = (_do_google, _do_bing) if prefer_quality and not _google_recently_failed() else (_do_bing, _do_google)
        try:
            return True, first(text, source, target)
        except Exception:
            if first is _do_google:
                _mark_google_failed()
            return True, second(text, source, target)
    except Exception as e:
        return False, f"翻译失败，请检查网络（{e}）"


def translate_text(text, source="auto", target=None, engine=None):
    """统一精准翻译入口（页面、划词、截图都走这里）。返回 (ok, 译文或错误)。
    target 不传时自动判断：外语→中文，中文→设置的目标语言。
    engine=auto：精准优先；不可用时自动回退直连引擎。"""
    text = (text or "").strip()
    if not text:
        return False, "没有可翻译的文字"
    target = target or smart_target(text)
    if source == "auto" and engine is None:
        return translate_selection_text(text, target=target)

    ok, res = translate_text_raw(text, source=source, target=target, engine=engine, prefer_quality=True)
    if ok and target == "zh-CN":
        improved, _fixed = improve_screenshot_translations([text], [res], target)
        res = improved[0]
    return ok, res

def warm_translation():
    """Warm the active translation engine used by screenshots and selection."""
    engine = load_settings().get("engine", "auto")
    if engine not in ("auto", "bing"):
        return
    try:
        import bing_translate

        t0 = time.perf_counter()
        bing_translate.warmup()
        debug_log(f"translation warmup ok elapsed={time.perf_counter() - t0:.2f}s")
    except Exception as e:
        debug_log(f"translation warmup failed={e}")


def translate_lines(texts, target):
    """按行批量翻译，返回 (译文列表, 没翻成的行数)。
    分块（防超长被拒）整批请求；行数对不上再并行逐行翻（兜底）。
    翻译失败的行退回原文、并计入"没翻成"——好让文档翻译能识别"整篇没翻"（断网/限流时
    悄悄退回原文）并报错，而不是生成一份看着成功、实则一字没翻的文件。"""
    from concurrent.futures import ThreadPoolExecutor

    def one(t):
        ok2, r2 = translate_text_raw(t, target=target, prefer_quality=True)
        # 真翻成才算成功；失败、或译文与原文完全一样（基本是没翻），都算没翻成
        if ok2 and r2 != t:
            return r2, True
        return t, False

    chunks, cur, size = [], [], 0
    for t in texts:
        if cur and size + len(t) + 1 > 4000:  # 谷歌单次约 5000 字上限，留余量
            chunks.append(cur)
            cur, size = [], 0
        cur.append(t)
        size += len(t) + 1
    if cur:
        chunks.append(cur)

    out, failed = [], 0
    for ch in chunks:
        ok, res = translate_text_raw("\n".join(ch), target=target, prefer_quality=True)
        parts = res.split("\n") if ok else []
        if ok and len(parts) == len(ch):
            out.extend(parts)  # 整批成功：正常路径，按成功计
        else:
            with ThreadPoolExecutor(max_workers=6) as ex:
                for text, good in ex.map(one, ch):
                    out.append(text)
                    if not good:
                        failed += 1
    return out, failed


_LINE_MARK_RE = None


def translate_screenshot_lines(texts, target):
    """Fast path for screenshot OCR lines.
    Code screenshots often contain punctuation-heavy lines. Generic translate_lines
    may fail to split the result by newline and then fall back to many per-line
    requests. Markers keep a single request splittable without that slow fallback.
    """
    global _LINE_MARK_RE
    import re

    if not texts:
        return []
    if len(texts) == 1:
        ok, res = translate_text_raw(texts[0], target=target, prefer_quality=True)
        return [res if ok else texts[0]]
    if _LINE_MARK_RE is None:
        _LINE_MARK_RE = re.compile(r"@@TT(\d+)@@\s*(.*?)(?=\s*@@TT\d+@@|$)", re.S)

    payload = "\n".join(f"@@TT{i}@@ {t}" for i, t in enumerate(texts))
    ok, res = translate_text_raw(payload, target=target, prefer_quality=True)
    if not ok:
        return list(texts)

    found = {int(i): value.strip() for i, value in _LINE_MARK_RE.findall(res)}
    if len(found) >= max(1, int(len(texts) * 0.7)):
        return [found.get(i, texts[i]) for i in range(len(texts))]

    parts = res.split("\n")
    if len(parts) == len(texts):
        return [re.sub(r"^@@TT\d+@@\s*", "", p).strip() for p in parts]
    return list(texts)


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


_SCREENSHOT_TERM_MAP = {
    "file": "文件",
    "edit": "编辑",
    "selection": "选择",
    "select": "选择",
    "view": "查看",
    "go": "前往",
    "run": "运行",
    "terminal": "终端",
    "settings": "设置",
    "setting": "设置",
    "preferences": "首选项",
    "keyboard shortcuts": "键盘快捷键",
    "command palette": "命令面板",
    "privacy": "隐私",
    "help": "帮助",
    "window": "窗口",
    "workspace": "工作区",
    "folder": "文件夹",
    "new file": "新建文件",
    "new folder": "新建文件夹",
    "rename": "重命名",
    "new": "新建",
    "open": "打开",
    "save": "保存",
    "save as": "另存为",
    "close": "关闭",
    "copy": "复制",
    "paste": "粘贴",
    "cut": "剪切",
    "undo": "撤销",
    "redo": "重做",
    "delete": "删除",
    "remove": "移除",
    "cancel": "取消",
    "ok": "确定",
    "yes": "是",
    "no": "否",
    "apply": "应用",
    "search": "搜索",
    "find": "查找",
    "replace": "替换",
    "explorer": "资源管理器",
    "source control": "源代码管理",
    "extensions": "扩展",
    "problems": "问题",
    "output": "输出",
    "tasks": "任务",
    "debugger": "调试器",
    "breakpoint": "断点",
    "watch": "监视",
    "call stack": "调用堆栈",
    "variables": "变量",
    "download": "下载",
    "upload": "上传",
    "install": "安装",
    "update": "更新",
    "reload": "重新加载",
    "refresh": "刷新",
    "enable": "启用",
    "disable": "禁用",
    "configure": "配置",
    "debug": "调试",
    "start": "启动",
    "stop": "停止",
    "pause": "暂停",
    "continue": "继续",
    "next": "下一步",
    "previous": "上一步",
    "back": "返回",
    "finish": "完成",
    "source": "源",
    "target": "目标",
    "language": "语言",
    "translation": "翻译",
    "translate": "翻译",
    "repository": "仓库",
    "repo": "仓库",
    "commit": "提交",
    "branch": "分支",
    "pull": "拉取",
    "push": "推送",
    "clone": "克隆",
    "merge": "合并",
    "conflict": "冲突",
    "changes": "更改",
    "modified": "已修改",
    "staged": "已暂存",
    "unstaged": "未暂存",
    "error": "错误",
    "warning": "警告",
    "information": "信息",
    "success": "成功",
    "failed": "失败",
    "login": "登录",
    "logout": "退出登录",
    "account": "账号",
    "password": "密码",
    "username": "用户名",
    "email": "邮箱",
    "home": "首页",
    "about": "关于",
}


def _looks_untranslated_english(src, dst):
    import re

    src_clean = re.sub(r"[^A-Za-z0-9]+", "", src or "").lower()
    dst_clean = re.sub(r"[^A-Za-z0-9]+", "", dst or "").lower()
    if not src_clean:
        return False
    if src_clean == dst_clean:
        return True
    cjk = sum(1 for ch in (dst or "") if "一" <= ch <= "鿿")
    latin = sum(1 for ch in (dst or "") if ("A" <= ch <= "Z") or ("a" <= ch <= "z"))
    return cjk == 0 and latin >= max(3, len(dst_clean) // 2)


def _term_fallback(text):
    import re

    raw = (text or "").strip()
    key = re.sub(r"\s+", " ", raw).lower().strip(" :：-_/|")
    if key in _SCREENSHOT_TERM_MAP:
        return _SCREENSHOT_TERM_MAP[key]
    words = re.findall(r"[A-Za-z]+", raw)
    if 1 <= len(words) <= 4 and len("".join(words)) <= 28:
        mapped = [_SCREENSHOT_TERM_MAP.get(w.lower()) for w in words]
        if all(mapped):
            return " ".join(mapped)
    return None


_CODE_TERM_REPLACEMENTS = [
    ("GetComponentsInChildren", "获取子对象组件"),
    ("GetRootGameObjects", "获取根游戏对象"),
    ("SerializedObject", "序列化对象"),
    ("GameObject", "游戏对象"),
    ("GameEntry", "游戏入口"),
    ("SetString", "设置字符串"),
    ("SetBool", "设置布尔值"),
    ("SetInt", "设置整数"),
    ("SetVector3", "设置三维向量"),
    ("SetEnum", "设置枚举"),
    ("ToArray", "转数组"),
    ("Scene", "场景"),
    ("Vector3", "三维向量"),
]

_CODE_PHRASE_REPLACEMENTS = [
    ("not found in scene", "场景中未找到"),
    ("must be unique", "必须唯一"),
    ("there are", "存在"),
    ("write params", "写入参数"),
    ("find the unique", "找到唯一的"),
]

_CODE_WORD_MAP = {
    "public": "公共",
    "private": "私有",
    "protected": "受保护",
    "internal": "内部",
    "static": "静态",
    "class": "类",
    "struct": "结构体",
    "enum": "枚举",
    "void": "无返回",
    "bool": "布尔",
    "boolean": "布尔",
    "string": "字符串",
    "int": "整数",
    "float": "浮点数",
    "double": "双精度",
    "var": "变量",
    "new": "新建",
    "return": "返回",
    "if": "如果",
    "else": "否则",
    "true": "真",
    "false": "假",
    "null": "空",
    "using": "使用",
    "namespace": "命名空间",
    "readonly": "只读",
    "override": "重写",
    "async": "异步",
    "await": "等待",
}


def _is_code_like(text):
    import re

    raw = text or ""
    if re.search(r"[{}();=<>]|\.\w+\(|//|^\s*(public|private|protected|var|if|return|class|using)\b", raw):
        return True
    return bool(re.search(r"\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*|\([^)]*\))", raw))


def _comment_text(text):
    import re

    raw = (text or "").strip()
    m = re.match(r"^/{2,3}\s*(.*)$", raw)
    if not m:
        return ""
    value = re.sub(r"</?summary>|</?\w+[^>]*>", " ", m.group(1), flags=re.I).strip(" /")
    letters = sum(1 for ch in value if ("A" <= ch <= "Z") or ("a" <= ch <= "z"))
    return value if letters >= 4 else ""


def _quoted_english_spans(text):
    import re

    spans = []
    for m in re.finditer(r'"([^"\n]{4,})"', text or ""):
        value = m.group(1)
        letters = sum(1 for ch in value if ("A" <= ch <= "Z") or ("a" <= ch <= "z"))
        if letters >= 4 and " " in value:
            spans.append((m.start(1), m.end(1), value))
    return spans


def _local_code_translate(text):
    import re

    out = text or ""
    for src, dst in _CODE_PHRASE_REPLACEMENTS:
        out = re.sub(re.escape(src), dst, out, flags=re.I)
    for src, dst in _CODE_TERM_REPLACEMENTS:
        out = out.replace(src, dst)
    for src, dst in _CODE_WORD_MAP.items():
        out = re.sub(rf"\b{re.escape(src)}\b", dst, out, flags=re.I)
    return out


def translate_screenshot_ocr_lines(sources, target):
    """Translate screenshot OCR lines quickly.
    For code-heavy screenshots, translating the whole code line is slow and often
    inaccurate. Keep structure local, translate comments/phrases, and batch only
    natural-language lines through the network.
    """
    if target != "zh-CN":
        trans = translate_screenshot_lines(sources, target)
        return improve_screenshot_translations(sources, trans, target)

    out = [None] * len(sources)
    requests = []
    for i, src in enumerate(sources):
        if _is_code_like(src):
            comment = _comment_text(src)
            if comment:
                requests.append((i, "comment", comment))
                out[i] = _local_code_translate(src)
                continue
            spans = _quoted_english_spans(src)
            if spans:
                out[i] = _local_code_translate(src)
                for span_index, (_a, _b, value) in enumerate(spans[:2]):
                    requests.append((i, f"quote:{span_index}", value))
                continue
            out[i] = _local_code_translate(src)
        else:
            requests.append((i, "line", src))
            out[i] = src

    if requests:
        translated = translate_screenshot_lines([item[2] for item in requests], target)
        for (i, kind, raw), value in zip(requests, translated):
            if kind == "line" or kind == "comment":
                out[i] = value
            elif kind.startswith("quote:") and value:
                local_raw = _local_code_translate(raw)
                if raw in out[i]:
                    out[i] = out[i].replace(raw, value, 1)
                elif local_raw in out[i]:
                    out[i] = out[i].replace(local_raw, value, 1)

    trans, fixed = improve_screenshot_translations(sources, out, target)
    code_fixed = sum(1 for src, dst in zip(sources, trans) if src != dst and _is_code_like(src))
    return trans, fixed + code_fixed


def translate_selection_text(text, target=None):
    """Translate selected text. Code selections use the same code-aware path as screenshots."""
    text = (text or "").strip()
    if not text:
        return False, "没有可翻译的文字"

    raw_lines = [line.strip() for line in text.splitlines() if line.strip()]
    code_like = any(_is_code_like(line) for line in raw_lines)
    lines = raw_lines if code_like else [fix_spaces(line) for line in raw_lines]
    if code_like:
        target = target or smart_screenshot_target(text)
        trans, _fixed = translate_screenshot_ocr_lines(lines, target)
        return True, "\n".join(trans)

    target = target or smart_target(text)
    ok, res = translate_text_raw(text, target=target, prefer_quality=True)
    if ok and target == "zh-CN":
        improved, _fixed = improve_screenshot_translations([text], [res], target)
        res = improved[0]
        if _looks_untranslated_english(text, res):
            local = _term_fallback(text)
            if local:
                res = local
    return ok, res


def translate_best_text(text, source="auto", target=None, engine=None):
    """Highest-accuracy user-facing translation path for the main translate box."""
    text = (text or "").strip()
    if not text:
        return False, "没有可翻译的文字"
    target = target or smart_target(text)

    raw_lines = [line.strip() for line in text.splitlines() if line.strip()]
    if any(_is_code_like(line) for line in raw_lines):
        trans, _fixed = translate_screenshot_ocr_lines(raw_lines, target)
        return True, "\n".join(trans)

    ok, res = translate_text_raw(
        text,
        source=source or "auto",
        target=target,
        engine=engine,
        prefer_quality=True,
    )
    if ok and target == "zh-CN":
        improved, _fixed = improve_screenshot_translations([text], [res], target)
        res = improved[0]
        if _looks_untranslated_english(text, res):
            local = _term_fallback(text)
            if local:
                res = local
    return ok, res


def improve_screenshot_translations(sources, translations, target):
    if target != "zh-CN":
        return translations, 0
    fixed = list(translations)
    changed = 0
    for i, (src, dst) in enumerate(zip(sources, fixed)):
        if not _looks_untranslated_english(src, dst):
            continue
        local = _term_fallback(src)
        if local:
            fixed[i] = local
            changed += 1
    return fixed, changed


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


def pin_command(path):
    if getattr(sys, "frozen", False):
        return [sys.executable, "--pin", path]
    return [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "snip.py"), "--pin", path]


def start_pin_window(path):
    debug_log(f"start_pin_window path={path} exists={os.path.exists(path)}")
    out = os.path.join(DATA_DIR, "pin_window_stdout.log")
    err = os.path.join(DATA_DIR, "pin_window_stderr.log")
    with open(out, "ab") as fo, open(err, "ab") as fe:
        p = subprocess.Popen(pin_command(path), stdout=fo, stderr=fe, close_fds=True)
    debug_log(f"pin_window pid={p.pid}")


def image_window_command(path):
    if getattr(sys, "frozen", False):
        return [sys.executable, "--image", path]
    return [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "snip.py"), "--image", path]


def start_image_window(path):
    debug_log(f"start_image_window path={path} exists={os.path.exists(path)}")
    out = os.path.join(DATA_DIR, "image_window_stdout.log")
    err = os.path.join(DATA_DIR, "image_window_stderr.log")
    with open(out, "ab") as fo, open(err, "ab") as fe:
        p = subprocess.Popen(image_window_command(path), stdout=fo, stderr=fe, close_fds=True)
    debug_log(f"image_window pid={p.pid}")


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
    ok, result = translate_best_text(text, source=source, target=target)
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
    tmp_png = os.path.join(DATA_DIR, f"snip_{uuid.uuid4().hex}.png")
    res = {"ok": False, "cancelled": False, "error": "", "action": "translate", "path": tmp_png,
           "text": "", "lines": [], "region": None, "img": None}
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
        proc = subprocess.Popen(
            snip_command(tmp_png),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        handled_translate = False
        started_at = time.time()
        while proc.poll() is None:
            if not handled_translate and os.path.exists(tmp_png) and os.path.exists(tmp_png + ".json"):
                try:
                    with open(tmp_png + ".json", encoding="utf-8") as f:
                        meta = json.load(f)
                except (OSError, ValueError):
                    meta = {}
                if (meta.get("action") or "") == "translate":
                    handled_translate = True
                    try:
                        _translate_snip_file(tmp_png, meta)
                    except Exception as e:
                        try:
                            with open(tmp_png + ".error.txt", "w", encoding="utf-8") as f:
                                f.write(str(e))
                        except OSError:
                            pass
            if time.time() - started_at > 300:
                proc.kill()
                break
            time.sleep(0.1)
        stdout, stderr = proc.communicate(timeout=5)
        debug_log(f"snip proc returncode={proc.returncode} path_exists={os.path.exists(tmp_png)}")
        if stdout:
            debug_log(f"snip stdout={stdout.strip()}")
        if stderr:
            debug_log(f"snip stderr={stderr.strip()}")
    except Exception as e:
        res["error"] = f"截图工具启动失败（{e}）"
        debug_log(f"snip proc error={e}")
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
                meta = json.load(f)
                res["region"] = meta.get("box")
                res["action"] = meta.get("action") or "translate"
                debug_log(f"snip meta action={res['action']} region={res['region']} path={tmp_png}")
                if res["action"] == "pin":
                    res["ok"] = True
                    return res
        except (OSError, ValueError):
            pass
        if SELECTION:  # 框选已完成，立刻在截图位置提示"正在翻译"
            try:
                SELECTION.show_busy(res["region"])
            except Exception:
                pass
        # 小图先放大 2 倍再识别（屏幕小字直接识别容易丢），识别完坐标缩回原尺度
        ocr_img, scale = res["img"], 1
        if max(ocr_img.width, ocr_img.height) < 700:
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
        if res.get("action") != "pin":
            for p in (tmp_png, tmp_png + ".json", tmp_png + ".translated.png", tmp_png + ".error.txt"):
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


def _translate_snip_file(path, meta):
    from PIL import Image as PILImage
    import numpy as np

    t0 = time.perf_counter()
    with PILImage.open(path) as im:
        img = im.convert("RGB")
    ocr_img, scale = img, 1
    if max(ocr_img.width, ocr_img.height) < 700:
        scale = 2
        ocr_img = ocr_img.resize((ocr_img.width * 2, ocr_img.height * 2), PILImage.LANCZOS)
    t_load = time.perf_counter()
    arr = np.ascontiguousarray(np.array(ocr_img)[:, :, ::-1])
    ocr_result, _ = get_ocr()(arr)
    t_ocr = time.perf_counter()
    lines = [
        ([[p[0] / scale, p[1] / scale] for p in line[0]], fix_spaces(line[1]))
        for line in (ocr_result or [])
    ]
    text = "\n".join(t for _, t in lines)
    if not text.strip():
        raise RuntimeError("没识别到文字，请框选更清晰的文字区域")
    target = smart_screenshot_target(text)
    sources = [t for _, t in lines]
    trans, fixed_count = translate_screenshot_ocr_lines(sources, target)
    t_translate = time.perf_counter()
    overlay = build_overlay_image(img, lines, trans)
    translated_path = path + ".translated.png"
    tmp_translated_path = translated_path + ".tmp"
    overlay.save(tmp_translated_path, format="PNG")
    os.replace(tmp_translated_path, translated_path)
    t_done = time.perf_counter()
    debug_log(
        "snip translate timing "
        f"load={t_load - t0:.2f}s "
        f"ocr={t_ocr - t_load:.2f}s "
        f"translate={t_translate - t_ocr:.2f}s "
        f"render={t_done - t_translate:.2f}s "
        f"total={t_done - t0:.2f}s "
        f"lines={len(lines)} target={target} fixed={fixed_count}"
    )


def _inplace_translate_overlay(res):
    """就地贴图翻译：译文按行贴回截图原位置，整块浮窗精准盖在原区域上"""
    target = smart_screenshot_target(res["text"])
    sources = [t for _, t in res["lines"]]
    trans, _fixed_count = translate_screenshot_ocr_lines(sources, target)
    if res["img"] is not None and res["region"]:
        overlay = build_overlay_image(res["img"], res["lines"], trans)
        SELECTION.show_overlay(overlay, res["region"], "\n".join(trans))
    else:
        SELECTION.show_result_popup("\n".join(trans))


def show_translated_image_window(res):
    """把译文直接贴回截图内，再用独立普通窗口显示。"""
    target = smart_screenshot_target(res["text"])
    sources = [t for _, t in res["lines"]]
    trans, _fixed_count = translate_screenshot_ocr_lines(sources, target)
    if res["img"] is None:
        return False
    overlay = build_overlay_image(res["img"], res["lines"], trans)
    out_path = os.path.join(DATA_DIR, f"translated_{uuid.uuid4().hex}.png")
    overlay.save(out_path)
    start_image_window(out_path)
    return True


def show_translated_overlay(res):
    """把译文贴回原截图区域，并覆盖在原屏幕位置，不弹普通窗口。"""
    target = smart_screenshot_target(res["text"])
    sources = [t for _, t in res["lines"]]
    trans, _fixed_count = translate_screenshot_ocr_lines(sources, target)
    if res["img"] is None or not res.get("region"):
        return False
    overlay = build_overlay_image(res["img"], res["lines"], trans)
    if SELECTION:
        SELECTION.show_overlay(overlay, res["region"], "\n".join(trans))
        return True
    return False


@app.route("/api/snip", methods=["POST"])
def snip():
    """界面按钮触发的截图翻译。同一时刻只允许一个截图流程。
    按设置 snip_to_window 决定：True 把原文交给页面在窗口里翻译；False 就地贴图翻译。"""
    if not SNIP_LOCK.acquire(blocking=False):
        return jsonify({"error": "已经有一个截图在进行中"}), 409
    try:
        to_window = load_settings().get("snip_to_window", True)
        res = _snip_and_ocr(restore=True)
        debug_log(f"/api/snip result action={res.get('action')} ok={res.get('ok')} cancelled={res.get('cancelled')} error={res.get('error')}")
        if res["cancelled"]:
            return jsonify({"cancelled": True})
        if res.get("action") == "pin":
            start_pin_window(res["path"])
            for p in (res["path"] + ".translated.png", res["path"] + ".error.txt"):
                try:
                    os.remove(p)
                except OSError:
                    pass
            return jsonify({"pinned": True})
        if not res["ok"]:
            _hide_busy()
            status = 400 if res["error"].startswith("没识别到") else 500
            return jsonify({"error": res["error"]}), status
        if not to_window:
            if show_translated_overlay(res):
                return jsonify({"inplace": True})
            return jsonify({"error": "显示截图翻译结果失败，请重试"}), 500
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
        debug_log(f"hotkey result action={res.get('action')} ok={res.get('ok')} cancelled={res.get('cancelled')} error={res.get('error')}")
        if res["cancelled"]:
            return  # 用户取消：什么都不打扰
        to_window = load_settings().get("snip_to_window", True)
        win = WEBVIEW_WINDOW

        if res.get("action") == "pin":
            start_pin_window(res["path"])
            for p in (res["path"] + ".translated.png", res["path"] + ".error.txt"):
                try:
                    os.remove(p)
                except OSError:
                    pass
            return

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
        elif show_translated_overlay(res):
            return
        elif win:
            _hide_busy()
            _bring_window_front(win)
            win.evaluate_js(f"window.snipFromHotkey({json.dumps(res['text'])})")
    except Exception as e:
        debug_log(f"hotkey exception={e}")
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


@app.route("/api/selection-status", methods=["GET"])
def selection_status_api():
    if SELECTION is None:
        return jsonify({"running": False, "status": None})
    try:
        return jsonify({"running": True, "status": SELECTION.status()})
    except Exception as e:
        return jsonify({"running": True, "error": str(e)})


@app.route("/api/selection-test-button", methods=["POST"])
def selection_test_button_api():
    if SELECTION is None:
        return jsonify({"error": "划词模块没有启动"}), 400
    try:
        SELECTION.test_button("划词测试")
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


DOC_LOCK = threading.Lock()  # 同一时刻只允许一批文档翻译，避免并发把翻译引擎挤爆


@app.route("/api/doc-pick", methods=["POST"])
def doc_pick():
    """桌面版弹窗：选多个文档，或选一个文件夹（自动列出里面支持的文档）。
    返回文件在本机的真实路径——翻译后才能放回原文件旁边（网页版拿不到真实路径，所以不支持）。"""
    win = WEBVIEW_WINDOW
    if win is None:
        return jsonify({"error": "网页版不支持文档翻译，请用桌面版软件"}), 400
    mode = (request.get_json(silent=True) or {}).get("mode", "files")
    try:
        import webview

        if mode == "folder":
            res = win.create_file_dialog(webview.FOLDER_DIALOG)
            if not res:
                return jsonify({"cancelled": True})
            folder = res[0] if isinstance(res, (list, tuple)) else res
            files = [
                os.path.join(folder, name)
                for name in sorted(os.listdir(folder))
                if os.path.isfile(os.path.join(folder, name))
                and doc_translate.is_supported(os.path.join(folder, name))
            ]
            return jsonify({"files": files})
        res = win.create_file_dialog(
            webview.OPEN_DIALOG,
            allow_multiple=True,
            file_types=("文档 (*.txt;*.docx;*.xlsx;*.pdf)", "所有文件 (*.*)"),
        )
        if not res:
            return jsonify({"cancelled": True})
        files = [f for f in res if doc_translate.is_supported(f)]
        return jsonify({"files": files})
    except Exception as e:
        return jsonify({"error": f"选择文件失败（{e}）"}), 500


@app.route("/api/doc-export-dir", methods=["POST"])
def doc_export_dir():
    """桌面版选择翻译完成后的导出文件夹。"""
    win = WEBVIEW_WINDOW
    if win is None:
        return jsonify({"error": "网页版不支持选择导出文件夹，请用桌面版软件"}), 400
    try:
        import webview

        res = win.create_file_dialog(webview.FOLDER_DIALOG)
        if not res:
            return jsonify({"cancelled": True})
        folder = res[0] if isinstance(res, (list, tuple)) else res
        os.makedirs(folder, exist_ok=True)
        return jsonify({"dir": folder})
    except Exception as e:
        return jsonify({"error": f"选择导出文件夹失败（{e}）"}), 500


@app.route("/api/doc-upload", methods=["POST"])
def doc_upload():
    """拖拽文件 fallback：浏览器拿不到真实路径时，把文件上传到程序目录临时区再翻译。"""
    files = request.files.getlist("files")
    saved = []
    for f in files:
        name = os.path.basename(f.filename or "")
        if not name:
            continue
        ext = os.path.splitext(name)[1].lower()
        if ext not in doc_translate.SUPPORTED_EXTS:
            continue
        base, ext = os.path.splitext(name)
        dest = os.path.join(DOC_UPLOAD_DIR, f"{base}_{uuid.uuid4().hex[:8]}{ext}")
        f.save(dest)
        saved.append(dest)
    if not saved:
        return jsonify({"error": "没有可翻译的文档，只支持 txt/docx/xlsx/pdf"}), 400
    return jsonify({"files": saved})


@app.route("/api/doc-translate", methods=["POST"])
def doc_translate_api():
    """翻译一批文档，每个在原文件旁生成带语言后缀的新文件。逐个返回成功/失败。"""
    data = request.get_json(force=True)
    paths = data.get("paths") or []
    target = data.get("target") or "en"
    export_dir = (data.get("export_dir") or "").strip() or None
    if target not in VALID_TARGETS:
        return jsonify({"error": "目标语言不在支持列表里"}), 400
    if not isinstance(paths, list) or not paths:
        return jsonify({"error": "没有要翻译的文件"}), 400
    if export_dir:
        try:
            os.makedirs(export_dir, exist_ok=True)
            probe = os.path.join(export_dir, ".__tt_export_test__")
            with open(probe, "w", encoding="utf-8"):
                pass
            os.remove(probe)
        except OSError as e:
            return jsonify({"error": f"导出文件夹不可写，请换一个（{e}）"}), 400
    if not DOC_LOCK.acquire(blocking=False):
        return jsonify({"error": "已经有一批文档在翻译中，请等它完成"}), 409
    try:
        results = []
        for p in paths:
            ok, res, partial = doc_translate.translate_file(
                p, target, target, translate_lines, export_dir=export_dir
            )
            results.append(
                {"path": p, "name": os.path.basename(p), "ok": ok,
                 "output": res if ok else "", "error": "" if ok else res,
                 "partial": partial}  # >0 表示这文件有 partial 段没翻成（网络不稳），文件已生成但带原文
            )
        return jsonify({"results": results})
    finally:
        DOC_LOCK.release()


@app.route("/api/open-path", methods=["POST"])
def open_path():
    data = request.get_json(force=True)
    path = data.get("path") or ""
    if not path:
        return jsonify({"error": "没有路径"}), 400
    try:
        if os.path.isfile(path):
            path = os.path.dirname(path)
        os.makedirs(path, exist_ok=True)
        os.startfile(path)
        return jsonify({"ok": True})
    except OSError as e:
        return jsonify({"error": f"打开失败（{e}）"}), 500


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
