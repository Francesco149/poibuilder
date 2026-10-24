#!/usr/bin/env python3
"""Compose the bake-boost comparison shots (project/test_scenes/bake_boost_shots.gd).

    python3 tools/boost_contact.py                 # review sheet of every shot
    python3 tools/boost_contact.py --docs brazier  # the Export page's figures

Reads  project/exports/boost_shots/<preset>_<pose>_<mode>.png
       (mode: b1 = boost 1, b2 = boost 2, hw2x = hardware modulate-2x)
Writes project/exports/boost_shots/sheet.png (review), or with --docs
       docs/site/assets/export-boost-dusk.png and export-boost-day.png
       (committed doc assets: see rule 4 in .pi/ORIENTATION.md).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SHOTS = ROOT / "project" / "exports" / "boost_shots"
ASSETS = ROOT / "docs" / "site" / "assets"
FONT = "/usr/share/fonts/noto/NotoSans-Bold.ttf"

MODES = ["b1", "b2", "hw2x"]
TITLES = {
    "b1": "Bake Boost 1 (default)",
    "b2": "Bake Boost 2",
    "hw2x": "Hardware modulate-2x (reference)",
}
# Which panels each docs figure shows: dusk is where the boost earns its keep,
# day is where its ceiling flattens the shading and parts from the hardware.
DOCS = {"dusk": ["b1", "b2"], "day": ["b1", "b2", "hw2x"]}


def font(size: int) -> ImageFont.ImageFont:
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default()


def collect() -> dict[tuple[str, str, str], Path]:
    rx = re.compile(r"^(?P<preset>[a-z]+)_(?P<pose>[a-z]+)_(?P<mode>b1|b2|hw2x)\.png$")
    out = {}
    for f in sorted(SHOTS.glob("*.png")):
        m = rx.match(f.name)
        if m:
            out[(m["preset"], m["pose"], m["mode"])] = f
    return out


def review_sheet(cells: dict) -> int:
    presets = sorted({k[0] for k in cells})
    poses = sorted({k[1] for k in cells})
    cw, label = 480, 24
    first = next(iter(cells.values()))
    with Image.open(first) as im:
        ch = int(im.height * cw / im.width)
    rows = [(p, m) for p in presets for m in MODES]
    sheet = Image.new("RGB", (cw * len(poses), (label + ch) * len(rows) + label), (18, 18, 22))
    d = ImageDraw.Draw(sheet)
    f = font(14)
    for ci, pose in enumerate(poses):
        d.text((ci * cw + 8, 4), pose, fill=(235, 235, 235), font=f)
    for ri, (preset, mode) in enumerate(rows):
        y = label + ri * (label + ch)
        d.text((8, y + 4), f"{preset} / {TITLES[mode]}", fill=(120, 220, 255), font=f)
        for ci, pose in enumerate(poses):
            p = cells.get((preset, pose, mode))
            if p:
                with Image.open(p) as im:
                    sheet.paste(im.convert("RGB").resize((cw, ch), Image.LANCZOS), (ci * cw, y + label))
    out = SHOTS / "sheet.png"
    sheet.save(out)
    print(out)
    return 0


def docs_figures(cells: dict, pose: str) -> int:
    for preset, modes in DOCS.items():
        paths = [cells.get((preset, pose, m)) for m in modes]
        if None in paths:
            print(f"missing shots for {preset}/{pose}: {modes}", file=sys.stderr)
            return 1
        # Panels at 960 px wide each: a 2-up figure is 1920 wide like the
        # other doc shots; a 3-up one 2880, which the page scales down.
        pw = 960
        with Image.open(paths[0]) as im:
            ph = int(im.height * pw / im.width)
        bar = 56
        fig = Image.new("RGB", (pw * len(modes) + 8 * (len(modes) - 1), ph + bar), (18, 18, 22))
        d = ImageDraw.Draw(fig)
        f = font(30)
        for i, (mode, p) in enumerate(zip(modes, paths)):
            x = i * (pw + 8)
            with Image.open(p) as im:
                fig.paste(im.convert("RGB").resize((pw, ph), Image.LANCZOS), (x, bar))
            d.text((x + 16, 10), TITLES[mode], fill=(240, 240, 240), font=f)
        out = ASSETS / f"export-boost-{preset}.png"
        fig.save(out, optimize=True)
        print(f"{out}  {fig.size[0]}x{fig.size[1]}  {out.stat().st_size // 1024} KB")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--docs", metavar="POSE", help="compose the docs figures from this pose")
    args = ap.parse_args()
    cells = collect()
    if not cells:
        print(f"no shots in {SHOTS} — run bake_boost_shots.gd first", file=sys.stderr)
        return 1
    return docs_figures(cells, args.docs) if args.docs else review_sheet(cells)


if __name__ == "__main__":
    sys.exit(main())
