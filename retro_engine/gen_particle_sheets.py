#!/usr/bin/env python3
"""Generates the shipped particle SPRITE SHEETS (flipbooks) for PoiBuilder.

The single-frame particle textures (`particle_flame/glow/smoke.png`) are one
cell; these are the same families laid out as a 4-column sheet, so the emitter
panel's Sheet Columns/Rows knobs have art that actually is a sheet:

  particle_flame_sheet.png   4 x 64x64 cells: a flame that licks and flickers
  particle_smoke_sheet.png   4 x 64x64 cells: a puff that swells and fades

Each cell is drawn procedurally (no source art) and written next to the other
shipped textures. Re-run after changing the recipe:

    python3 retro_engine/gen_particle_sheets.py
"""

import math
import os
import random

from PIL import Image, ImageFilter

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "project", "addons", "poibuilder", "materials", "textures")
CELL = 64
FRAMES = 4


def _radial(cx, cy, r, softness=1.0):
    """A 1.0-at-centre, 0.0-at-r falloff, per pixel (float)."""
    def f(x, y):
        d = math.hypot(x - cx, y - cy) / max(r, 0.001)
        if d >= 1.0:
            return 0.0
        return (1.0 - d) ** softness
    return f


def flame_cell(frame):
    """A soft, wispy flame that licks side to side; 4 frames = one loop."""
    img = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    px = img.load()
    phase = frame / FRAMES * math.tau
    lean = math.sin(phase) * 6.0
    tall = 1.0 + 0.16 * math.sin(phase + 0.6)
    pulse = 0.80 + 0.20 * math.sin(phase + 1.4)
    lick_t = 0.35 + 0.30 * math.sin(phase)     # where the flame bulges
    base_y = CELL * 0.98
    top_y = CELL * 0.10 / tall
    for y in range(CELL):
        t = (y - top_y) / max(base_y - top_y, 1.0)
        if t < 0.0 or t > 1.0:
            continue
        half_w = (1.2 + 15.0 * (t ** 1.25)) * (1.0 - 0.18 * (t ** 2.5))
        half_w *= 1.0 + 0.30 * math.exp(-(((t - lick_t) / 0.13) ** 2))
        cx = CELL * 0.5 + lean * ((1.0 - t) ** 1.5) + math.sin(t * 5.0 + phase) * 1.4
        # The tip thins out and the base feathers, so a floating particle never
        # shows a hard cut where the art ends.
        fade = min(1.0, 0.10 + t * 2.4) * (1.0 - max(0.0, (t - 0.80) / 0.20) ** 2)
        for x in range(CELL):
            d = abs(x - cx) / max(half_w, 0.6)
            if d >= 1.0:
                continue
            w = ((1.0 - d * d) ** 1.7) * (0.22 + 0.78 * t) * fade
            w += max(0.0, 1.0 - d * 2.4) ** 2 * max(0.0, t - 0.2) * 0.85
            heat = min(1.0, w * pulse * 1.2)
            if heat <= 0.02:
                continue
            r = int(min(255, 255 * min(1.0, heat * 1.3)))
            g = int(min(255, 200 * max(0.0, heat - 0.15) ** 0.85))
            b = int(min(255, 70 * max(0.0, heat - 0.6) ** 1.3))
            a = int(min(255, 255 * min(1.0, heat * 1.35)))
            px[x, y] = (r, g, b, a)
    return img.filter(ImageFilter.GaussianBlur(0.7))


def smoke_cell(frame):
    """A puff that swells and fades: the classic 4-frame smoke loop."""
    img = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    phase = frame / FRAMES
    radius = CELL * (0.26 + 0.16 * phase)
    alpha = 0.85 - 0.5 * phase
    swirl = math.sin(phase * math.tau) * 2.0
    puff = _radial(CELL * 0.5 + swirl, CELL * 0.5 - phase * 3.0, radius, 1.7)
    # A second, offset lobe keeps the silhouette from reading as a perfect disc.
    lobe = _radial(CELL * 0.38 - swirl, CELL * 0.44 + phase * 2.0, radius * 0.72, 1.4)
    px = img.load()
    for y in range(CELL):
        for x in range(CELL):
            w = min(1.0, puff(x, y) * 1.0 + lobe(x, y) * 0.7)
            if w <= 0.01:
                continue
            # A little grain so the puff does not band when it is stretched.
            grain = 0.94 + 0.06 * math.sin(x * 0.9 + y * 1.3 + frame)
            v = int(min(255, 255 * w * grain))
            a = int(min(255, 255 * w * alpha * grain))
            px[x, y] = (v, v, v, a)
    return img.filter(ImageFilter.GaussianBlur(0.6))


def build(name, cell_fn, tint):
    sheet = Image.new("RGBA", (CELL * FRAMES, CELL), (0, 0, 0, 0))
    for i in range(FRAMES):
        sheet.paste(cell_fn(i), (i * CELL, 0))
    if tint is not None:
        r, g, b = tint
        px = sheet.load()
        for y in range(CELL):
            for x in range(CELL * FRAMES):
                pr, pg, pb, pa = px[x, y]
                px[x, y] = (pr * r // 255, pg * g // 255, pb * b // 255, pa)
    path = os.path.join(OUT_DIR, name)
    sheet.save(path)
    print("wrote %s (%dx%d, %d frames)" % (path, sheet.width, sheet.height, FRAMES))


def main():
    random.seed(7)  # deterministic art
    build("particle_flame_sheet.png", flame_cell, None)
    build("particle_smoke_sheet.png", smoke_cell, (245, 245, 250))


if __name__ == "__main__":
    main()
