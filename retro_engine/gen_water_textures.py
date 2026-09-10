#!/usr/bin/env python3
"""Generates the seamless water textures the courtyard waterfall demo uses.

Everything a scrolling texture needs is a tile that WRAPS: the visible motion
comes from shifting the texture coordinates, so a seam along the scroll axis
repeats once per second and reads immediately as a bug. Every drawing routine
here therefore stamps with wraparound (a blob near an edge is drawn again on
the opposite side), and the pool ripples are built from integer-frequency
sinusoids, which are seamless on a torus by construction.

All outputs are power-of-two RGBA8888, which is what the retro exporters and
the PSP texture uploader want.

Usage: python3 retro_engine/gen_water_textures.py [--out DIR]
Writes into project/addons/poibuilder/materials/textures/ by default.
"""
import argparse
import math
import os
import random

import numpy as np

from PIL import Image, ImageDraw, ImageFilter

TAU = math.pi * 2  # kept explicit: every wobble frequency below is in radians

# Strength of the blue-white tint used by every water surface, so the four
# textures read as one material family under the baked courtyard lighting.
DEEP = (48, 92, 122)
MID = (96, 152, 186)
BRIGHT = (198, 232, 246)
FOAM = (238, 250, 255)


def _wrapped_blob(draw, x, y, w, h, fill, width, height):
    """Stamps a soft-ish rectangle/blob, repeated across every edge so the
    texture stays seamless in both axes."""
    for dx in (-width, 0, width):
        for dy in (-height, 0, height):
            draw.ellipse([x + dx - w / 2, y + dy - h / 2, x + dx + w / 2, y + dy + h / 2], fill=fill)


def _lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def _rope_field(width, height, seed, ropes):
    """Builds the two fields a falling-water sheet needs, both seamless in x
    and y:

      rope(x, y)  in [0,1]: how far inside a rivulet this texel is (1 = the
                  rope's core, 0 = the veil between ropes)
      value(x, y) in [0,1]: brightness along the rope, so a rope lightens and
                  darkens along its length instead of being a painted stripe

    Ropes are never straight: each one's centre wobbles with two wrapped
    sinusoids, and its strength surges along its length — which is what makes
    a scrolling sheet read as running water rather than a moving grid.
    """
    rng = random.Random(seed)
    rope_px = [[0.0] * height for _ in range(width)]
    val_px = [[0.0] * height for _ in range(width)]

    for r in ropes:
        cx, half = r["x"], r["w"]
        f1 = rng.uniform(0.4, 1.4) * TAU / height
        f2 = rng.uniform(1.6, 3.4) * TAU / height
        p1, p2 = rng.uniform(0, TAU), rng.uniform(0, TAU)
        amp = rng.uniform(0.10, 0.30) * half
        # A slow surge plus a faster "breaking" term: a rope thins to the veil
        # where the break term dips, which is what a rope of water does.
        fs, fb = rng.uniform(0.6, 1.2) * TAU / height, rng.uniform(2.0, 4.0) * TAU / height
        ps, pb = rng.uniform(0, TAU), rng.uniform(0, TAU)
        for y in range(height):
            cx_y = cx + amp * (math.sin(y * f1 + p1) + 0.5 * math.sin(y * f2 + p2))
            surge = 0.55 + 0.45 * math.sin(y * fs + ps)
            brk = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(y * fb + pb))
            strength = r["s"] * surge * brk
            for x in range(width):
                dx = x - cx_y
                if dx > width / 2: dx -= width
                elif dx < -width / 2: dx += width
                d = abs(dx) / half
                if d >= 1.0:
                    continue
                # Flat-topped profile: a rope has a body, not a gaussian ridge.
                prof = 1.0 if d < 0.55 else (1.0 - (d - 0.55) / 0.45)
                rr = prof * strength
                if rr > rope_px[x][y]:
                    rope_px[x][y] = rr
                    val_px[x][y] = min(1.0, 0.35 + 0.65 * strength)
    return rope_px, val_px


def rng_hl(spec, y):
    """Where the bright ridge sits inside a rope at a given height. Wobbling it
    along the length keeps the highlight from reading as a drawn line."""
    return spec["w"] * 0.35 * math.sin(y * 0.061 + spec["x"])


def _shift_diff(img, frac):
    """Mean absolute difference between a texture and itself shifted by `frac`
    of its height — i.e. how much the sheet visibly CHANGES when the engine
    advances the scroll by that amount.

    This is the number that matters for a scrolling texture: a pattern that is
    vertically uniform (straight unbroken ropes) scores near zero and reads as
    frozen no matter how correct the animation is, which is exactly how one
    shipping version of this sheet behaved.
    """
    a = np.asarray(img.convert("RGBA")).astype(float)
    b = np.roll(a, int(round(frac * a.shape[0])), axis=0)
    return float(np.abs(a - b).mean())


def make_waterfall_sheet(width=128, height=256, seed=7):
    """Falling water: a curtain of torrents, drawn after the pixel waterfall in
    cosmic2d's waterwall demo.

    Three things make it read as water rather than as moving dots:
      - few, LONG ropes spanning the tile, with real gaps between them where
        the alpha drops out and the wall shows through,
      - VARIATION ALONG each rope: it swells and pinches, brightens and dulls,
        so advancing the scroll visibly moves something (see _shift_diff),
      - highlights that break into patches rather than running as continuous
        lines, which is what the eye follows down the fall.

    Everything wraps in both axes, so the engine can move the sheet with a
    texture-coordinate offset without a seam ever appearing.
    """
    rng = random.Random(seed)
    # (centre, half-width, weight). Uneven spacing and weight: a curtain of
    # identical ropes reads as a comb.
    specs = [
        {"x": 4.0,   "w": 8.0,  "s": 1.00},
        {"x": 24.0,  "w": 2.6,  "s": 0.42},
        {"x": 41.0,  "w": 10.5, "s": 0.92},
        {"x": 66.0,  "w": 3.4,  "s": 0.58},
        {"x": 80.0,  "w": 6.2,  "s": 0.76},
        {"x": 99.0,  "w": 2.2,  "s": 0.34},
        {"x": 112.0, "w": 9.0,  "s": 1.00},
    ]

    body_px = [[0.0] * height for _ in range(width)]
    hl_px = [[0.0] * height for _ in range(width)]
    alpha_px = [[0.0] * height for _ in range(width)]
    for spec in specs:
        cx, half, weight = spec["x"], spec["w"], spec["s"]
        # Edge wobble (fast) + a slow swell (which is vertical structure).
        f1 = rng.uniform(0.8, 2.0) * TAU / height
        f2 = rng.uniform(2.5, 5.0) * TAU / height
        p1, p2 = rng.uniform(0, TAU), rng.uniform(0, TAU)
        amp = rng.uniform(0.12, 0.30) * half
        # The swell: 2-4 pinches per tile, deep enough to see move.
        fs = rng.uniform(2.0, 4.0) * TAU / height
        ps = rng.uniform(0, TAU)
        fs2 = rng.uniform(4.0, 8.0) * TAU / height
        ps2 = rng.uniform(0, TAU)
        for y in range(height):
            cy = cx + amp * (math.sin(y * f1 + p1) + 0.5 * math.sin(y * f2 + p2))
            swell = 0.62 + 0.38 * (0.5 + 0.5 * math.sin(y * fs + ps))
            strength = weight * (0.80 + 0.14 * math.sin(y * fs + ps + 0.9)
                                 + 0.06 * math.sin(y * fs2 + ps2))
            half_y = half * (0.55 + 0.75 * swell)
            for x in range(width):
                dx = x - cy
                if dx > width / 2: dx -= width
                elif dx < -width / 2: dx += width
                d = abs(dx) / half_y
                if d >= 1.0:
                    continue
                prof = 1.0 if d < 0.45 else 1.0 - (d - 0.45) / 0.55
                v = prof * strength
                if v > body_px[x][y]:
                    body_px[x][y] = v
                    alpha_px[x][y] = 0.35 + 0.65 * swell
                # A bright ridge off-centre in the rope, broken into patches
                # that come and go along the length.
                hd = abs(dx - rng_hl(spec, y)) / max(1.0, half_y * 0.34)
                if hd < 1.0 and d < 0.95:
                    patch = 0.5 + 0.5 * math.sin(y * fs2 + ps2 + 2.1)
                    if patch > 0.30:
                        v = (1.0 - hd) * strength * (patch - 0.30) / 0.70
                        if v > hl_px[x][y]:
                            hl_px[x][y] = v

    img = Image.new("RGBA", (width, height))
    ip = img.load()
    for y in range(height):
        for x in range(width):
            b = min(1.0, body_px[x][y])
            h = min(1.0, hl_px[x][y])
            if b <= 0.01:
                sheen = 0.5 + 0.5 * math.sin((x * 3 + y) * TAU / 97.0)
                a = int(34 * sheen)
                ip[x, y] = (DEEP[0], DEEP[1], DEEP[2], a) if a > 5 else (0, 0, 0, 0)
                continue
            a = int(min(255, (24 + 226 * min(1.0, b * 1.15)) * (0.72 + 0.28 * alpha_px[x][y])))
            col = _lerp(DEEP, BRIGHT, min(1.0, 0.18 + 0.82 * min(1.0, b * 1.2)))
            if h > 0.15:
                col = _lerp(col, FOAM, min(0.8, h * 0.95))
            elif b > 0.6 and math.sin(x * 2.9 + y * 2.3) > 0.86:
                col = _lerp(col, FOAM, 0.3)
            ip[x, y] = (col[0], col[1], col[2], a)
    return img.filter(ImageFilter.GaussianBlur(0.3))


def make_waterfall_core(width=64, height=128, seed=19):
    """The fast inner stream, drawn IN FRONT of the sheet and scrolling about
    half again as fast. Sparse, bright rivulets with foam heads, so the two
    layers moving at different speeds read as depth rather than as one sheet.

    Blended (soft alpha), so the sheet and the wall read through the gaps.
    """
    rng = random.Random(seed)
    specs = [
        {"x": 5.0,  "w": 3.4, "s": 1.00},
        {"x": 18.0, "w": 1.6, "s": 0.60},
        {"x": 31.0, "w": 4.2, "s": 0.95},
        {"x": 47.0, "w": 1.3, "s": 0.55},
        {"x": 56.0, "w": 2.8, "s": 0.85},
    ]

    img = Image.new("RGBA", (width, height))
    ip = img.load()
    for spec in specs:
        cx, half, weight = spec["x"], spec["w"], spec["s"]
        f1 = rng.uniform(0.6, 1.8) * TAU / height
        f2 = rng.uniform(2.2, 4.5) * TAU / height
        p1, p2 = rng.uniform(0, TAU), rng.uniform(0, TAU)
        amp = rng.uniform(0.2, 0.5) * half
        fs, ps = rng.uniform(1.0, 2.2) * TAU / height, rng.uniform(0, TAU)
        # Foam heads: a bright blob every so often along the rivulet, the way
        # a fast stream foams where it accelerates.
        fh, ph = rng.uniform(2.0, 4.0) * TAU / height, rng.uniform(0, TAU)
        for y in range(height):
            cy = cx + amp * (math.sin(y * f1 + p1) + 0.5 * math.sin(y * f2 + p2))
            half_y = half * (0.75 + 0.5 * (0.5 + 0.5 * math.sin(y * fs + ps + 0.9)))
            strength = weight * (0.8 + 0.2 * math.sin(y * fs + ps))
            head = max(0.0, math.sin(y * fh + ph)) ** 6
            for x in range(width):
                dx = x - cy
                if dx > width / 2: dx -= width
                elif dx < -width / 2: dx += width
                d = abs(dx) / half_y
                if d >= 1.0:
                    continue
                prof = 1.0 if d < 0.45 else 1.0 - (d - 0.45) / 0.55
                v = prof * strength
                a = int(min(255, 60 + 195 * v))
                col = _lerp(MID, BRIGHT, min(1.0, 0.35 + 0.65 * v))
                if head > 0.25 and d < 0.7:
                    col = _lerp(col, FOAM, min(0.9, head * 1.2))
                    a = int(min(255, a * (1.0 + 0.35 * head)))
                if a > ip[x, y][3]:
                    ip[x, y] = (col[0], col[1], col[2], a)
    return img.filter(ImageFilter.GaussianBlur(0.35))


def make_water_pool(width=128, height=128, seed=23):
    """Pool water: interference ripples over a dark body.

    Seamless by construction (integer frequencies over the texture period), and
    deliberately DARKER than the stone it sits on — water absorbs, and a bright
    surface reads as a painted blue patch rather than as water. The ripples
    carry the light instead.
    """
    img = Image.new("RGB", (width, height))
    pix = img.load()
    waves = [
        (1, 0, 0.6), (0, 2, 0.5), (2, 1, 0.35), (3, -1, 0.3),
        (1, 3, 0.25), (-2, 2, 0.2), (5, 2, 0.12), (2, -4, 0.1),
    ]
    phases = [i * 1.7 for i in range(len(waves))]
    # The body is deep water; ripples brighten it toward the mid tone and only
    # the interference crests reach the bright colour.
    body = (34, 66, 92)
    for y in range(height):
        v = y / height
        for x in range(width):
            u = x / width
            s = 0.0
            for (kx, ky, amp), ph in zip(waves, phases):
                s += amp * math.sin(2 * math.pi * (kx * u + ky * v) + ph)
            t = 0.5 + 0.5 * math.tanh(s * 0.55)          # -1..1 -> 0..1, soft
            base = _lerp(body, MID, t * 0.8)
            hf = math.sin(2 * math.pi * (7 * u - 5 * v)) * math.sin(2 * math.pi * (4 * u + 9 * v))
            col = _lerp(base, BRIGHT, max(0.0, hf) * 0.45)
            pix[x, y] = (col[0], col[1], col[2])
    return img.filter(ImageFilter.GaussianBlur(0.6)).convert("RGBA")


def make_water_foam(width=128, height=64, seed=31):
    """Churn: the bright, broken water where the fall hits the pool."""
    rng = random.Random(seed)
    img = Image.new("RGB", (width, height), MID)
    draw = ImageDraw.Draw(img)
    for _ in range(240):
        x = rng.uniform(0, width)
        y = rng.uniform(0, height)
        w = rng.uniform(3.0, 12.0)
        h = rng.uniform(2.0, 7.0)
        col = _lerp(MID, FOAM, rng.uniform(0.35, 1.0))
        _wrapped_blob(draw, x, y, w, h, col, width, height)
    img = img.filter(ImageFilter.GaussianBlur(1.3))

    # Crack the foam with a few dark swirls so it does not read as one white
    # smear once it is scrolling.
    draw = ImageDraw.Draw(img)
    for _ in range(60):
        x = rng.uniform(0, width)
        y = rng.uniform(0, height)
        w = rng.uniform(4.0, 14.0)
        h = rng.uniform(1.5, 4.0)
        _wrapped_blob(draw, x, y, w, h, _lerp(DEEP, MID, rng.uniform(0.0, 0.5)), width, height)
    return img.filter(ImageFilter.GaussianBlur(0.9)).convert("RGBA")


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


def _clamp(v):
    return 0 if v < 0 else (255 if v > 255 else int(v))


def main():
    ap = argparse.ArgumentParser()
    default_out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "..", "project", "addons", "poibuilder",
                               "materials", "textures")
    ap.add_argument("--out", default=os.path.normpath(default_out))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

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
