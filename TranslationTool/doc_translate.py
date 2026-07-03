# -*- coding: utf-8 -*-
"""文档翻译：读 txt/docx/xlsx/pdf 里的文字 → 翻译 → 在原文件旁边另存带语言后缀的新文件。
PDF 没法保持排版，抠出文字翻译后另存成 .docx。
翻译本身复用 app.translate_lines（传进来的 tl_fn），它返回 (译文列表, 没翻成的行数)。

关键设计（避免"假翻译"）：断网/限流时翻译会静默退回原文，这里靠 tl_fn 回报的"没翻成行数"
判断——整篇都没翻成就报错、删掉半成品，绝不生成一份看着成功实则没翻的文件；部分没翻成则
保留文件但回报 partial，让前端给黄色警告。"""
import os
import zipfile

SUPPORTED_EXTS = {".txt", ".docx", ".xlsx", ".pdf"}


def is_supported(path):
    return os.path.splitext(path)[1].lower() in SUPPORTED_EXTS


def output_path(path, suffix, export_dir=None):
    """原文件旁边的输出路径：报告.docx → 报告_en.docx；PDF 改存 .docx。
    若同名已存在，自动加 (2)(3)… 避免覆盖；试到很多还撞就用时间兜底，不死循环。"""
    d = export_dir or os.path.dirname(path)
    base, ext = os.path.splitext(os.path.basename(path))
    ext = ext.lower()
    if ext == ".pdf":
        ext = ".docx"
    cand = os.path.join(d, f"{base}_{suffix}{ext}")
    n = 2
    while os.path.exists(cand) and n < 100:
        cand = os.path.join(d, f"{base}_{suffix}({n}){ext}")
        n += 1
    return cand


def _read_text_file(path):
    """读 txt：优先 UTF-8，失败退 GBK（中文 Windows 记事本默认 ANSI=GBK）"""
    for enc in ("utf-8-sig", "gbk"):
        try:
            with open(path, encoding=enc) as f:
                return f.read(), enc
        except (UnicodeDecodeError, LookupError):
            continue
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read(), "utf-8"


def _should_translate_text(text):
    """文档里的纯路径/编号/明显代码不强行翻，普通说明尽量翻译。"""
    import re

    raw = (text or "").strip()
    if not raw:
        return False
    letters = sum(1 for ch in raw if ("A" <= ch <= "Z") or ("a" <= ch <= "z"))
    cjk = sum(1 for ch in raw if "\u4e00" <= ch <= "\u9fff")
    if letters == 0 and cjk == 0:
        return False
    if re.fullmatch(r"[\W\d_]+", raw):
        return False
    # 路径、URL、纯域名默认保留。
    if re.search(r"https?://|[A-Za-z]:\\|[/\\][\w.-]+[/\\]|^\s*[\w.-]+\.(com|cn|net|org)\b", raw, re.I):
        return False

    # 只有明显是代码/命令的短行才保留；长段即使夹杂代码符号，也按正文翻译。
    code_hits = len(re.findall(
        r"[{};=<>]|\b(public|private|protected|class|static|return|import|using|function|const|let|var|def)\b",
        raw,
    ))
    words = re.findall(r"[A-Za-z][A-Za-z'-]*", raw)
    if code_hits >= 2 and len(words) <= 10:
        return False
    if re.fullmatch(r"[A-Za-z_][\w.]*\([^)]*\);?", raw):
        return False

    words = re.findall(r"[A-Za-z][A-Za-z'-]*", raw)
    if words and len(words) <= 2 and re.fullmatch(r"[A-Za-z0-9_.:/\\#-]+", raw):
        return False
    return True


def _translate_keep_blanks(lines, target, tl_fn, stats):
    """只翻译非空行，空行/纯符号行原样保留；把翻译量和没翻成数累加进 stats"""
    idx = [i for i, ln in enumerate(lines) if _should_translate_text(ln)]
    if not idx:
        return lines
    originals = [lines[i] for i in idx]
    trans, failed = tl_fn(originals, target)
    stats["total"] += len(idx)
    stats["failed"] += failed
    stats["changed"] += sum(1 for a, b in zip(originals, trans) if (a or "").strip() != (b or "").strip())
    out = list(lines)
    for i, t in zip(idx, trans):
        out[i] = t
    return out


def _set_para_text(p, text):
    """把整段译文写回段落：保住段落级样式（字体/对齐），放弃段内逐字格式。
    含超链接的段落特殊处理——python-docx 的 p.text 能读到超链接里的文字、但 p.runs 读不到，
    若按 run 回写会残留超链接原文造成"译文+原文"重复损坏，故直接整段替换（会丢超链接、保译文）。"""
    from docx.oxml.ns import qn

    if p._p.findall(qn("w:hyperlink")):
        p.text = text  # python-docx 1.x 的 text setter 会清掉全部内容、塞成单个 run
        return
    if p.runs:
        p.runs[0].text = text
        for r in p.runs[1:]:
            r.text = ""
    else:
        p.add_run(text)


def _iter_docx_paragraphs(doc):
    """正文段落 + 所有表格单元格里的段落，都要翻译"""
    for p in doc.paragraphs:
        yield p
    for table in doc.tables:
        for row in table.rows:
            for cell in row.cells:
                for p in cell.paragraphs:
                    yield p


def _do_txt(path, target, tl_fn, stats, out):
    text, _enc = _read_text_file(path)
    lines = text.split("\n")
    lines = _translate_keep_blanks(lines, target, tl_fn, stats)
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def _do_docx(path, target, tl_fn, stats, out):
    from docx import Document

    doc = Document(path)
    paras = [p for p in _iter_docx_paragraphs(doc) if _should_translate_text(p.text)]
    if paras:
        originals = [p.text for p in paras]
        trans, failed = tl_fn(originals, target)
        stats["total"] += len(paras)
        stats["failed"] += failed
        stats["changed"] += sum(1 for a, b in zip(originals, trans) if (a or "").strip() != (b or "").strip())
        for p, t in zip(paras, trans):
            _set_para_text(p, t)
    doc.save(out)


def _do_xlsx(path, target, tl_fn, stats, out):
    from openpyxl import load_workbook

    wb = load_workbook(path)
    try:
        cells = []
        for ws in wb.worksheets:
            for row in ws.iter_rows():
                for c in row:
                    v = c.value
                    # 只翻文字单元格；公式（=开头）跳过，免得把公式翻坏
                    if isinstance(v, str) and _should_translate_text(v) and not v.startswith("="):
                        cells.append(c)
        if cells:
            originals = [c.value for c in cells]
            trans, failed = tl_fn(originals, target)
            stats["total"] += len(cells)
            stats["failed"] += failed
            stats["changed"] += sum(1 for a, b in zip(originals, trans) if (a or "").strip() != (b or "").strip())
            for c, t in zip(cells, trans):
                c.value = t
        wb.save(out)
    finally:
        wb.close()


def _do_pdf(path, target, tl_fn, stats, out):
    """PDF 抠文字 → 翻译 → 另存 .docx（每行一段，保不住原排版）"""
    from pypdf import PdfReader
    from docx import Document

    reader = PdfReader(path)
    if reader.is_encrypted:
        try:
            reader.decrypt("")  # 试空密码（有些 PDF 只是设了空的所有者密码）
        except Exception:
            raise ValueError("这个 PDF 有密码保护，请先去掉密码再翻译")
    lines = []
    for page in reader.pages:
        txt = page.extract_text() or ""
        lines.extend(txt.split("\n"))
    if not any(ln.strip() for ln in lines):
        raise ValueError("这个 PDF 里没提取到文字（可能是扫描成图片的 PDF）。如果是图片上的字，可以用主页的「截图翻译」")
    lines = _translate_keep_blanks(lines, target, tl_fn, stats)
    doc = Document()
    for ln in lines:
        doc.add_paragraph(ln)
    doc.save(out)


_HANDLERS = {".txt": _do_txt, ".docx": _do_docx, ".xlsx": _do_xlsx, ".pdf": _do_pdf}


def _friendly_error(e):
    """把底层英文/系统异常翻成非技术用户看得懂的中文提示"""
    if isinstance(e, ValueError):
        return str(e)  # 我们自己抛的中文提示（扫描版 PDF、加密 PDF 等），直接用
    low = str(e).lower()
    if (isinstance(e, PermissionError) or "winerror 32" in low or "being used" in low
            or "errno 13" in low or "permission denied" in low):
        return "这个文件可能正开在 Word/Excel/记事本里，或所在文件夹没有写入权限。请先关掉文件、或把文件放到桌面等普通文件夹再试"
    if isinstance(e, FileNotFoundError) or "errno 2" in low or "no such file" in low:
        return "找不到保存位置，U盘或网盘可能断开了，请重新插好/连上再试"
    if "password" in low or "encrypted" in low or "decrypt" in low:
        return "这个文件有密码保护，请先去掉密码再翻译"
    if (isinstance(e, zipfile.BadZipFile) or "package not found" in low
            or "not a zip" in low or "badzipfile" in low or "invalidfile" in low):
        return "这个文件打不开：可能正被其他程序占用、已损坏，或不是真正的 Word/Excel 文件，请关掉后重试"
    return f"处理失败：这个文件可能损坏或格式不对（{e}）"


def translate_file(path, target, suffix, tl_fn, export_dir=None):
    """翻译单个文档。返回 (ok, 结果, partial)：
    - 成功：(True, 输出文件路径, 没翻成的段数)。partial>0 表示网络不稳、有部分段落退回原文。
    - 失败：(False, 中文错误说明, 0)。整篇没翻成/读写失败都算失败，且删掉半成品不留假文件。"""
    if not os.path.isfile(path):
        return False, "文件不存在", 0
    ext = os.path.splitext(path)[1].lower()
    handler = _HANDLERS.get(ext)
    if not handler:
        return False, f"不支持的格式（{ext}）", 0
    out = output_path(path, suffix, export_dir=export_dir)

    # 翻译前先探测输出目录能不能写，省得翻几分钟才在保存时失败
    out_dir = os.path.dirname(out) or "."
    try:
        os.makedirs(out_dir, exist_ok=True)
        probe = os.path.join(out_dir, ".__tt_wtest__")
        with open(probe, "w"):
            pass
        os.remove(probe)
    except OSError:
        return False, "这个文件夹没法写入（可能是只读、U盘/网盘断开，或没权限），请把文件放到桌面等普通文件夹再试", 0

    stats = {"total": 0, "failed": 0, "changed": 0}
    try:
        handler(path, target, tl_fn, stats, out)
    except Exception as e:
        if os.path.exists(out):
            try:
                os.remove(out)
            except OSError:
                pass
        return False, _friendly_error(e), 0

    # 熔断：整篇都没翻成（断网/限流被静默退回原文）→ 不留假文件，明确报错
    if stats["total"] == 0:
        if os.path.exists(out):
            try:
                os.remove(out)
            except OSError:
                pass
        return False, "没有检测到需要翻译的正文内容；代码、路径、编号等已按策略保留", 0

    if stats["total"] > 0 and stats["failed"] >= stats["total"]:
        if os.path.exists(out):
            try:
                os.remove(out)
            except OSError:
                pass
        return False, "翻译服务连不上或被限流，这份文件没能翻出来，请检查网络后重试", 0

    if stats["total"] > 0 and stats["changed"] == 0:
        if os.path.exists(out):
            try:
                os.remove(out)
            except OSError:
                pass
        return False, "没有检测到有效译文，已停止生成，避免导出一份和原文一样的文件", 0

    return True, out, stats["failed"]
