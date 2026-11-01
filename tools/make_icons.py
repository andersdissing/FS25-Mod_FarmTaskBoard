"""Draws the mod's icons and writes them as DDS (BC1/DXT1, no mipmaps, as ModHub wants):

  Build/icon_FarmTaskBoard.dds  512x512  mod icon (opaque)
  Build/icon_tab.dds            256x256  menu tab and header icon: white on transparent

PNG previews go to Docs/icons/. Usage: python tools/make_icons.py      Needs: pip install pillow
"""
import os
import struct

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "Build")
PREVIEW = os.path.join(ROOT, "Docs", "icons")

GREEN = (141, 198, 63)
YELLOW = (224, 176, 48)
GREY = (122, 122, 122)


def mod_icon(size=512):
    s = size / 512
    img = Image.new("RGBA", (size, size), (24, 30, 18, 255))
    d = ImageDraw.Draw(img)
    # Board
    d.rounded_rectangle([28 * s, 28 * s, 484 * s, 484 * s], radius=26 * s, fill=(38, 44, 32, 255), outline=(77, 107, 37, 255), width=int(6 * s))
    d.rectangle([54 * s, 31 * s, 458 * s, 42 * s], fill=GREEN)
    cols = [(GREY, 3), (YELLOW, 2), (GREEN, 3)]
    colw = 128 * s
    for i, (color, n) in enumerate(cols):
        x0 = 52 * s + i * (colw + 16 * s)
        d.rectangle([x0, 70 * s, x0 + colw, 82 * s], fill=color)
        for j in range(n):
            y0 = 104 * s + j * 120 * s
            d.rectangle([x0, y0, x0 + colw, y0 + 96 * s], fill=(58, 64, 50, 255))
            d.rectangle([x0, y0, x0 + 12 * s, y0 + 96 * s], fill=color)
            for k in range(2):
                ly = y0 + 28 * s + k * 30 * s
                d.rectangle([x0 + 26 * s, ly, x0 + colw - (16 + 30 * k) * s, ly + 12 * s], fill=(205, 210, 196, 255))
    # Check mark on the done column
    x0 = 52 * s + 2 * (colw + 16 * s)
    d.line([(x0 + 34 * s, 430 * s), (x0 + 58 * s, 454 * s), (x0 + 100 * s, 404 * s)], fill=GREEN, width=int(14 * s), joint="curve")
    return img


def tab_icon(size=256):
    s = size / 256
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)
    colw = 62 * s
    for i, n in enumerate([3, 2, 3]):
        x0 = 22 * s + i * (colw + 13 * s)
        d.rectangle([x0, 24 * s, x0 + colw, 38 * s], fill=white)
        for j in range(n):
            y0 = 56 * s + j * 62 * s
            d.rectangle([x0, y0, x0 + colw, y0 + 48 * s], fill=white)
    return img


def rgb565(c):
    r, g, b = c[:3]
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def unpack565(v):
    r = (v >> 11) & 31
    g = (v >> 5) & 63
    b = v & 31
    return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)


def encode_block(pixels):
    """BC1 block from 16 RGBA pixels; alpha < 128 = transparent (punch-through)."""
    opaque = [p for p in pixels if p[3] >= 128]
    transparent = len(opaque) < 16
    if not opaque:
        return struct.pack("<HHI", 0, 0, 0xFFFFFFFF)

    def lum(p):
        return p[0] * 299 + p[1] * 587 + p[2] * 114

    lo = min(opaque, key=lum)
    hi = max(opaque, key=lum)
    a, b = rgb565(hi), rgb565(lo)
    if transparent:
        c0, c1 = min(a, b), max(a, b)  # c0 <= c1: 3 colours + transparent
        p0, p1 = unpack565(c0), unpack565(c1)
        palette = [p0, p1, tuple((x + y) // 2 for x, y in zip(p0, p1))]
    else:
        if a == b:
            c0, c1 = a, b
            p0 = unpack565(c0)
            palette = [p0, p0, p0]
        else:
            c0, c1 = max(a, b), min(a, b)  # c0 > c1: 4 colours
            p0, p1 = unpack565(c0), unpack565(c1)
            palette = [p0, p1, tuple((2 * x + y) // 3 for x, y in zip(p0, p1)), tuple((x + 2 * y) // 3 for x, y in zip(p0, p1))]
    bits = 0
    for i, p in enumerate(pixels):
        if transparent and p[3] < 128:
            idx = 3
        else:
            idx = min(range(len(palette)), key=lambda k: sum((palette[k][j] - p[j]) ** 2 for j in range(3)))
        bits |= idx << (2 * i)
    return struct.pack("<HHI", c0, c1, bits)


def write_dds(img, path):
    w, h = img.size
    px = img.load()
    blocks = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            blocks += encode_block([px[bx + x, by + y] for y in range(4) for x in range(4)])
    header = struct.pack("<4sIIIIIII", b"DDS ", 124, 0x81007, h, w, w * h // 2, 0, 0)
    header += b"\0" * 44
    header += struct.pack("<II4sIIIII", 32, 0x4, b"DXT1", 0, 0, 0, 0, 0)
    header += struct.pack("<IIIII", 0x1000, 0, 0, 0, 0)
    assert len(header) == 128
    with open(path, "wb") as f:
        f.write(header + bytes(blocks))


if __name__ == "__main__":
    os.makedirs(PREVIEW, exist_ok=True)
    for img, name in ((mod_icon(), "icon_FarmTaskBoard"), (tab_icon(), "icon_tab")):
        write_dds(img, os.path.join(BUILD, name + ".dds"))
        img.save(os.path.join(PREVIEW, name + ".png"))
        print("wrote", name)
