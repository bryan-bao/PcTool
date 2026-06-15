# -*- coding: utf-8 -*-
"""生成软件图标 app.ico：紫色渐变圆角方块 + 白色"译"字"""
from PIL import Image, ImageDraw, ImageFont

SIZE = 256
RADIUS = 52
TOP = (0x43, 0x38, 0xCA)     # 紫蓝
BOTTOM = (0x93, 0x33, 0xEA)  # 紫

grad = Image.new("RGB", (SIZE, SIZE))
d = ImageDraw.Draw(grad)
for y in range(SIZE):
    t = y / (SIZE - 1)
    color = tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
    d.line([(0, y), (SIZE, y)], fill=color)

mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], RADIUS, fill=255)

icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
icon.paste(grad, (0, 0), mask)

draw = ImageDraw.Draw(icon)
font = ImageFont.truetype(r"C:\Windows\Fonts\msyhbd.ttc", 150)
text = "译"
box = draw.textbbox((0, 0), text, font=font)
w, h = box[2] - box[0], box[3] - box[1]
draw.text(((SIZE - w) / 2 - box[0], (SIZE - h) / 2 - box[1]), text, font=font, fill="white")

icon.save(
    "app.ico",
    sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)],
)
print("app.ico 已生成")
