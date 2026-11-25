"""Draw the numbered markers on the Cell Analysis picture of the user wiki, and put the wiki's
Cell Analysis pictures in place.

    python tools/wiki/annotate_analysis.py <screens folder> <wiki clone>/images

<screens folder> is what tests\tWikiScreens.m wrote (WIKI_SCREENS_OUT): analysis_annotated_raw.png
and analysis_annotated.json (the marker centers, derived in MATLAB from the components' positions),
and the other analysis_<name>.png pictures.

Written to the images folder: analysis_annotated.png (the raw picture with markers 1-10, the style
of annotate_manager.py) and the other analysis_*.png pictures (copied as they are, minus the ones
named in SKIP). Needs Pillow. Nothing is committed or pushed.
"""
import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from annotate_manager import annotate  # noqa: E402

SKIP = set()   # picture names (without analysis_ and .png) that are not copied


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    src, dst = Path(argv[1]), Path(argv[2])
    if not dst.is_dir():
        print(f"not a folder: {dst}")
        return 2
    spec = json.loads((src / "analysis_annotated.json").read_text(encoding="utf-8"))
    annotate(src / "analysis_annotated_raw.png", spec, dst / "analysis_annotated.png")
    for f in sorted(src.glob("analysis_*.png")):
        name = f.stem[len("analysis_"):]
        if name in SKIP or name.startswith("annotated"):
            continue
        Image.open(f).convert("RGB").save(dst / f.name, optimize=True)
        print(dst / f.name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
