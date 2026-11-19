#!/usr/bin/env python3
"""Generates the stock floor-tile textures (the courtyard floor).

  tiles_light_4x4.png  512x512 RGB   pale stone/ceramic tiles
  tiles_wet_4x4.png    512x512 RGBA  the same floor, wet: darker slate with a
                                     glossy sheen (alpha is a constant 255 --
                                     the file has always been RGBA, and the
                                     exporter/alpha detector see it as opaque)

Layout contract (scenes' UV tiling depends on it): a 4x4 grid of 128 px
tiles whose grout straddles every multiple of 128 px, 2 px on each side
(so x/y in {0,1,126,127} of each cell are grout, and the image edges carry
half a grout line each -- the texture tiles seamlessly).

Each tile gets its own tone, a slight random tilt of its shading, a bevel lit
from the top-left and soft surface mottling. tiles_wet keeps the
same tiles (same seed) under a darker slate tint with damp patches and
specular sheen, and stays mid-toned so painted splat layers read on top of it.

Retro notes: the PSP ships opaque art as RGBA5551 (5 bits per channel, steps
of 8), so the surface noise is broad and gentle rather than per-pixel grain
(which would only turn into 5551 dither, and would also triple the PNG size).

Usage: python3 retro_engine/gen_tile_textures.py [--out DIR]
Writes into project/addons/poibuilder/materials/textures/ by default.
"""
import argparse
import os

import numpy as np

from PIL import Image

from texgen_noise import blur, mix, pnoise, smoothstep, to_u8

SIZE = 512
CELLS = 4
CELL = SIZE // CELLS
GROUT_HALF = 2          # px of grout on each side of a tile boundary
BEVEL = 7.0             # px of rounded edge inside the grout


def _tile_fields(seed=5):
    """Geometry + noise shared by both variants (so wet == light, just wet)."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float64)
    # Position inside the tile, measured from the grout's inner edge.
    lx = (xx % CELL) - GROUT_HALF + 0.5
    ly = (yy % CELL) - GROUT_HALF + 0.5
    inner = CELL - 2 * GROUT_HALF
    rx = inner - lx
    ry = inner - ly
    tile_ix = (xx // CELL).astype(int)
    tile_iy = (yy // CELL).astype(int)
    d_edge = np.minimum(np.minimum(lx, rx), np.minimum(ly, ry))
    grout = smoothstep(0.6, -0.4, d_edge)                  # 1 in the grout

    # Bevel: a rounded profile; its slope is lit from the top-left.
    def prof(d):
        return 1.0 - smoothstep(0.0, BEVEL, d)
    light = (prof(lx) + prof(ly)) * 0.5 - (prof(rx) + prof(ry)) * 0.5
    rim = np.maximum(np.maximum(prof(lx), prof(rx)), np.maximum(prof(ly), prof(ry)))

    # Per-tile tone and a gentle shading tilt (hand-laid, not perfectly flat).
    tone_tab = rng.normal(0.0, 1.0, (CELLS, CELLS))
    tilt_tab = rng.normal(0.0, 1.0, (CELLS, CELLS, 2))
    hue_tab = rng.normal(0.0, 1.0, (CELLS, CELLS))
    tone = tone_tab[tile_iy, tile_ix]
    tone2 = rng.normal(0.0, 1.0, (CELLS, CELLS))[tile_iy, tile_ix]
    hue = hue_tab[tile_iy, tile_ix]
    u = lx / inner - 0.5
    v = ly / inner - 0.5
    tilt = tilt_tab[tile_iy, tile_ix, 0] * u + tilt_tab[tile_iy, tile_ix, 1] * v

    mottle = pnoise(SIZE, SIZE, rng, 14, 14)
    cloud = pnoise(SIZE, SIZE, rng, 40, 40)
    grout_n = pnoise(SIZE, SIZE, rng, 2.0, 2.0)
    sheen = pnoise(SIZE, SIZE, rng, 34, 22)
    damp = pnoise(SIZE, SIZE, rng, 26, 26)
    # Integer-frequency diagonal (2 cycles across the image): seamless.
    diag = 2.0 * np.pi * 2.0 * (xx + yy) / SIZE
    return dict(tone2=tone2, diag=diag, grout=grout, light=light, rim=rim, tone=tone, hue=hue, tilt=tilt,
                mottle=mottle, cloud=cloud, grout_n=grout_n,
                sheen=sheen, damp=damp, d_edge=d_edge)


def make_tiles_light(f):
    base = np.array([204.0, 205.0, 201.0])
    # Per-tile tone: a few warm/cool shades of the same stone.
    rgb = base + f["tone"][..., None] * 7.0
    rgb = rgb + f["hue"][..., None] * np.array([3.0, 0.5, -3.0])
    rgb = rgb + f["tilt"][..., None] * 6.0
    rgb = rgb + f["mottle"][..., None] * 2.5 + f["cloud"][..., None] * 2.0
    # Bevel: highlight on the top/left edges, shade on the bottom/right.
    rgb = rgb + f["light"][..., None] * 30.0 - f["rim"][..., None] * 6.0
    grout = np.array([146.0, 144.0, 138.0]) + f["grout_n"][..., None] * 4.0
    rgb = mix(rgb, grout, f["grout"])
    return Image.fromarray(to_u8(np.clip(rgb, 0, 238)), "RGB")


def make_tiles_wet(f):
    base = np.array([100.0, 116.0, 130.0])
    rgb = base + f["tone"][..., None] * 6.0
    rgb = rgb + f["hue"][..., None] * np.array([-1.5, 0.5, 2.0])
    rgb = rgb + f["mottle"][..., None] * 2.5
    # Damp patches: soaked stone reads a little darker and bluer.
    damp = smoothstep(0.4, 1.6, f["damp"])
    rgb = mix(rgb, rgb * np.array([0.84, 0.88, 0.93]), damp * 0.7)
    # Gloss: each tile is a slightly tilted mirror, so it carries a smooth
    # reflection gradient (its own tilt) and a soft diagonal sky streak that
    # runs across the whole floor.
    gloss = np.clip(0.5 + 0.35 * f["tilt"], 0, 1)
    rgb = mix(rgb, np.array([150.0, 170.0, 186.0]), gloss * 0.35)
    streak = smoothstep(0.35, 1.0, np.sin(f["diag"] + 0.5 * f["sheen"]) * 0.5 + 0.5)
    streak = streak * np.clip(0.55 + 0.3 * f["tone2"], 0.15, 1.0)   # glossier tiles
    rgb = mix(rgb, np.array([176.0, 194.0, 208.0]), streak * 0.28)
    glint = np.clip(f["light"], 0, 1)
    rgb = rgb + glint[..., None] * (30.0 + 24.0 * streak[..., None])
    rgb = rgb - np.clip(-f["light"], 0, 1)[..., None] * 20.0
    # Grout holds water: dark, cool.
    grout = np.array([52.0, 62.0, 72.0]) + f["grout_n"][..., None] * 3.0
    rgb = mix(rgb, grout, f["grout"])
    rgb = np.clip(rgb, 0, 228)
    alpha = np.full(rgb.shape[:2], 255.0)
    return Image.fromarray(np.dstack([to_u8(rgb), to_u8(alpha)]), "RGBA")


def main():
    ap = argparse.ArgumentParser()
    default_out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "..", "project", "addons", "poibuilder",
                               "materials", "textures")
    ap.add_argument("--out", default=os.path.normpath(default_out))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    fields = _tile_fields()
    for name, img in (("tiles_light_4x4.png", make_tiles_light(fields)),
                      ("tiles_wet_4x4.png", make_tiles_wet(fields))):
        path = os.path.join(args.out, name)
        img.save(path, optimize=True)
        print(f"{path}: {img.width}x{img.height} {img.mode} ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    main()
