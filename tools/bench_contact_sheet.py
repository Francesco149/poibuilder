#!/usr/bin/env python3
"""Assemble the frame bench's visual-parity shots into contact sheets.

The bench (frame_pacing_bench.gd) photographs fixed poses of every variant
(pb / retro_glb / modern_glb, plus the ablation profile scenes) in every
renderer. This tool grids them — variants in rows, poses in columns, one
sheet per renderer — so a lighting regression is SEEN next to its siblings:

    python3 tools/bench_contact_sheet.py            # sheet per renderer
    python3 tools/bench_contact_sheet.md --open     # (no --open; just print)

Reads  project/exports/bench/shots/<renderer>_<variant>_<pose>.png
Writes project/exports/bench/sheet_<renderer>.png (+ .md index of the rows)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SHOTS = ROOT / "project" / "exports" / "bench" / "shots"

VARIANT_ORDER = ["pb", "retro_glb", "modern_glb"]
POSE_ORDER = ["plaza", "waterfall", "doorway", "neon", "roof"]
LABEL_H = 28
CELL_W = 640  # shots are 1280x720; downscale to keep the sheet readable


def collect() -> dict[str, dict[tuple[str, str], Path]]:
    """renderer -> (variant, pose) -> png path, from the shot file names."""
    grid: dict[str, dict[tuple[str, str], Path]] = {}
    rx = re.compile(r"^(?P<renderer>[^_]+)_(?P<variant>.+)_(?P<pose>plaza|waterfall|doorway|neon|roof)\.png$")
    for f in sorted(SHOTS.glob("*.png")):
        m = rx.match(f.name)
        if not m:
            continue
        grid.setdefault(m["renderer"], {})[(m["variant"], m["pose"])] = f
    return grid


def sheet_for(renderer: str, cells: dict[tuple[str, str], Path]) -> Path | None:
    variants = [v for v in VARIANT_ORDER if any((v, p) in cells for p in POSE_ORDER)]
    ablations = sorted({v for (v, _) in cells if v.startswith("ablation_")})
    rows = variants + ablations
    if not rows:
        return None
    cols = [p for p in POSE_ORDER if any((v, p) in cells for v in rows)]
    if not cols:
        return None
    # ablation rows only shoot the poses they have
    first = cells[(rows[0], cols[0])]
    with Image.open(first) as im:
        cell_h = int(im.height * CELL_W / im.width)
    W = CELL_W * len(cols)
    H = (LABEL_H + cell_h) * len(rows) + LABEL_H
    sheet = Image.new("RGB", (W, H), (18, 18, 22))
    d = ImageDraw.Draw(sheet)
    for ci, pose in enumerate(cols):
        d.text((ci * CELL_W + 8, 7), pose, fill=(235, 235, 235))
    for ri, variant in enumerate(rows):
        y = LABEL_H + ri * (LABEL_H + cell_h)
        d.text((8, y + 7), variant, fill=(120, 220, 255) if variant in VARIANT_ORDER else (255, 200, 120))
        for pose in cols:
            cell = cells.get((variant, pose))
            if cell is None:
                continue
            with Image.open(cell) as im:
                im = im.convert("RGB").resize((CELL_W, cell_h))
                sheet.paste(im, (cols.index(pose) * CELL_W, y + LABEL_H))
    out = SHOTS.parent / f"sheet_{renderer}.png"
    sheet.save(out)
    print(f"{out}  ({len(rows)} rows x {len(cols)} cols)")
    return out


def main() -> int:
    if not SHOTS.is_dir():
        print(f"no shots dir: {SHOTS} — run ./run_bench.sh first", file=sys.stderr)
        return 1
    grid = collect()
    if not grid:
        print("no bench shots matched", file=sys.stderr)
        return 1
    made = [sheet_for(r, cells) for r, cells in sorted(grid.items())]
    return 0 if any(made) else 1


if __name__ == "__main__":
    raise SystemExit(main())
