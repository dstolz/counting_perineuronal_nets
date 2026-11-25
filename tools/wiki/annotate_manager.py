"""Draw the numbered markers on the Dataset Manager picture of the user wiki, and put the wiki's
three Dataset Manager pictures in place.

    python tools/wiki/annotate_manager.py <screens folder> <wiki clone>/images

<screens folder> is what tests\\tWikiScreens.m wrote (WIKI_SCREENS_OUT): manager_annotated_raw.png,
manager_annotated.json (the marker centers, derived in MATLAB from the components' positions, in
pixels from the top left of the figure's drawing area), manager_curated.png, manager_database.png.

Written to the images folder: manager_annotated.png (the raw picture with markers 1-8: a filled
pink circle with a white rim and a white bold digit, the style of the wiki's other annotated
pictures), manager_curated.png and manager_database.png (copied as they are).

Needs Pillow. Nothing is committed or pushed: look at the pictures, then do that yourself.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

PINK = (214, 51, 108)
WHITE = (255, 255, 255)
RIM = 2.0          # white rim around the circle, in figure pixels
SUPER = 4          # markers are drawn at this multiple and scaled down, for smooth edges


def font(size):
    for name in ("arialbd.ttf", "segoeuib.ttf", "DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def marker(radius, digit):
    """One marker as an RGBA image (already scaled down), and its half size."""
    half = radius + RIM
    side = int(round(2 * half * SUPER))
    im = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse((0, 0, side - 1, side - 1), fill=WHITE + (255,))
    r = RIM * SUPER
    d.ellipse((r, r, side - 1 - r, side - 1 - r), fill=PINK + (255,))
    f = font(int(round(radius * 1.2 * SUPER)))
    d.text((side / 2, side / 2), str(digit), fill=WHITE + (255,), font=f, anchor="mm")
    out = int(round(2 * half))
    return im.resize((out, out), Image.LANCZOS)


def annotate(raw, spec, out):
    im = Image.open(raw).convert("RGBA")
    fig_w, fig_h = spec["figure"]
    sx, sy = im.width / fig_w, im.height / fig_h
    radius = spec["radius"] * (sx + sy) / 2
    for m in spec["markers"]:
        mk = marker(radius, m["n"])
        x = int(round(m["x"] * sx - mk.width / 2))
        y = int(round(m["y"] * sy - mk.height / 2))
        im.alpha_composite(mk, (x, y))
        print(f"  marker {m['n']} at ({m['x'] * sx:.0f}, {m['y'] * sy:.0f}): {m['what']}")
    im.convert("RGB").save(out, optimize=True)
    print(f"{out}  ({im.width} x {im.height})")


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    src, dst = Path(argv[1]), Path(argv[2])
    if not dst.is_dir():
        print(f"not a folder: {dst}")
        return 2
    spec = json.loads((src / "manager_annotated.json").read_text(encoding="utf-8"))
    annotate(src / "manager_annotated_raw.png", spec, dst / "manager_annotated.png")
    for name in ("manager_curated.png", "manager_database.png"):
        Image.open(src / name).convert("RGB").save(dst / name, optimize=True)
        print(dst / name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
