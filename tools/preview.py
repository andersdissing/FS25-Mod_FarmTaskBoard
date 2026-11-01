"""Renders the task board as the stubbed game would draw it, to PNG files in Docs/preview/.
Only rectangles and text (approximate font), but enough to check the layout without the game.

Usage: python tools/preview.py       Needs: pip install lupa pillow
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests"))
import smoke_test as st  # noqa: E402

OUT = os.path.join(st.ROOT, "Docs", "preview")
W, H = 1920, 1080

RECORD = r"""
DRAWS = {}
local rect, text = drawFilledRect, renderText
local color, bold, align = { 1, 1, 1, 1 }, false, 0
function drawFilledRect(x, y, w, h, r, g, b, a) rect(x, y, w, h, r, g, b, a) table.insert(DRAWS, { "r", x, y, w, h, r, g, b, a }) end
function setTextColor(r, g, b, a) color = { r, g, b, a } end
function setTextBold(v) bold = v end
function setTextAlignment(v) align = v end
function renderText(x, y, size, s) text(x, y, size, s) table.insert(DRAWS, { "t", x, y, size, s, color[1], color[2], color[3], color[4], bold, align }) end
"""


def font(size, bold):
    for name in (("segoeuib.ttf" if bold else "segoeui.ttf"), "arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def render(lua, path):
    lua.execute("DRAWS = {} frameStep(0)")
    img = Image.new("RGB", (W, H), (38, 45, 28))
    over = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for d in lua.eval("DRAWS").values():
        d = list(d.values())
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        g = ImageDraw.Draw(layer)
        if d[0] == "r":
            _, x, y, w, h, r, gg, b, a = d
            x0, y0 = x * W, (1 - y - h) * H
            g.rectangle([x0, y0, max(x0, (x + w) * W - 1), max(y0, (1 - y) * H - 1)], fill=(int(r * 255), int(gg * 255), int(b * 255), int(a * 255)))
        else:
            _, x, y, size, s, r, gg, b, a, bold, align = d
            f = font(max(6, int(size * H * 0.95)), bold)
            tw = g.textlength(s, font=f)
            px = x * W - (tw / 2 if align == 1 else tw if align == 2 else 0)
            g.text((px, (1 - y) * H), s, font=f, fill=(int(r * 255), int(gg * 255), int(b * 255), int(a * 255)), anchor="ls")
        over = Image.alpha_composite(over, layer)
    img = Image.alpha_composite(img.convert("RGBA"), over).convert("RGB")
    img.save(path)
    print("wrote", path)


def main():
    os.makedirs(OUT, exist_ok=True)
    lua = st.make_runtime(True, False, 1, 1)
    lua.execute(RECORD)
    for text, status in [("Kalk mark 23+25 før vintersæd", 0), ("Køb 4.000 l frø til canola, mark 76/77", 0), ("Lever byg til Grain Mill", 0),
                         ("Pløj mark 6+7", 1), ("Høst havre mark 8", 1), ("Slå græs mark 3,4,5", 1),
                         ("Så hvede mark 3,4,5", 2), ("Lever canola til Oil Mill", 2), ("Gød mark 23+25 " + "og meget mere tekst " * 8, 2)]:
        lua.execute(f"newTask({text!r}, {status})")
    render(lua, os.path.join(OUT, "board.png"))
    lua.execute("local c = column(1) dragTo(3, c.x + c.w / 2, c.listTop - 60 / 1080, false)")
    render(lua, os.path.join(OUT, "drag.png"))
    lua.execute("F():requestClose() for _ = 1, 20 do frameStep(20) end")
    lua.execute("clickHit('edit:5') F().taskTextInput:setText('Høst havre mark 8')")
    render(lua, os.path.join(OUT, "dialog.png"))
    lua.execute("clickHit('delete')")
    render(lua, os.path.join(OUT, "delete.png"))
    member = st.make_runtime(True, True, 2, 4)
    member.execute(RECORD)
    member.execute("FarmTaskBoardData.createTask(board(), 'Pløj mark 6+7', 1) FarmTaskBoardData.createTask(board(), 'Lever byg', 0)")
    render(member, os.path.join(OUT, "member.png"))


if __name__ == "__main__":
    main()
