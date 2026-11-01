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
SS = 4  # drawn 4x larger, then scaled down (smooth edges)


def pen_polygons(tip, toward, length, width):
    """Pencil from tip towards a point: (cone, graphite point, body, cap) polygons."""
    import math
    dx, dy = toward[0] - tip[0], toward[1] - tip[1]
    n = math.hypot(dx, dy)
    ux, uy = dx / n, dy / n
    px, py = -uy, ux
    hw = width / 2

    def at(t, side):
        return (tip[0] + ux * t + px * side, tip[1] + uy * t + py * side)

    cone_len = width * 1.25
    cone = [at(0, 0), at(cone_len, hw), at(cone_len, -hw)]
    lead = [at(0, 0), at(cone_len * 0.38, hw * 0.38), at(cone_len * 0.38, -hw * 0.38)]
    body = [at(cone_len, hw), at(length - width * 0.6, hw), at(length - width * 0.6, -hw), at(cone_len, -hw)]
    cap = [at(length - width * 0.6, hw), at(length, hw), at(length, -hw), at(length - width * 0.6, -hw)]
    return cone, lead, body, cap


def scaled(points, k):
    return [(x * k, y * k) for x, y in points]


def mod_icon(size=512):
    k = SS * size / 512
    img = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def box(r, **kw):
        d.rounded_rectangle([v * k for v in r[:4]], radius=r[4] * k, **{a: (int(b * k) if a == "width" else b) for a, b in kw.items()})

    box((0, 0, 512, 512, 64), fill=(30, 40, 22, 255), outline=(77, 107, 37, 255), width=8)
    # Clipboard
    box((92, 62, 404, 470, 30), fill=(150, 102, 58, 255), outline=(112, 74, 40, 255), width=8)
    d.rectangle(scaled([(124, 112), (372, 440)], k), fill=(244, 241, 230, 255))
    # Rows: check boxes and lines
    for i, y in enumerate((150, 220, 290, 360)):
        done = i < 2
        d.rectangle(scaled([(150, y), (184, y + 34)], k), outline=(95, 95, 95, 255), width=int(5 * k))
        if done:
            d.line(scaled([(154, y + 16), (166, y + 30), (192, y - 6)], k), fill=GREEN + (255,), width=int(9 * k), joint="curve")
        end = (340, 310, 330, 290)[i]
        d.rectangle(scaled([(204, y + 11), (end, y + 23)], k), fill=(185, 185, 185, 255) if done else (120, 120, 120, 255))
    # Clip
    box((180, 34, 316, 108, 20), fill=(196, 202, 206, 255), outline=(118, 124, 130, 255), width=6)
    box((222, 50, 274, 72, 10), fill=(110, 116, 122, 255))
    # Pen, with a soft shadow
    cone, lead, body, cap = pen_polygons((292, 410), (470, 190), 270, 50)
    shade = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    for poly in (cone, body, cap):
        sd.polygon(scaled([(x + 10, y + 12) for x, y in poly], k), fill=(0, 0, 0, 80))
    img.alpha_composite(shade)
    d = ImageDraw.Draw(img)
    d.polygon(scaled(body, k), fill=GREEN + (255,), outline=(90, 130, 40, 255), width=int(4 * k))
    d.polygon(scaled(cap, k), fill=(70, 100, 32, 255))
    d.polygon(scaled(cone, k), fill=(232, 200, 150, 255))
    d.polygon(scaled(lead, k), fill=(45, 45, 45, 255))
    img = img.resize((size, size), Image.LANCZOS)
    # Opaque icon: put it on the background colour (corners included)
    bg = Image.new("RGBA", (size, size), (20, 26, 15, 255))
    return Image.alpha_composite(bg, img)


def tab_icon(size=256):
    k = SS * size / 256
    img = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)
    clear = (0, 0, 0, 0)
    d.rounded_rectangle([v * k for v in (44, 34, 192, 234)], radius=18 * k, outline=white, width=int(16 * k))
    for y, end in ((92, 160), (128, 148), (164, 130)):
        d.rectangle(scaled([(76, y), (end, y + 14)], k), fill=white)
    # Clip: a gap in the outline, then the clip itself
    d.rounded_rectangle([v * k for v in (78, 14, 158, 62)], radius=12 * k, fill=clear)
    d.rounded_rectangle([v * k for v in (88, 20, 148, 56)], radius=10 * k, fill=white)
    # Pen over the corner, cut free from the board by a transparent edge
    cone, lead, body, cap = pen_polygons((150, 214), (246, 92), 150, 30)
    cone2, _, body2, cap2 = pen_polygons((142, 224), (246, 92), 168, 52)
    for poly in (cone2, body2, cap2):
        d.polygon(scaled(poly, k), fill=clear)
    for poly in (cone, body, cap):
        d.polygon(scaled(poly, k), fill=white)
    d.polygon(scaled(lead, k), fill=clear)
    return img.resize((size, size), Image.LANCZOS)


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
