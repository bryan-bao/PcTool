# -*- mode: python ; coding: utf-8 -*-
import os
import wordninja
from PyInstaller.utils.hooks import collect_data_files

# wordninja 是单文件模块(wordninja.py)，词库在它同目录的 wordninja/ 子目录里，
# collect_data_files 收不到（会 warning），必须显式打到 wordninja\ 子目录，否则打包后 import wordninja 直接 FileNotFoundError、拆词失效
_wordninja_words = os.path.join(os.path.dirname(os.path.abspath(wordninja.__file__)), 'wordninja', 'wordninja_words.txt.gz')

# rapidocr 没有官方 hook，模型(.onnx)/config.yaml/字典必须手动收集，否则打包后 OCR 报 FileNotFoundError
a = Analysis(
    ['desktop.py'],
    pathex=[],
    binaries=[],
    # python-docx 创建/保存 Word 要用 templates/default.docx 等模板，collect_data_files('docx') 收齐它们，
    # 否则打包后文档翻译生成 .docx（含 PDF→docx）会 FileNotFoundError。openpyxl/pypdf 纯 py 无需额外 datas。
    datas=[('static', 'static'), ('app.ico', '.'), (_wordninja_words, 'wordninja')]
          + collect_data_files('rapidocr_onnxruntime') + collect_data_files('docx'),
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='TranslationTool',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['app.ico'],
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='TranslationTool',
)
