# -*- coding: utf-8 -*-
"""必应网页翻译：免费、国内可直连、无需任何密钥。
原理：模拟必应翻译网页的请求——先打开翻译页拿到会话参数（IG/IID/token），
再调它的 ttranslatev3 接口。token 约几分钟过期，过期自动刷新。"""
import re
import threading
import time

import requests

# 我们的语言代码 → 必应的语言代码
BING_LANGS = {
    "zh-CN": "zh-Hans", "zh-TW": "zh-Hant", "en": "en", "ja": "ja",
    "ko": "ko", "fr": "fr", "de": "de", "es": "es", "ru": "ru",
    "pt": "pt", "it": "it", "vi": "vi", "th": "th", "ar": "ar",
}

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

_lock = threading.Lock()
_session = None
_meta = {"ig": "", "iid": "", "key": "", "token": "", "expiry": 0.0, "host": "www.bing.com"}


def _refresh():
    global _session
    _session = requests.Session()
    _session.headers["User-Agent"] = UA
    r = _session.get("https://www.bing.com/translator", timeout=8)
    r.raise_for_status()
    host_m = re.match(r"https?://([^/]+)/", r.url)
    ig = re.search(r'IG:"([^"]+)"', r.text)
    iid = re.search(r'data-iid="([^"]+)"', r.text)
    helper = re.search(r"params_AbusePreventionHelper\s*=\s*\[([^\]]+)\]", r.text)
    if not (ig and iid and helper):
        raise RuntimeError("必应翻译页面解析失败")
    parts = helper.group(1).split(",")
    _meta.update(
        host=host_m.group(1) if host_m else "www.bing.com",
        ig=ig.group(1),
        iid=iid.group(1),
        key=parts[0].strip(),
        token=parts[1].strip().strip('"'),
        expiry=time.time() + 8 * 60,
    )


def _chunks(text, limit=900):
    """按行切成不超过 limit 字的块（必应单次约 1000 字上限）"""
    if len(text) <= limit:
        return [text]
    parts, cur = [], ""
    for line in text.split("\n"):
        while len(line) > limit:  # 单行超长，硬切
            if cur:
                parts.append(cur)
                cur = ""
            parts.append(line[:limit])
            line = line[limit:]
        if cur and len(cur) + len(line) + 1 > limit:
            parts.append(cur)
            cur = line
        else:
            cur = f"{cur}\n{line}" if cur else line
    if cur:
        parts.append(cur)
    return parts


def _post(chunk, src, dst):
    url = f"https://{_meta['host']}/ttranslatev3?isVertical=1&IG={_meta['ig']}&IID={_meta['iid']}"
    data = {"fromLang": src, "to": dst, "text": chunk,
            "token": _meta["token"], "key": _meta["key"]}
    r = _session.post(url, data=data, timeout=10)
    j = r.json()
    if isinstance(j, dict):  # 一般是 token 过期 / 被限流
        raise RuntimeError(f"必应接口返回异常（{j.get('statusCode')}）")
    return j[0]["translations"][0]["text"]


def translate(text, source="auto", target="zh-CN"):
    """返回译文；失败抛异常。线程安全。"""
    with _lock:
        if _session is None or time.time() > _meta["expiry"]:
            _refresh()
        src = "auto-detect" if source == "auto" else BING_LANGS.get(source, source)
        dst = BING_LANGS.get(target, target)
        out = []
        for chunk in _chunks(text):
            try:
                out.append(_post(chunk, src, dst))
            except Exception:
                _refresh()  # 刷新会话重试一次
                out.append(_post(chunk, src, dst))
        return "\n".join(out)
