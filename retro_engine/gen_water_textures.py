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
CYAN_BODY = (68, 140, 185)
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

def make_waterfall_sheet(width=128, height=256, seed=7):
    """Falling water curtain: vertically stretched runnels with glistening specular streaks.

    Seamless on both X and Y axes via integer-period noise generators.
    """
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pix = img.load()

    for y in range(height):
        ny = y / float(height)
        for x in range(width):
            nx = x / float(width)
            n1 = _wnoise(seed, nx * 6.0, ny * 4.0, 6, 4)
            n2 = _wnoise(seed + 31, nx * 12.0, ny * 8.0, 12, 8)
            n3 = _wnoise(seed + 77, nx * 24.0, ny * 16.0, 24, 16)
            runnel = n1 * 0.55 + n2 * 0.30 + n3 * 0.15
            col_mod = math.sin(nx * TAU * 3.0 + n1 * 1.5) * 0.5 + 0.5
            val = runnel * (0.65 + 0.35 * col_mod)

            if val < 0.36:
                pix[x, y] = (0, 0, 0, 0)
                continue

            d = (val - 0.36) / 0.64
            if d < 0.45:
                t = d / 0.45
                c = _lerp(DEEP, CYAN_BODY, t)
                alpha = int(140 + 90 * t)
            elif d < 0.80:
                t = (d - 0.45) / 0.35
                c = _lerp(CYAN_BODY, BRIGHT, t)
                alpha = int(230 + 20 * t)
            else:
                t = (d - 0.80) / 0.20
                c = _lerp(BRIGHT, FOAM, t)
                alpha = 255

            pix[x, y] = (c[0], c[1], c[2], alpha)

    return _toroidal_blur(img, 0.35)


def make_waterfall_core(width=64, height=128, seed=19):
    """Fast inner stream: narrower, focused cascade with bright specular highlights.

    Blended (soft alpha), seamless in X and Y on the torus.
    """
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pix = img.load()

    for y in range(height):
        ny = y / float(height)
        for x in range(width):
            nx = x / float(width)
            dist_from_center = abs(nx - 0.5) * 2.0
            col_envelope = 1.0 - math.pow(dist_from_center, 1.8)

            n1 = _wnoise(seed, nx * 5.0, ny * 4.0, 5, 4)
            n2 = _wnoise(seed + 43, nx * 10.0, ny * 8.0, 10, 8)
            val = (n1 * 0.6 + n2 * 0.4) * col_envelope

            if val < 0.22:
                pix[x, y] = (0, 0, 0, 0)
                continue

            norm = (val - 0.22) / 0.78
            if norm < 0.40:
                c = _lerp(CYAN_BODY, MID, norm / 0.40)
                alpha = int(120 + 80 * (norm / 0.40))
            elif norm < 0.75:
                c = _lerp(MID, BRIGHT, (norm - 0.40) / 0.35)
                alpha = int(200 + 40 * ((norm - 0.40) / 0.35))
            else:
                c = _lerp(BRIGHT, FOAM, (norm - 0.75) / 0.25)
                alpha = 250

            pix[x, y] = (c[0], c[1], c[2], alpha)

    return _toroidal_blur(img, 0.35)

def make_water_pool(width=128, height=128, seed=23):
    """Pool water: organic caustic web network and interference ripples over a translucent body.

    Seamless by construction (integer frequencies over the texture period in both axes),
    and carrying soft alpha so the underlying stone tiles and steps read through the water
    with caustic light play.
    """
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pix = img.load()
    waves = [
        (1, 0, 0.6), (0, 2, 0.5), (2, 1, 0.35), (3, -1, 0.3),
        (1, 3, 0.25), (-2, 2, 0.2), (5, 2, 0.12), (2, -4, 0.1),
    ]
    phases = [i * 1.7 for i in range(len(waves))]
    body = (28, 60, 88)

    for y in range(height):
        v = y / float(height)
        for x in range(width):
            u = x / float(width)
            s = 0.0
            for (kx, ky, amp), ph in zip(waves, phases):
                s += amp * math.sin(TAU * (kx * u + ky * v) + ph)
            t = 0.5 + 0.5 * math.tanh(s * 0.55)
            base = _lerp(body, MID, t * 0.8)

            # Integer-frequency high-frequency caustics: (3, 2) and (2, 4)
            w1 = math.sin(u * TAU * 3.0 + math.cos(v * TAU * 2.0) * 1.5)
            w2 = math.sin(v * TAU * 4.0 + math.sin(u * TAU * 2.0) * 1.2)
            w3 = math.sin((u + v) * TAU * 2.0)
            w4 = math.sin((u - v) * TAU * 3.0 + w1 * 0.8)
            caustic = (w1 + w2 + w3 + w4) * 0.25
            c_val = 1.0 - math.pow(abs(caustic), 0.45)

            if c_val > 0.40:
                c_t = (c_val - 0.40) / 0.60
                col = _lerp(base, BRIGHT, c_t * 0.95)
                alpha = int(160 + 95 * c_t)
            else:
                col = base
                alpha = int(120 + 40 * (c_val / 0.40))

            pix[x, y] = (col[0], col[1], col[2], alpha)

    return _toroidal_blur(img, 0.5)


def _toroidal_blur(img, radius):
    """Gaussian blur wrapped around a torus so image boundaries remain 100% seamless."""
    w, h = img.size
    pad = int(math.ceil(radius * 3))
    big = Image.new(img.mode, (w + pad * 2, h + pad * 2))
    big.paste(img, (pad, pad))
    big.paste(img.crop((0, h - pad, w, h)), (pad, 0))
    big.paste(img.crop((0, 0, w, pad)), (pad, h + pad))
    big.paste(img.crop((w - pad, 0, w, h)), (0, pad))
    big.paste(img.crop((0, 0, pad, h)), (w + pad, pad))
    big.paste(img.crop((w - pad, h - pad, w, h)), (0, 0))
    big.paste(img.crop((0, h - pad, pad, h)), (w + pad, 0))
    big.paste(img.crop((w - pad, 0, w, pad)), (0, h + pad))
    big.paste(img.crop((0, 0, pad, pad)), (w + pad, h + pad))
    blurred = big.filter(ImageFilter.GaussianBlur(radius))
    return blurred.crop((pad, pad, pad + w, pad + h))


def make_water_foam(width=128, height=64, seed=31):
    """Churn: turbulent foaming billows spreading away from the waterfall impact point.

    Rendered with transparent background and soft alpha falloff around churn boundaries,
    so the foam overlays naturally on top of the pool without forming harsh rectangular seams.
    Wrapped seamlessly in both X and Y.
    """
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pix = img.load()

    for y in range(height):
        ny = y / float(height)
        for x in range(width):
            nx = x / float(width)
            # Integer periods (6, 4), (12, 8), (24, 16) wrap seamlessly in both axes
            n1 = _wnoise(seed, nx * 6.0, ny * 4.0, 6, 4)
            n2 = _wnoise(seed + 19, nx * 12.0, ny * 8.0, 12, 8)
            n3 = _wnoise(seed + 47, nx * 24.0, ny * 16.0, 24, 16)
            churn = n1 * 0.50 + n2 * 0.35 + n3 * 0.15

            # Soft alpha foam billows:
            # Low churn: transparent, revealing the pool ripples below
            # Mid churn: translucent aquatic cyan billow
            # High churn: glistening white foam heads
            if churn < 0.35:
                alpha = int(max(0, (churn - 0.20) / 0.15 * 50))
                col = CYAN_BODY
            elif churn < 0.60:
                t = (churn - 0.35) / 0.25
                col = _lerp(CYAN_BODY, MID, t)
                alpha = int(50 + 130 * t)
            elif churn < 0.80:
                t = (churn - 0.60) / 0.20
                col = _lerp(MID, BRIGHT, t)
                alpha = int(180 + 55 * t)
            else:
                t = (churn - 0.80) / 0.20
                col = _lerp(BRIGHT, FOAM, t)
                alpha = int(235 + 20 * t)

            pix[x, y] = (col[0], col[1], col[2], alpha)

    return _toroidal_blur(img, 0.4)


def _h01(seed, ix, iy):
    s = (seed ^ (int(ix) * 374761393) ^ (int(iy) * 668265263)) & 0xffffffff
    s = (s ^ (s >> 13)) * 1274126177 & 0xffffffff
    return (s & 0xffff) / 65535.0


def _wnoise(seed, x, y, period_x, period_y):
    gx = int(math.floor(x))
    gy = int(math.floor(y))
    fx = x - float(gx)
    fy = y - float(gy)
    def at(ix, iy):
        return _h01(seed, ix % period_x, iy % period_y)
    a = at(gx, gy)
    b = at(gx + 1, gy)
    c = at(gx, gy + 1)
    d = at(gx + 1, gy + 1)
    u = fx * fx * (3.0 - 2.0 * fx)
    v = fy * fy * (3.0 - 2.0 * fy)
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v

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

def make_tiles_wet_4x4(base_path):
    """Generates wet stone tiles from tiles_light_4x4 by applying aquatic slate tint and water sheen."""
    if not os.path.exists(base_path):
        return None
    base = Image.open(base_path).convert("RGB")
    arr = np.array(base, dtype=np.float32)
    # Darkened aquatic slate tone (0.55, 0.62, 0.70)
    tint = np.array([0.55, 0.62, 0.70], dtype=np.float32)
    arr = np.clip(arr * tint, 0, 255).astype(np.uint8)
    return Image.fromarray(arr)


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

    light_tiles_path = os.path.join(args.out, "tiles_light_4x4.png")
    textures = {
        "waterfall_sheet.png": make_waterfall_sheet(),
        "waterfall_core.png": make_waterfall_core(),
        "water_pool.png": make_water_pool(),
        "water_foam.png": make_water_foam(),
        "water_spray.png": make_water_spray(),
    }
    wet_tiles = make_tiles_wet_4x4(light_tiles_path)
    if wet_tiles is not None:
        textures["tiles_wet_4x4.png"] = wet_tiles
    for name, img in textures.items():
        path = os.path.join(args.out, name)
        img.convert("RGBA").save(path)
        print(f"{path}: {img.width}x{img.height} ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    main()
