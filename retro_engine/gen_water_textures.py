#!/usr/bin/env python3
"""Generates the seamless water textures the courtyard waterfall demo uses.

  waterfall_sheet.png  128x256  the falling curtain: long vertical streaks with
                                thin specular runnels and clumps of white water
                                over a mostly-opaque body (soft alpha, no holes)
  waterfall_core.png    64x128  the fast inner stream: brighter, foamier, with a
                                ragged soft edge fading out at both sides
  water_pool.png       128x128  translucent pool: deep teal body with a
                                domain-warped two-scale caustic web
  water_foam.png       128x64   foam lace: bubble-cell outlines gathered into
                                drifting patches over open (transparent) water
  water_spray.png       64x64   soft mist puffs for the impact billboard

Everything a scrolling texture needs is a tile that WRAPS: the visible motion
comes from shifting the texture coordinates, so a seam along the scroll axis
repeats once per cycle and reads immediately as a bug. Every field below comes
from `texgen_noise` (FFT-filtered noise, wraparound warps, torus Voronoi), so
the outputs are seamless in both axes by construction, not by edge blending.

Retro notes: all outputs are power-of-two RGBA8888 with genuinely soft alpha
(the exporter ships them RGBA8888 and blends them). Feature sizes are kept at
>= ~2 px so the PSP's mip chain does not turn them to shimmer.

Usage: python3 retro_engine/gen_water_textures.py [--out DIR]
Writes into project/addons/poibuilder/materials/textures/ by default.
"""
import argparse
import os
import random

import numpy as np

from PIL import Image, ImageDraw, ImageFilter

from texgen_noise import blur, mix, pnoise, smoothstep, to_u8, voronoi, warp

# One palette for the whole water family so the textures read as one material
# under the baked courtyard lighting.
DEEP = (22, 64, 96)
BODY = (44, 116, 160)
MID = (92, 166, 200)
BRIGHT = (186, 230, 246)
FOAM = (238, 250, 255)


def _rgba(rgb, alpha):
    return Image.fromarray(np.dstack([to_u8(rgb), to_u8(alpha)]), "RGBA")


def make_waterfall_sheet(width=128, height=256, seed=7):
    """Falling water curtain: streaky body, specular runnels, white-water clumps."""
    rng = np.random.default_rng(seed)
    h, w = height, width
    # Gentle sideways meander so the streaks are not ruler-straight.
    meander = pnoise(h, w, rng, 48, 40) * 2.0
    broad = warp(pnoise(h, w, rng, 36, 5.5), meander, 0)    # sheet thickness
    fine = warp(pnoise(h, w, rng, 16, 2.0), meander, 0)     # streak detail
    runnel = warp(pnoise(h, w, rng, 80, 6.5), meander, 0)   # specular lines
    clump = warp(pnoise(h, w, rng, 16, 4.0), meander, 0)    # white water

    t = np.clip(0.55 + 0.20 * broad + 0.12 * fine, 0, 1)
    rgb = mix(DEEP, BODY, smoothstep(0.05, 0.55, t))
    rgb = mix(rgb, MID, smoothstep(0.50, 0.95, t))

    # Bright runnels: the ridge (zero crossing) of a streak field, kept >= 2 px.
    ridge = 1.0 - np.abs(runnel)
    hl = smoothstep(0.72, 0.96, ridge) * smoothstep(-0.9, 0.5, broad)
    hl *= smoothstep(-0.4, 0.8, pnoise(h, w, rng, 18, 6))   # broken into dashes
    rgb = mix(rgb, BRIGHT, hl * 0.8)

    # White water: long vertical smears where the sheet is thick.
    foam_f = clump + 0.45 * fine + 0.35 * broad
    foam = blur(smoothstep(1.0, 1.9, foam_f), 4.0, 0.7)
    rgb = mix(rgb, FOAM, np.clip(foam * 1.3, 0, 0.9))

    # Mostly opaque body; thin parts of the sheet go translucent, never holes.
    alpha = 205 + 36 * broad + 12 * fine + hl * 45 + foam * 90
    return _rgba(rgb, np.clip(alpha, 125, 255))


def make_waterfall_core(width=64, height=128, seed=19):
    """Fast inner stream: bright, foamy, with a ragged soft edge at both sides."""
    rng = np.random.default_rng(seed)
    h, w = height, width
    meander = pnoise(h, w, rng, 28, 24) * 1.5
    broad = warp(pnoise(h, w, rng, 22, 3.5), meander, 0)
    fine = warp(pnoise(h, w, rng, 12, 1.8), meander, 0)
    runnel = warp(pnoise(h, w, rng, 48, 3.5), meander, 0)
    clump = warp(pnoise(h, w, rng, 10, 3.0), meander, 0)

    t = np.clip(0.55 + 0.2 * broad + 0.14 * fine, 0, 1)
    rgb = mix(BODY, MID, smoothstep(0.15, 0.75, t))
    rgb = mix(rgb, BRIGHT, smoothstep(0.65, 1.0, t) * 0.8)
    hl = smoothstep(0.78, 0.96, 1.0 - np.abs(runnel))
    rgb = mix(rgb, FOAM, hl * 0.75)
    foam = blur(smoothstep(0.8, 1.7, clump + 0.5 * fine), 3.0, 0.6)
    rgb = mix(rgb, FOAM, np.clip(foam * 1.3, 0, 0.95))

    # Column envelope: 1 in the middle, 0 at both x edges (so the X wrap is
    # seamless too), with the edge position wobbling down the stream.
    xx = (np.arange(w) + 0.5) / w
    dist = np.abs(xx - 0.5)[None, :] * 2.0               # 0 centre .. 1 edge
    edge = 0.82 + 0.09 * pnoise(h, w, rng, 12, 6)
    env = 1.0 - smoothstep(edge - 0.45, edge, dist)
    alpha = (205 + 30 * broad + hl * 40 + foam * 60) * env
    return _rgba(rgb, np.clip(alpha, 0, 255))


def make_water_pool(width=128, height=128, seed=23):
    """Pool water: translucent teal body with a warped two-scale caustic web."""
    rng = np.random.default_rng(seed)
    h, w = height, width
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)

    def web(count, width_px, amp, sigma):
        wx = pnoise(h, w, rng, sigma, sigma) * amp
        wy = pnoise(h, w, rng, sigma, sigma) * amp
        f1, f2 = voronoi(h, w, rng, count, xx + wx, yy + wy)
        return 1.0 - smoothstep(0.0, width_px, f2 - f1)

    # Two offset webs: where their lines cross, the caustic knots brighten.
    web_a = web(10, 4.2, 7.0, 14)
    web_b = web(18, 2.6, 5.0, 10)
    caustic = blur(np.clip(web_a + web_b * 0.35, 0, 1.2), 0.8)

    depth = pnoise(h, w, rng, 22, 22)
    rgb = mix(DEEP, BODY, 0.35 + 0.5 * smoothstep(-2.0, 2.0, depth))
    glow = smoothstep(0.05, 0.9, caustic)
    rgb = mix(rgb, BRIGHT, glow * 0.92)
    alpha = 172 + 12 * depth + 58 * glow
    return _rgba(rgb, np.clip(alpha, 130, 240))


def make_water_foam(width=128, height=64, seed=31):
    """Foam: round bubbles packed into drifting patches that thin out to lace.

    Bubbles are torus-Voronoi cells; foam is the space BETWEEN them. The cut
    threshold on F1/F2 (0 at a cell centre, 1 on its border) follows a patch
    noise, so a dense patch is nearly solid white with small holes, its rim is
    a thin lace of bubble outlines, and open water is left transparent."""
    rng = np.random.default_rng(seed)
    h, w = height, width
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    wx = pnoise(h, w, rng, 8, 8) * 1.5
    wy = pnoise(h, w, rng, 8, 8) * 1.5
    f1, f2 = voronoi(h, w, rng, 90, xx + wx, yy + wy)
    ratio = f1 / np.maximum(f2, 1e-6)
    f1s, f2s = voronoi(h, w, rng, 260, xx - wy, yy + wx)
    ratio_s = f1s / np.maximum(f2s, 1e-6)

    patch = pnoise(h, w, rng, 7, 10)
    dense = smoothstep(-1.6, 2.2, patch)                    # 0 open .. 1 packed
    cut = 0.95 - 0.6 * dense                               # high: thin lace
    big = smoothstep(cut - 0.06, cut + 0.03, ratio)
    small = smoothstep(cut - 0.06, cut + 0.04, ratio_s) * smoothstep(0.5, 0.85, dense)
    cover = np.maximum(big, small * 0.8) * smoothstep(0.03, 0.2, dense)
    cover = blur(cover, 0.6)

    shade = smoothstep(0.2, 0.9, cover) * (0.75 + 0.25 * dense)
    rgb = mix(MID, FOAM, shade)
    alpha = 240 * smoothstep(0.03, 0.75, cover) + 22 * smoothstep(-0.9, 0.2, patch)
    return _rgba(rgb, np.clip(alpha, 0, 245))


def make_water_spray(width=64, height=64, seed=41):
    """Alpha-cutout mist for the impact point (drawn as a billboard)."""
    rng = random.Random(seed)
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    def blob(cx, cy, r, alpha):
        for dx in (-width, 0, width):
            for dy in (-height, 0, height):
                for r_step, a_scale in ((1.0, 1.0), (1.6, 0.45), (2.3, 0.15)):
                    rr = r * r_step
                    draw.ellipse([cx + dx - rr, cy + dy - rr, cx + dx + rr, cy + dy + rr],
                                 fill=(FOAM[0], FOAM[1], FOAM[2], int(alpha * a_scale)))

    for _ in range(26):
        blob(rng.uniform(6, width - 6), rng.uniform(6, height - 6),
             rng.uniform(3.0, 9.0), rng.uniform(40, 120))
    img = img.filter(ImageFilter.GaussianBlur(1.6))

    # Fade the sprite's border to zero alpha so the cutout has no hard edge.
    pix = img.load()
    for y in range(height):
        for x in range(width):
            r, g, b, a = pix[x, y]
            # Torus distance to the border keeps the falloff seamless too.
            dx = min(x, width - x) / (width * 0.5)
            dy = min(y, height - y) / (height * 0.5)
            edge = min(1.0, min(dx, dy) * 3.0)
            pix[x, y] = (r, g, b, int(a * edge))
    return img


def main():
    ap = argparse.ArgumentParser()
    default_out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "..", "project", "addons", "poibuilder",
                               "materials", "textures")
    ap.add_argument("--out", default=os.path.normpath(default_out))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    # The floor tiles (tiles_light/tiles_wet) live in gen_tile_textures.py.
    textures = {
        "waterfall_sheet.png": make_waterfall_sheet(),
        "waterfall_core.png": make_waterfall_core(),
        "water_pool.png": make_water_pool(),
        "water_foam.png": make_water_foam(),
        "water_spray.png": make_water_spray(),
    }
    for name, img in textures.items():
        path = os.path.join(args.out, name)
        img.convert("RGBA").save(path)
        print(f"{path}: {img.width}x{img.height} ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    main()
