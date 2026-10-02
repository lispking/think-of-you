#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
渲染「小聆 AI · 时钟天气番茄钟」竖屏介绍片。

规格: 1080x1920 (9:16), 30fps, 30s, 共 900 帧
产物: video/frames/f00000.png ... f00899.png
用法: python3 video/render.py            # 全量渲染
      python3 video/render.py --preview  # 只渲关键帧到 video/preview/
"""
import os
import sys
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1080, 1920
FPS = 30
DUR = 30.0
NFRAMES = int(DUR * FPS)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "frames")
PREVIEW = os.path.join(HERE, "preview")

FONT_DIR = os.path.expanduser("~/Library/Fonts")
# 注: 本机 LXGWWenKai-Bold.ttf 只有 9 字节(占位文件), 粗体用 Medium + 描边模拟
KAI = {
    "r": os.path.join(FONT_DIR, "LXGWWenKai-Regular.ttf"),
    "m": os.path.join(FONT_DIR, "LXGWWenKai-Medium.ttf"),
    "b": os.path.join(FONT_DIR, "LXGWWenKai-Medium.ttf"),
}
MONO = "/System/Library/Fonts/SFNSMono.ttf"

_font_cache = {}


def kai(size, weight="m"):
    key = ("k", int(size), weight)
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(KAI[weight], max(8, int(size)))
    return _font_cache[key]


def mono(size):
    key = ("m", int(size))
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(MONO, max(8, int(size)))
    return _font_cache[key]


# ---------------------------------------------------------------- 颜色
BG_TOP = (10, 21, 36)
BG_BOT = (5, 11, 22)

ACCENTS = {
    "clock": (94, 226, 255),      # 青
    "weather": (255, 193, 92),    # 暖黄
    "pomo": (255, 118, 138),      # 珊瑚红
    "brand": (126, 200, 255),
}
WHITE = (240, 247, 255)
DIM = (150, 172, 200)
DARK = (8, 16, 28)


def rgba(c, a):
    return (int(c[0]), int(c[1]), int(c[2]), int(max(0, min(255, a))))


def mix(c1, c2, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))


def lighten(c, t):
    return mix(c, (255, 255, 255), t)


def darken(c, t):
    return mix(c, (0, 0, 0), t)


# ---------------------------------------------------------------- 缓动
def clamp(v, a=0.0, b=1.0):
    return max(a, min(b, v))


def ease_out(t):
    t = clamp(t)
    return 1 - (1 - t) ** 3


def ease_in_out(t):
    t = clamp(t)
    return 3 * t * t - 2 * t * t * t


def ease_out_back(t, s=1.4):
    t = clamp(t)
    return 1 + (s + 1) * (t - 1) ** 3 + s * (t - 1) ** 2


def seq(t, start, dur=0.5, ease=ease_out):
    """返回 start 起、dur 长的进度(已缓动)"""
    return ease(clamp((t - start) / max(1e-6, dur)))


# ---------------------------------------------------------------- 文字
def text_size(text, font, ls=0):
    d = ImageDraw.Draw(Image.new("RGB", (8, 8)))
    if not text:
        return (0, 0)
    box = d.textbbox((0, 0), text, font=font)
    w = box[2] - box[0] + ls * max(0, len(text) - 1)
    h = box[3] - box[1]
    return (w, h)


def draw_text_track(d, xy, text, font, fill, ls=0, anchor="la", stroke=0, stroke_fill=None):
    """支持字间距的文字绘制; anchor: la(左) / ma(中) / ra(右)"""
    if not text:
        return 0
    tw, _ = text_size(text, font, ls)
    x, y = xy
    if anchor[0] == "m":
        x -= tw / 2
    elif anchor[0] == "r":
        x -= tw
    kw = {}
    if stroke:
        kw["stroke_width"] = stroke
        kw["stroke_fill"] = stroke_fill or fill
    if ls:
        cx = x
        for ch in text:
            d.text((cx, y), ch, font=font, fill=fill, **kw)
            cx += text_size(ch, font)[0] + ls
    else:
        d.text((x, y), text, font=font, fill=fill, **kw)
    return tw


def rrect(d, box, radius, fill=None, outline=None, width=1):
    d.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


# ---------------------------------------------------------------- 渐变/光效
def vgrad(size, c_top, c_bot, radius=0):
    """竖直渐变图(带圆角遮罩)"""
    w, h = size
    grad = Image.new("RGB", (1, h))
    px = grad.load()
    for y in range(h):
        px[0, y] = mix(c_top, c_bot, y / max(1, h - 1))
    grad = grad.resize((w, h), Image.BILINEAR)
    if radius > 0:
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=255)
        out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        out.paste(grad, (0, 0), mask)
        return out
    return grad.convert("RGBA")


_glow_cache = {}
GLOW_PAD = 60
GLOW_W, GLOW_H = 1200, 1000


def glow_sprite(color, radius=40, strength=110):
    """缓存一张外发光精灵, 按需缩放"""
    key = (color, radius, strength)
    if key not in _glow_cache:
        w, h = GLOW_W, GLOW_H
        base = Image.new("RGBA", (w + GLOW_PAD * 2, h + GLOW_PAD * 2), (0, 0, 0, 0))
        m = Image.new("L", base.size, 0)
        ImageDraw.Draw(m).rounded_rectangle(
            (GLOW_PAD, GLOW_PAD, GLOW_PAD + w, GLOW_PAD + h), radius=radius, fill=strength
        )
        m = m.filter(ImageFilter.GaussianBlur(26))
        base.putalpha(m)
        base = Image.new("RGBA", base.size, rgba(color, 255))
        base.putalpha(m)
        _glow_cache[key] = base
    return _glow_cache[key]


def add_glow(img, rect, color, radius=40, strength=110):
    sp = glow_sprite(color, radius, strength)
    pad = GLOW_PAD
    x0, y0, x1, y1 = rect
    tw, th = int(x1 - x0), int(y1 - y0)
    sw = int(tw + pad * 2)
    sh = int(th + pad * 2)
    sp2 = sp.resize((max(4, sw), max(4, sh)), Image.BILINEAR)
    tmp = Image.new("RGBA", img.size, (0, 0, 0, 0))
    tmp.alpha_composite(sp2, (int(x0 - pad), int(y0 - pad)))
    return Image.alpha_composite(img, tmp)


GLOW_C = 700
_glow_circle_cache = {}


def add_glow_circle(img, cx, cy, r, color, strength=190, blur=46):
    """圆形光点(番茄进度头等); 用正方形精灵保证缩放后仍是正圆"""
    key = (color, strength, blur)
    if key not in _glow_circle_cache:
        side = GLOW_C + GLOW_PAD * 2
        base = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        m = Image.new("L", (side, side), 0)
        ImageDraw.Draw(m).ellipse((GLOW_PAD, GLOW_PAD, GLOW_PAD + GLOW_C, GLOW_PAD + GLOW_C),
                                  fill=int(strength))
        m = m.filter(ImageFilter.GaussianBlur(blur))
        base = Image.new("RGBA", (side, side), rgba(color, 255))
        base.putalpha(m)
        _glow_circle_cache[key] = base
    sp = _glow_circle_cache[key]
    side = int(2 * r + GLOW_PAD * 2)
    sp2 = sp.resize((max(4, side), max(4, side)), Image.BILINEAR)
    tmp = Image.new("RGBA", img.size, (0, 0, 0, 0))
    tmp.alpha_composite(sp2, (int(cx - r - GLOW_PAD), int(cy - r - GLOW_PAD)))
    return Image.alpha_composite(img, tmp)


# ---------------------------------------------------------------- 背景
def make_base():
    """底色渐变 + 点阵 + 光晕, 只算一次"""
    base = vgrad((W, H), BG_TOP, BG_BOT).convert("RGBA")

    # 左上 / 右下 冷暖光晕
    halo = Image.new("L", (W, H), 0)
    dh = ImageDraw.Draw(halo)
    dh.ellipse((-360, -520, 760, 520), fill=90)
    dh.ellipse((520, 1180, 1560, 2260), fill=70)
    dh.ellipse((-200, 1300, 620, 2100), fill=40)
    halo = halo.filter(ImageFilter.GaussianBlur(150))
    tint = Image.new("RGBA", (W, H), (44, 96, 150, 255))
    tint.putalpha(halo)
    base = Image.alpha_composite(base, tint)

    # 点阵纹理
    dots = Image.new("L", (W, H), 0)
    dd = ImageDraw.Draw(dots)
    step = 46
    for y in range(24, H, step):
        for x in range(24, W, step):
            dd.ellipse((x, y, x + 2, y + 2), fill=34)
    base = Image.alpha_composite(base, Image.merge("RGBA", (
        Image.new("L", (W, H), 255), Image.new("L", (W, H), 255),
        Image.new("L", (W, H), 255), dots)))

    # 暗角
    vg = Image.new("L", (W, H), 0)
    dvg = ImageDraw.Draw(vg)
    dvg.ellipse((-420, -220, W + 420, H + 220), fill=255)
    vg = Image.eval(vg.filter(ImageFilter.GaussianBlur(220)), lambda v: 255 - v)
    dark = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    dark.putalpha(Image.eval(vg, lambda v: int(v * 0.55)))
    return Image.alpha_composite(base, dark)


BASE = None
NOISE = []


def init_assets():
    global BASE, NOISE
    BASE = make_base()
    rng = np.random.default_rng(7)
    for _ in range(4):
        arr = rng.integers(96, 160, (H, W), dtype=np.uint8)
        n = Image.fromarray(arr, mode="L").convert("RGB")
        NOISE.append(n)


def background(t):
    """随时间缓慢漂移的光斑 + 颗粒"""
    img = BASE.copy()

    blob = Image.new("L", (W, H), 0)
    db = ImageDraw.Draw(blob)
    for i, (cx, cy, r, col, spd, amp) in enumerate([
        (300, 500, 420, ACCENTS["clock"], 0.30, 70),
        (820, 1100, 380, ACCENTS["pomo"], 0.22, 60),
        (540, 1650, 300, ACCENTS["weather"], 0.26, 55),
    ]):
        x = cx + math.sin(t * spd + i * 2.0) * amp
        y = cy + math.cos(t * spd * 0.7 + i * 1.3) * amp * 0.7
        db.ellipse((x - r, y - r, x + r, y + r), fill=26)
    blob = blob.filter(ImageFilter.GaussianBlur(120))

    tint = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    acc = mix(ACCENTS["clock"], ACCENTS["pomo"], 0.5 * (1 + math.sin(t * 0.12)))
    tint = Image.new("RGBA", (W, H), rgba(acc, 255))
    tint.putalpha(blob)
    img = Image.alpha_composite(img, tint)

    n = NOISE[int(t * FPS) % len(NOISE)]
    img = Image.blend(img, Image.merge("RGBA", (*n.split(), Image.new("L", (W, H), 255))), 0.022)
    return img


# ---------------------------------------------------------------- 排版工具
def put_text(img, xy, text, font, color, alpha=255, ls=0, anchor="la", rise=0, stroke=0):
    """带独立透明度的文字绘制(便于逐条错峰淡入)"""
    if alpha <= 2 or not text:
        return 0
    tw, th = text_size(text, font, ls)
    pad = 16
    layer = Image.new("RGBA", (int(tw) + pad * 2, int(th) + pad * 2 + 12), (0, 0, 0, 0))
    draw_text_track(ImageDraw.Draw(layer), (pad, pad), text, font, rgba(color, alpha),
                    ls=ls, stroke=stroke, stroke_fill=rgba(color, alpha))
    x, y = xy
    if anchor[0] == "m":
        x -= tw / 2
    elif anchor[0] == "r":
        x -= tw
    if anchor[1] == "m":
        y -= th / 2
    elif anchor[1] == "b":
        y -= th
    img.alpha_composite(layer, (int(x - pad), int(y - pad + rise)))
    return tw


def lerp_rect(a, b, t):
    t = clamp(t)
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(4))


def rect_size(r):
    return (int(r[2] - r[0]), int(r[3] - r[1]))


def panel(size, radius=52, top=(27, 42, 65), bot=(16, 27, 45), edge=(96, 146, 205)):
    p = vgrad(size, top, bot, radius=radius).convert("RGBA")
    d = ImageDraw.Draw(p)
    d.rounded_rectangle((1, 1, size[0] - 2, size[1] - 2), radius=radius,
                        outline=rgba(edge, 78), width=2)
    # 顶部高光
    sh = Image.new("L", size, 0)
    ImageDraw.Draw(sh).rounded_rectangle((0, 0, size[0] - 1, int(size[1] * 0.42)),
                                         radius=radius, fill=26)
    sh = sh.filter(ImageFilter.GaussianBlur(24))
    hi = Image.new("RGBA", size, (255, 255, 255, 255))
    hi.putalpha(sh)
    return Image.alpha_composite(p, hi)


def card_shadow(img, rect, radius=52, alpha=110, blur=30, offset=18):
    x0, y0, x1, y1 = [int(v) for v in rect]
    layer = Image.new("L", (W, H), 0)
    ImageDraw.Draw(layer).rounded_rectangle(
        (x0, y0 + offset, x1, y1 + offset), radius=radius, fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    sh.putalpha(layer)
    return Image.alpha_composite(img, sh)


def compose_card(img, layer, rect, alpha=1.0, scale=1.0, glow=None, glow_radius=52,
                 glow_strength=95, shadow=True, radius=52):
    """把卡片层合成到画布(支持整体缩放/透明/外发光)"""
    if alpha <= 0.01:
        return img
    if shadow:
        img = card_shadow(img, rect, radius=radius)
    if glow:
        img = add_glow(img, rect, glow, radius=glow_radius, strength=int(glow_strength * alpha))
    lw, lh = rect_size(rect)
    if scale != 1.0:
        lw, lh = max(4, int(lw * scale)), max(4, int(lh * scale))
        layer = layer.resize((lw, lh), Image.LANCZOS)
    else:
        layer = layer.resize((lw, lh), Image.LANCZOS)
    if alpha < 0.999:
        a = layer.split()[3].point(lambda v: int(v * alpha))
        layer = layer.copy()
        layer.putalpha(a)
    cx = (rect[0] + rect[2]) / 2
    cy = (rect[1] + rect[3]) / 2
    img.alpha_composite(layer, (int(cx - lw / 2), int(cy - lh / 2)))
    return img


def add_vignette(img, strength=0.5):
    vg = Image.new("L", (W, H), 0)
    ImageDraw.Draw(vg).ellipse((-500, -300, W + 500, H + 300), fill=255)
    vg = Image.eval(vg.filter(ImageFilter.GaussianBlur(200)), lambda v: 255 - v)
    dark = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    dark.putalpha(Image.eval(vg, lambda v: int(v * strength)))
    return Image.alpha_composite(img, dark)


# ---------------------------------------------------------------- 卡片内容
def clock_layer(size, seconds, mode="card", week="星期五", date_txt="2026 年 10 月 2 日"):
    lw, lh = size
    p = panel((lw, lh))
    d = ImageDraw.Draw(p)
    d.rounded_rectangle((0, 74, 9, lh - 74), radius=5, fill=rgba(ACCENTS["clock"], 210))
    hms = seconds_to_hhmmss(seconds)

    if mode == "hero":
        put_text(p, (52, 46), "本地时间", kai(30, "m"), ACCENTS["clock"], alpha=225, ls=6)
        put_text(p, (52, 98), "杭州 · 中国", kai(26), DIM, alpha=155, ls=3)
        big = mono(158)
        put_text(p, (48, 172), hms[:5], big, WHITE)
        tw = text_size(hms[:5], big)[0]
        put_text(p, (54 + tw + 10, 264), hms[6:], mono(62), ACCENTS["clock"], alpha=235)
        d.line((48, lh - 226, lw - 48, lh - 226), fill=rgba((110, 150, 200), 55), width=2)
        put_text(p, (48, lh - 200), date_txt + "  " + week, kai(36, "m"), WHITE, alpha=215)
        cells = [("显示", "常亮"), ("校时", "自动"), ("状态", "在线")]
        cw = (lw - 96) / 3
        for i, (lb, vl) in enumerate(cells):
            x = 48 + cw * i
            put_text(p, (x, lh - 138), lb, kai(26), DIM, alpha=165)
            put_text(p, (x, lh - 96), vl, kai(38, "m"), WHITE, alpha=230)
            if i < 2:
                d.line((x + cw - 34, lh - 136, x + cw - 34, lh - 84),
                       fill=rgba((120, 160, 200), 50), width=2)
    else:
        put_text(p, (52, 44), "本地时间", kai(30, "m"), ACCENTS["clock"], alpha=220, ls=6)
        put_text(p, (52, 96), "杭州 · 中国", kai(25), DIM, alpha=150, ls=3)
        big = mono(132)
        put_text(p, (48, 140), hms[:5], big, WHITE)
        tw = text_size(hms[:5], big)[0]
        put_text(p, (54 + tw + 10, 208), hms[6:], mono(54), ACCENTS["clock"], alpha=230)
        d.line((48, lh - 96, lw - 48, lh - 96), fill=rgba((110, 150, 200), 58), width=2)
        put_text(p, (48, lh - 74), date_txt + "  " + week, kai(31), WHITE, alpha=205)
    return p


def clock_strip_layer(size, seconds):
    """分镜 3/4 用的压缩版时钟条 (920x300)"""
    lw, lh = size
    p = panel((lw, lh))
    d = ImageDraw.Draw(p)
    d.rounded_rectangle((0, 40, 9, lh - 40), radius=5, fill=rgba(ACCENTS["clock"], 210))
    hms = seconds_to_hhmmss(seconds)

    put_text(p, (50, 32), "本地时间", kai(27, "m"), ACCENTS["clock"], alpha=215, ls=5)
    put_text(p, (50, 74), "杭州 · 中国", kai(23), DIM, alpha=150, ls=3)

    big = mono(98)
    put_text(p, (46, 104), hms[:5], big, WHITE)
    tw = text_size(hms[:5], big)[0]
    put_text(p, (54 + tw + 10, 152), hms[6:], mono(42), ACCENTS["clock"], alpha=230)

    put_text(p, (lw - 50, 108), "2026-10-02", kai(30, "m"), WHITE, alpha=205, anchor="ra")
    put_text(p, (lw - 50, 158), "星期五", kai(26), DIM, alpha=165, anchor="ra")
    return p


_cn_week = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]


def seconds_to_hhmmss(sec):
    sec = int(sec) % 86400
    return "%02d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)


def weather_glyph(size, kind="cloud", t=0.0, color=(255, 200, 110)):
    """简易天气图形: sun / cloud / sun+cloud"""
    w, h = size
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if kind in ("sun", "suncloud"):
        cx, cy, r = w * (0.36 if kind == "suncloud" else 0.5), h * 0.4, min(w, h) * 0.21
        for i in range(12):
            a = i * math.pi / 6 + t * 0.25
            x1 = cx + math.cos(a) * r * 1.32
            y1 = cy + math.sin(a) * r * 1.32
            x2 = cx + math.cos(a) * r * 1.62
            y2 = cy + math.sin(a) * r * 1.62
            d.line((x1, y1, x2, y2), fill=rgba(color, 150), width=max(3, int(w * 0.022)))
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=rgba(color, 235))
    if kind in ("cloud", "suncloud"):
        oy = h * (0.52 if kind == "suncloud" else 0.46)
        c = (222, 234, 248)
        d.ellipse((w * 0.10, oy - h * 0.10, w * 0.42, oy + h * 0.10), fill=rgba(c, 235))
        d.ellipse((w * 0.30, oy - h * 0.19, w * 0.70, oy + h * 0.11), fill=rgba(c, 245))
        d.ellipse((w * 0.58, oy - h * 0.07, w * 0.92, oy + h * 0.13), fill=rgba(c, 235))
        d.rounded_rectangle((w * 0.12, oy + h * 0.02, w * 0.90, oy + h * 0.14),
                            radius=int(h * 0.06), fill=rgba(c, 245))
    return img


def weather_layer(size, t_local, temp, rows, show_rows, zoom=1.0):
    lw, lh = size
    p = panel((lw, lh), top=(28, 40, 62), bot=(17, 27, 44), edge=(150, 160, 120))
    d = ImageDraw.Draw(p)

    d.rounded_rectangle((0, 70, 9, lh - 70), radius=5, fill=rgba(ACCENTS["weather"], 210))

    put_text(p, (52, 42), "杭州 · 西湖区", kai(34, "m"), WHITE, alpha=225, ls=3)
    put_text(p, (lw - 48, 48), "刚刚更新", kai(24), DIM, alpha=140, anchor="ra")

    # 温度(随入场数字滚动)
    tstr = "%d" % int(round(temp))
    put_text(p, (50, 92), tstr, mono(int(138 * zoom)), WHITE, alpha=255)
    tw = text_size(tstr, mono(int(138 * zoom)))[0]
    put_text(p, (56 + tw + 6, 130), "°", mono(int(88 * zoom)), ACCENTS["weather"], alpha=235)

    put_text(p, (58, 248), "多云", kai(40, "m"), WHITE, alpha=225)
    put_text(p, (58, 302), "体感 27° · 空气 良", kai(26), DIM, alpha=165)

    g = weather_glyph((280, 210), "suncloud", t_local, color=ACCENTS["weather"])
    p.alpha_composite(g, (lw - 330, 74))

    d.line((48, lh - 140, lw - 48, lh - 140), fill=rgba((120, 160, 200), 58), width=2)

    # 底部三格
    cell_w = (lw - 96) / 3
    for i, (label, value) in enumerate(rows):
        cx = 48 + cell_w * i
        a = show_rows[i]
        if a <= 0.01:
            continue
        rise = int((1 - a) * 16)
        put_text(p, (cx, lh - 116 + rise), label, kai(26), DIM, alpha=int(170 * a))
        put_text(p, (cx, lh - 74 + rise), value, kai(38, "m"), WHITE, alpha=int(235 * a))
        if i < 2:
            d.line((cx + cell_w - 34, lh - 114, cx + cell_w - 34, lh - 62),
                   fill=rgba((120, 160, 200), 50), width=2)
    return p


BIG_TXT_PAD = 500


def pomo_layer(size, t_local, remain, total, running, done_count, zoom=1.0):
    lw, lh = size
    p = panel((lw, lh), top=(34, 38, 60), bot=(19, 22, 40), edge=(210, 140, 170))
    d = ImageDraw.Draw(p)

    d.rounded_rectangle((0, 70, 9, lh - 70), radius=5, fill=rgba(ACCENTS["pomo"], 210))
    put_text(p, (52, 44), "专注 · 番茄钟", kai(34, "m"), WHITE, alpha=225, ls=3)
    state = "进行中" if running else "已暂停"
    col = ACCENTS["pomo"] if running else DIM
    put_text(p, (lw - 48, 50), state, kai(26), col, alpha=180, anchor="ra")

    # 环形进度
    cy = 206
    R = 104
    cx = lw / 2
    prog = 1 - clamp(remain / total)
    d.ellipse((cx - R, cy - R, cx + R, cy + R), outline=rgba((96, 122, 160), 70), width=16)
    steps = 140
    pts = []
    for i in range(steps + 1):
        a = math.radians(-90 + 360 * prog * i / steps)
        pts.append((cx + math.cos(a) * R, cy + math.sin(a) * R))
    if len(pts) > 2:
        d.line(pts, fill=rgba(ACCENTS["pomo"], 240), width=16, joint="curve")

    # 进度头光点(在独立层上算, 免去外发光被卡片边缘裁切)
    ha = math.radians(-90 + 360 * prog)
    hx, hy = cx + math.cos(ha) * R, cy + math.sin(ha) * R
    head = Image.new("RGBA", (lw, lh), (0, 0, 0, 0))
    head = add_glow_circle(head, hx, hy, 20, ACCENTS["pomo"], strength=150, blur=16)
    ImageDraw.Draw(head).ellipse((hx - 13, hy - 13, hx + 13, hy + 13),
                                 fill=rgba((255, 242, 246), 255))
    p = Image.alpha_composite(p, head)

    mm, ss = int(remain) // 60, int(remain) % 60
    put_text(p, (cx, cy - 40), "%02d:%02d" % (mm, ss), mono(int(76 * zoom)), WHITE,
             anchor="ma")

    d.line((48, lh - 186, lw - 48, lh - 186), fill=rgba((150, 150, 190), 55), width=2)

    # 两段式 专注/休息
    seg_y = lh - 160
    seg_w = (lw - 96) // 2
    d.rounded_rectangle((48, seg_y, 48 + seg_w - 10, seg_y + 58), radius=29,
                        fill=rgba(ACCENTS["pomo"], 46),
                        outline=rgba(ACCENTS["pomo"], 120), width=2)
    put_text(p, (48 + (seg_w - 10) / 2, seg_y + 15), "专注 25 分钟", kai(28, "m"),
             ACCENTS["pomo"], alpha=235, anchor="ma")
    d.rounded_rectangle((48 + seg_w + 10, seg_y, lw - 48, seg_y + 58), radius=29,
                        outline=rgba((120, 150, 190), 90), width=2)
    put_text(p, (48 + seg_w + 10 + (seg_w - 10) / 2, seg_y + 15), "休息 5 分钟", kai(28),
             DIM, alpha=190, anchor="ma")

    put_text(p, (48, lh - 84), "今日已完成 %d 个" % done_count, kai(28), WHITE,
             alpha=205)
    for i in range(5):
        bx = lw - 48 - (4 - i) * 46
        on = i < min(5, done_count + 1)
        d.ellipse((bx - 15, lh - 78, bx + 15, lh - 48),
                  fill=rgba(ACCENTS["pomo"], 225) if on else rgba((110, 130, 165), 90))
    return p


def conclusion_layer(size, rows, show):
    lw, lh = size
    p = panel((lw, lh), top=(24, 40, 62), bot=(14, 24, 42), edge=(120, 190, 240))
    d = ImageDraw.Draw(p)
    put_text(p, (lw / 2, 40), "为什么它值得放桌角", kai(30, "m"), ACCENTS["brand"],
             alpha=230, ls=8, anchor="ma")
    y = 96
    for i, (title, sub) in enumerate(rows):
        a = show[i]
        rise = int((1 - a) * 26)
        if a <= 0.01:
            continue
        d.ellipse((50, y + 14 + rise, 66, y + 30 + rise), fill=rgba(ACCENTS["brand"], int(240 * a)))
        put_text(p, (84, y + rise), title, kai(38, "m"), WHITE, alpha=int(240 * a))
        put_text(p, (84, y + 48 + rise), sub, kai(25), DIM, alpha=int(175 * a))
        if i < len(rows) - 1:
            d.line((50, y + 96, lw - 50, y + 96), fill=rgba((120, 160, 210), 42), width=2)
        y += 112
    return p


def brand_layer(size):
    lw, lh = size
    p = panel((lw, lh), radius=44, top=(26, 44, 70), bot=(15, 26, 44), edge=(110, 190, 245))
    put_text(p, (lw / 2, lh / 2 - 44), "用小聆 AI 开发", kai(40, "b"), WHITE, alpha=245,
             ls=6, anchor="ma")
    put_text(p, (lw / 2, lh / 2 + 26), "一句话，就能做小应用", kai(28), ACCENTS["brand"],
             alpha=215, ls=4, anchor="ma")
    return p


def chip_layer(size, kind, main, sub, accent, t_local=0.0):
    """三合一里的图标小卡"""
    lw, lh = size
    p = panel((lw, lh), radius=40, top=(28, 44, 68), bot=(17, 28, 46), edge=accent)
    d = ImageDraw.Draw(p)
    d.rounded_rectangle((0, 26, 7, lh - 26), radius=4, fill=rgba(accent, 220))

    iw = lh - 60
    ix, iy = 40, 30
    d.rounded_rectangle((ix, iy, ix + iw, iy + iw), radius=30, fill=rgba(accent, 42),
                        outline=rgba(accent, 110), width=2)
    cx, cy = ix + iw / 2, iy + iw / 2
    if kind == "clock":
        r = iw * 0.28
        d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=rgba(accent, 235), width=5)
        d.line((cx, cy, cx, cy - r * 0.62), fill=rgba(accent, 235), width=5)
        d.line((cx, cy, cx + r * 0.46, cy + r * 0.3), fill=rgba(accent, 235), width=5)
    elif kind == "weather":
        g = weather_glyph((int(iw * 0.82), int(iw * 0.82)), "suncloud", t_local, color=accent)
        p.alpha_composite(g, (int(ix + iw * 0.09), int(iy + iw * 0.09)))
    else:
        r = iw * 0.28
        d.arc((cx - r, cy - r, cx + r, cy + r), -90, 180, fill=rgba(accent, 235), width=6)
        d.arc((cx - r, cy - r, cx + r, cy + r), 180, 250, fill=rgba((110, 130, 165), 120), width=6)
        d.ellipse((cx - 6, cy - r - 6, cx + 6, cy - r + 6), fill=rgba(accent, 255))

    tx = ix + iw + 34
    put_text(p, (tx, iy + 6), sub, kai(26), DIM, alpha=170, ls=2)
    put_text(p, (tx, iy + 48), main, mono(52), WHITE, alpha=242)
    return p


# ---------------------------------------------------------------- 版面常量
T_HERO = (80, 500, 1000, 1180)     # 920 x 680
T_SM = (80, 470, 1000, 990)        # 920 x 520
T_W = (80, 1040, 1000, 1560)       # 920 x 520
CONC = (80, 520, 1000, 1040)       # 920 x 520
BRAND = (100, 1100, 980, 1360)     # 880 x 260
CHIPS = [(60, 700, 560, 900), (60, 930, 560, 1130), (60, 1160, 560, 1360)]
SIDE = (610, 700, 1020, 1360)      # 410 x 660

CARD_R = 52
CLOCK_S = 9 * 3600 + 41 * 60 + 14

T_S1, T_S2, T_S3, T_S4, T_S5, T_S6 = 0.0, 3.5, 9.5, 17.5, 22.8, 28.0

T_SM2 = (80, 740, 1000, 1260)      # 920 x 520 (天气/番茄共用槽位)
T_STRIP = (80, 420, 1000, 720)     # 920 x 300 (时钟压条)

S5_LINES = [
    ("零代码门槛", "说一句需求，小聆 AI 就帮你写出来"),
    ("桌面就能调试", "模拟器里改完即见，确认后再推给设备"),
    ("一个设备，三种日常", "时钟、天气、专注，抬眼即得"),
]
WEATHER_ROWS = [("最高 / 最低", "28° / 21°"), ("湿度", "62%"), ("东南风", "2 级")]
POMO_TOTAL = 25 * 60
POMO_START_T = 9.5 + 0.95        # 番茄开始走字的时间点
POMO_BASE_REMAIN = 12 * 60       # 演示起始余量(环上先有可见弧长)
POMO_SPEED = 20.0                # 加速系数: 1 秒画面 ≈ 20 秒番茄时间


def pomo_remain(t):
    return max(0.0, POMO_BASE_REMAIN - max(0.0, t - POMO_START_T) * POMO_SPEED)


def flash(img, t, at, dur=0.26, color=(170, 215, 255), strength=64):
    d = abs(t - at)
    if d > dur:
        return img
    a = int(strength * (1 - d / dur) ** 2)
    return Image.alpha_composite(img, Image.new("RGBA", (W, H), rgba(color, a)))


def load_bar(img, t):
    """底部进度条"""
    if t > 28.4:
        return img
    a = 0.55 if t < 27.8 else 0.55 * (28.4 - t) / 0.6
    y = H - 8
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle((0, y, W, H), fill=(255, 255, 255, 0))
    d.rectangle((0, y, int(W * clamp(t / 28.0)), H), fill=rgba(ACCENTS["brand"], int(150 * a)))
    return img


def watermark(img, t):
    if not (0.8 < t < 27.9):
        return img
    a = 130 if t < 27.2 else 130 * (27.9 - t) / 0.7
    put_text(img, (W / 2, 1832), "小聆 AI · LingClaw 小应用", kai(25), DIM,
             alpha=int(a), ls=3, anchor="ma")
    return img


def mini_ui_layer(size, t_local, seconds, remain):
    """三合一右侧的合成界面 (410x660)"""
    lw, lh = size
    p = panel((lw, lh), radius=46, top=(26, 42, 66), bot=(16, 27, 45), edge=(120, 185, 235))
    d = ImageDraw.Draw(p)
    hms = seconds_to_hhmmss(seconds)

    put_text(p, (32, 24), hms[:5], mono(72), WHITE)
    tw = text_size(hms[:5], mono(72))[0]
    put_text(p, (38 + tw + 8, 48), hms[6:], mono(30), ACCENTS["clock"], alpha=225)
    put_text(p, (lw - 30, 38), "星期五", kai(23), DIM, alpha=150, anchor="ra")

    d.line((28, 130, lw - 28, 130), fill=rgba((120, 160, 210), 60), width=2)

    g = weather_glyph((120, 96), "suncloud", t_local, color=ACCENTS["weather"])
    p.alpha_composite(g, (26, 148))
    put_text(p, (160, 150), "26°", mono(54), WHITE)
    put_text(p, (160, 214), "多云 · 杭州", kai(24), DIM, alpha=180)

    d.line((28, 276, lw - 28, 276), fill=rgba((120, 160, 210), 60), width=2)

    cx, cy, R = lw / 2, 398, 70
    prog = 1 - clamp(remain / POMO_TOTAL)
    d.ellipse((cx - R, cy - R, cx + R, cy + R), outline=rgba((96, 122, 160), 75), width=13)
    pts = []
    for i in range(97):
        a = math.radians(-90 + 360 * prog * i / 96)
        pts.append((cx + math.cos(a) * R, cy + math.sin(a) * R))
    if len(pts) > 1:
        d.line(pts, fill=rgba(ACCENTS["pomo"], 240), width=13, joint="curve")
    mm, ss = int(remain) // 60, int(remain) % 60
    put_text(p, (cx, cy - 32), "%02d:%02d" % (mm, ss), mono(48), WHITE, anchor="ma")
    put_text(p, (cx, cy + R + 30), "专注中 · 今日 2 个", kai(23), DIM, alpha=175, anchor="ma")

    d.line((28, 558, lw - 28, 558), fill=rgba((120, 160, 210), 60), width=2)
    dot = Image.new("RGBA", (20, 20), (0, 0, 0, 0))
    ImageDraw.Draw(dot).ellipse((3, 3, 17, 17), fill=rgba((110, 240, 170), 255))
    p.alpha_composite(dot, (30, 592))
    put_text(p, (60, 586), "已联网 · 自动校时", kai(23), DIM, alpha=170)
    return p


# ---------------------------------------------------------------- 分镜
def scene1(t):
    img = background(t)
    a = seq(t, 0.10, 0.85, ease_out)
    r = lerp_rect((T_HERO[0], T_HERO[1] + 90, T_HERO[2], T_HERO[3] + 90), T_HERO, a)
    clk = clock_layer(rect_size(T_HERO), CLOCK_S + t, mode="hero")
    img = compose_card(img, clk, r, alpha=a, glow=ACCENTS["clock"], glow_strength=90)

    ka = seq(t, 0.55, 0.6)
    put_text(img, (W / 2, 300 + int((1 - ka) * 22)), "时钟 · 天气 · 番茄钟", kai(74, "b"),
             WHITE, alpha=int(248 * ka), ls=6, anchor="ma")
    put_text(img, (W / 2, 402 + int((1 - ka) * 18)), "小聆 AI 小应用 · 介绍", kai(30),
             ACCENTS["brand"], alpha=int(225 * ka), ls=6, anchor="ma")
    put_text(img, (W / 2, 1330), "一块屏幕，三件事", kai(38), WHITE, alpha=int(232 * seq(t, 1.1, 0.7)), ls=4, anchor="ma")
    put_text(img, (W / 2, 1394), "看时间 · 看天气 · 管专注", kai(28), DIM,
             alpha=int(180 * seq(t, 1.35, 0.7)), ls=3, anchor="ma")
    return flash(img, t, 0.05, 0.3, strength=52)


def scene2(t):
    img = background(t)
    # 时钟上移收缩
    k = ease_in_out(clamp((t - T_S2) / 0.9))
    csmall = seq(t, T_S2 + 0.9, 0.5)
    r = lerp_rect(T_HERO, T_SM, k)
    clk = clock_layer(rect_size(r), CLOCK_S + t, mode="card")
    img = compose_card(img, clk, r, alpha=clamp(0.25 + 0.75 * csmall), glow=ACCENTS["clock"],
                       glow_strength=70)
    # 天气卡
    wa = seq(t, T_S2 + 0.45, 0.75, ease_out_back)
    wr = lerp_rect((T_W[0], T_W[1] + 150, T_W[2], T_W[3] + 150), T_W, clamp(wa))
    rows = [seq(t, T_S2 + 1.25 + i * 0.30, 0.5) for i in range(3)]
    temp = 26 * seq(t, T_S2 + 0.8, 0.9, ease_out)
    zero = seq(t, T_S2 + 1.05, 0.5)
    wlay = weather_layer(rect_size(T_W), t, temp, WEATHER_ROWS, rows, zoom=clamp(0.86 + 0.14 * zero))
    img = compose_card(img, wlay, wr, alpha=clamp(wa * 1.3), glow=ACCENTS["weather"],
                       glow_strength=85)

    ha = seq(t, T_S2 + 0.3, 0.6)
    put_text(img, (W / 2, 322 + int((1 - ha) * 18)), "出门之前，先看它一眼", kai(46, "b"),
             WHITE, alpha=int(242 * ha), ls=5, anchor="ma")
    put_text(img, (W / 2, 396), "温度 · 体感 · 湿度 · 风力，一屏读完", kai(27), DIM,
             alpha=int(185 * seq(t, T_S2 + 1.6, 0.6)), ls=2, anchor="ma")
    put_text(img, (W / 2, 1660), "不用摸手机，抬眼就有答案", kai(31), ACCENTS["weather"],
             alpha=int(215 * seq(t, T_S2 + 2.2, 0.6)), ls=3, anchor="ma")
    return img


def scene3(t):
    img = background(t)
    # 时钟压成顶条: 前段用大卡等比缩到目标尺寸, 后半段换成压缩版(内容不溢出)
    k = ease_in_out(clamp((t - T_S3) / 0.85))
    r = lerp_rect(T_SM, T_STRIP, k)
    if k < 0.62:
        lay = clock_layer(rect_size(T_SM), CLOCK_S + t, mode="card").resize(
            rect_size(T_STRIP), Image.LANCZOS)
    else:
        lay = clock_strip_layer(rect_size(T_STRIP), CLOCK_S + t)
    img = compose_card(img, lay, r, glow=ACCENTS["clock"], glow_strength=55)

    # 天气下移淡出
    out = ease_in_out(clamp((t - T_S3 - 0.15) / 0.7))
    if out < 1:
        wr = lerp_rect(T_SM2, (T_SM2[0], T_SM2[1] + 190, T_SM2[2], T_SM2[3] + 190), out)
        wlay = weather_layer(rect_size(T_SM2), t, 26, WEATHER_ROWS, [1, 1, 1])
        img = compose_card(img, wlay, wr, alpha=1 - out, shadow=False)

    # 番茄卡推入 (余量按真实速度走: 25 分钟 = 1500 秒)
    pa = seq(t, T_S3 + 0.6, 0.8, ease_out_back)
    pr = lerp_rect((T_SM2[0], T_SM2[1] + 170, T_SM2[2], T_SM2[3] + 170), T_SM2, clamp(pa))
    remain = pomo_remain(t)
    running = t > T_S3 + 0.95
    play = seq(t, T_S3 + 1.5, 0.8)
    pl = pomo_layer(rect_size(T_SM2), t, remain, POMO_TOTAL, running, 2,
                    zoom=clamp(0.9 + 0.1 * play))
    img = compose_card(img, pl, pr, alpha=clamp(pa * 1.3), glow=ACCENTS["pomo"],
                       glow_strength=95)

    ha = seq(t, T_S3 + 0.4, 0.6)
    put_text(img, (W / 2, 300 + int((1 - ha) * 16)), "一个番茄，二十五分钟", kai(46, "b"),
             WHITE, alpha=int(242 * ha), ls=5, anchor="ma")
    put_text(img, (W / 2, 1660), "按下开始，剩下的交给它", kai(31), ACCENTS["pomo"],
             alpha=int(215 * seq(t, T_S3 + 2.4, 0.6)), ls=3, anchor="ma")
    return img


def scene4(t):
    img = background(t)
    # 番茄卡与顶条收束
    out = ease_in_out(clamp((t - T_S4) / 0.7))
    if out < 1:
        r = lerp_rect(T_STRIP, (T_STRIP[0], T_STRIP[1] - 120, T_STRIP[2], T_STRIP[3] - 120), out)
        clk = clock_layer(rect_size(T_STRIP), CLOCK_S + t, mode="card")
        img = compose_card(img, clk, r, alpha=1 - out, shadow=False)
        pr = lerp_rect(T_SM2, (T_SM2[0] - 90, T_SM2[1], T_SM2[2] - 90, T_SM2[3]), out)
        remain = max(0.0, POMO_TOTAL - (t - (T_S3 + 0.95)) * 1.35)
        pl = pomo_layer(rect_size(T_SM2), t, remain, POMO_TOTAL, True, 2)
        img = compose_card(img, pl, pr, alpha=1 - out, shadow=False)

    # 三张图标小卡
    remain = max(0.0, POMO_TOTAL - (t - (T_S3 + 0.95)) * 1.35)
    kinds = [
        ("clock", seconds_to_hhmmss(CLOCK_S + t)[:5], "时钟", ACCENTS["clock"], 0.05),
        ("weather", "26° 多云", "天气", ACCENTS["weather"], 0.32),
        ("pomo", "%02d:%02d" % (int(remain) // 60, int(remain) % 60), "专注", ACCENTS["pomo"], 0.59),
    ]
    for i, (kind, main, sub, acc, delay) in enumerate(kinds):
        a = seq(t, T_S4 + delay, 0.7, ease_out_back)
        if a <= 0.01:
            continue
        r = lerp_rect((CHIPS[i][0] - 130, CHIPS[i][1], CHIPS[i][2] - 130, CHIPS[i][3]), CHIPS[i], clamp(a))
        lay = chip_layer(rect_size(CHIPS[i]), kind, main, sub, acc, t)
        img = compose_card(img, lay, r, alpha=clamp(a * 1.3), glow=acc, glow_strength=62,
                           radius=40)

    # 右侧合成界面
    sa = seq(t, T_S4 + 0.85, 0.85, ease_out_back)
    if sa > 0.01:
        sr = lerp_rect((SIDE[0] + 150, SIDE[1], SIDE[2] + 150, SIDE[3]), SIDE, clamp(sa))
        lay = mini_ui_layer(rect_size(SIDE), t, CLOCK_S + t, remain)
        img = compose_card(img, lay, sr, alpha=clamp(sa * 1.3), glow=ACCENTS["brand"],
                           glow_strength=80, radius=46)

    ha = seq(t, T_S4 + 0.2, 0.6)
    put_text(img, (W / 2, 320 + int((1 - ha) * 16)), "三合一，一台设备就够", kai(46, "b"),
             WHITE, alpha=int(242 * ha), ls=5, anchor="ma")
    put_text(img, (W / 2, 392), "长在一块屏幕上，放在桌角", kai(27), DIM,
             alpha=int(185 * seq(t, T_S4 + 1.3, 0.6)), ls=2, anchor="ma")
    put_text(img, (W / 2, 1630), "抬眼就看得见", kai(34, "m"), ACCENTS["brand"],
             alpha=int(225 * seq(t, T_S4 + 3.0, 0.6)), ls=6, anchor="ma")
    return img


def scene5(t):
    img = background(t)
    out = ease_in_out(clamp((t - T_S5) / 0.55))
    if out < 1:
        for i in range(3):
            sp = lerp_rect(CHIPS[i], (CHIPS[i][0] - 160, CHIPS[i][1], CHIPS[i][2] - 160, CHIPS[i][3]), out)
            kinds = [("clock", seconds_to_hhmmss(CLOCK_S + t)[:5], "时钟", ACCENTS["clock"]),
                     ("weather", "26° 多云", "天气", ACCENTS["weather"]),
                     ("pomo", "18:24", "专注", ACCENTS["pomo"])][i]
            lay = chip_layer(rect_size(CHIPS[i]), kinds[0], kinds[1], kinds[2], kinds[3], t)
            img = compose_card(img, lay, sp, alpha=1 - out, shadow=False, radius=40)
        sr = lerp_rect(SIDE, (SIDE[0] + 160, SIDE[1], SIDE[2] + 160, SIDE[3]), out)
        remain = max(0.0, POMO_TOTAL - (t - (T_S3 + 0.95)) * 1.35)
        lay = mini_ui_layer(rect_size(SIDE), t, CLOCK_S + t, remain)
        img = compose_card(img, lay, sr, alpha=1 - out, shadow=False, radius=46)

    ha = seq(t, T_S5 + 0.15, 0.6)
    put_text(img, (W / 2, 300 + int((1 - ha) * 16)), "用小聆 AI 开发", kai(52, "b"),
             WHITE, alpha=int(245 * ha), ls=7, anchor="ma")
    put_text(img, (W / 2, 378), "一句话，就能做小应用", kai(29), ACCENTS["brand"],
             alpha=int(220 * seq(t, T_S5 + 0.4, 0.6)), ls=5, anchor="ma")

    y = 500
    for i, (title, sub) in enumerate(S5_LINES):
        a = seq(t, T_S5 + 0.6 + i * 0.45, 0.65, ease_out_back)
        rise = int((1 - clamp(a)) * 34)
        if a > 0.01:
            d = ImageDraw.Draw(img, "RGBA")
            d.ellipse((100, y + 16 + rise, 122, y + 38 + rise),
                      fill=rgba(ACCENTS["brand"], int(240 * clamp(a))))
            d.line((104, y + 27 + rise, 109, y + 33 + rise),
                   fill=rgba((10, 22, 38), int(255 * clamp(a))), width=4)
            d.line((109, y + 33 + rise, 119, y + 20 + rise),
                   fill=rgba((10, 22, 38), int(255 * clamp(a))), width=4)
            put_text(img, (144, y + rise), title, kai(44, "m"), WHITE,
                     alpha=int(240 * clamp(a)), ls=2)
            put_text(img, (146, y + 62 + rise), sub, kai(26), DIM,
                     alpha=int(180 * clamp(a)), ls=1)
        y += 128

    ba = seq(t, T_S5 + 2.15, 0.8, ease_out_back)
    if ba > 0.01:
        br = lerp_rect((BRAND[0] + 60, BRAND[1] + 70, BRAND[2] + 60, BRAND[3] + 70), BRAND, clamp(ba))
        lay = brand_layer(rect_size(BRAND))
        img = compose_card(img, lay, br, alpha=clamp(ba * 1.3), glow=ACCENTS["brand"],
                           glow_strength=110, radius=44)
    return img


def scene6(t):
    e = ease_in_out(clamp((t - T_S6) / 0.7))
    img = background(t)
    if e < 1:
        img = background(t)
    img = Image.blend(img, Image.new("RGBA", (W, H), (0, 0, 0, 255)), e)
    a = seq(t, T_S6 + 0.9, 0.8)
    if a > 0.01:
        put_text(img, (W / 2, H / 2 - 20), "接下来，看它真正跑起来", kai(40, "m"), WHITE,
                 alpha=int(190 * a), ls=8, anchor="ma")
        put_text(img, (W / 2, H / 2 + 66), "功能演示", kai(26), DIM,
                 alpha=int(120 * a), ls=10, anchor="ma")
    return img


def render_scene(t):
    if t < T_S2:
        img = scene1(t)
    elif t < T_S3:
        img = scene2(t)
    elif t < T_S4:
        img = scene3(t)
    elif t < T_S5:
        img = scene4(t)
    elif t < T_S6:
        img = scene5(t)
    else:
        img = scene6(t)
    for at in (T_S2, T_S3, T_S4, T_S5):
        if 0 < at:
            img = flash(img, t, at, 0.24, strength=42)
    img = watermark(img, t)
    img = load_bar(img, t)
    img = add_vignette(img, 0.34)
    return img.convert("RGB")


# ---------------------------------------------------------------- 主程序
PREVIEW_T = [1.6, 5.4, 12.2, 20.0, 25.6, 29.0]


def contact_sheet(paths, out_path, cols=3, thumb_w=340):
    thumbs = []
    for p in paths:
        im = Image.open(p).convert("RGB")
        h = int(im.height * thumb_w / im.width)
        thumbs.append(im.resize((thumb_w, h), Image.LANCZOS))
    if not thumbs:
        return
    tw, th = thumbs[0].size
    rows = (len(thumbs) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * tw + (cols + 1) * 12, rows * th + (rows + 1) * 12),
                      (18, 18, 22))
    for i, im in enumerate(thumbs):
        r, c = divmod(i, cols)
        sheet.paste(im, (12 + c * (tw + 12), 12 + r * (th + 12)))
    sheet.save(out_path)


def main():
    init_assets()
    if "--preview" in sys.argv:
        os.makedirs(PREVIEW, exist_ok=True)
        paths = []
        for t in PREVIEW_T:
            f = int(round(t * FPS))
            img = render_scene(f / FPS)
            p = os.path.join(PREVIEW, "t%05.2f.png" % t)
            img.save(p)
            paths.append(p)
            print("预览帧", p)
        contact_sheet(paths, os.path.join(PREVIEW, "contact_sheet.png"))
        print("预览合图", os.path.join(PREVIEW, "contact_sheet.png"))
        return

    os.makedirs(OUT, exist_ok=True)
    only = None
    for i, a in enumerate(sys.argv):
        if a == "--frames" and i + 1 < len(sys.argv):
            only = sys.argv[i + 1]
    rng = range(NFRAMES)
    if only:
        lo, _, hi = only.partition("-")
        rng = range(int(lo), int(hi) + 1 if hi else int(lo) + 1)
    for f in rng:
        t = f / FPS
        img = render_scene(t)
        img.save(os.path.join(OUT, "f%05d.png" % f), compress_level=1)
        if f % 30 == 0:
            print("  帧 %d/%d  t=%.2fs" % (f, NFRAMES, t), flush=True)
    print("完成, 共 %d 帧 -> %s" % (len(list(rng)), OUT))


if __name__ == "__main__":
    main()
