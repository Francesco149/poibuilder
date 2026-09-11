#!/usr/bin/env python3
"""Generates the particle textures the emitter demo uses.

Three textures, one per emitter render mode the format standardises:

  particle_glow.png   64x64  additive glimmer: RGB carries the falloff, the
                             alpha is 1-bit (so it stays RGBA5551 on the PSP,
                             which halves its memory and keeps it inside the
                             GE's texture cache)
  particle_flame.png  64x64  2x2 flipbook of 32x32 flame frames, same 1-bit
                             alpha: the cells are the frames a particle walks
                             through over its lifetime
  particle_smoke.png  64x64  soft-edged puff: its alpha is a real gradient, so
                             it must travel as RGBA8888 and blend

Two conventions from the format specification are load bearing here:

  * Every cell of a flipbook has a fully transparent border ring. The runtime
    insets its sampling by half a texel and disables mipmapping, but a
    transparent margin means even a stray filter tap can only pick up more
    nothing, never the neighbouring frame.
  * Additive art puts its falloff in the RGB channels, not in the alpha. One
    alpha bit can only cut a texel out, so a soft glow has to live in the colour
    channels -- and that is exactly what additive blending multiplies.

Usage: python3 retro_engine/gen_particle_textures.py [--out DIR]
Writes into project/addons/poibuilder/materials/textures/ by default.
"""
import argparse
import math
import os

import numpy as np

from PIL import Image, ImageDraw, ImageFilter

TAU = math.pi * 2

# Warm ember palette: the core of a flame is nearly white, its body amber, its
# tips deep orange. Kept as constants so the three textures read as one family.
CORE = (255, 235, 190)
BODY = (255, 170, 70)
TIP = (232, 96, 28)


def _smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def gen_glow(size=64):
    """A radial glimmer with a 1-bit alpha: additive sparks and motes."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) * 0.5
    d = np.sqrt((x - c) ** 2 + (y - c) ** 2) / c

    fall = _smoothstep(1.0 - d)                # broad halo
    core = np.clip(1.0 - d * 2.1, 0.0, 1.0) ** 1.6  # hot centre

    r = fall * 220.0 + core * 35.0
    g = fall * 150.0 + core * 70.0
    b = fall * 70.0 + core * 90.0
    a = np.where(d < 0.92, 255.0, 0.0)         # binary on purpose

    img = np.dstack([r, g, b, a]).clip(0, 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def _flame_cell(seed, w=32, h=32):
    """One flame frame: a tapering teardrop that flickers with `seed`."""
    rng = np.random.RandomState(seed)
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    cx = (w - 1) * 0.5
    # Normalised height: 0 at the tip, 1 at the base of the flame.
    t = np.clip((y - 1.0) / (h - 2.0), 0.0, 1.0)

    # Teardrop width: zero at the tip, widest about a third of the way up, and
    # rounded back to zero at the base -- a triangle reads as a cone, not fire.
    prof = np.maximum(np.sin(math.pi * np.power(t, 0.62)), 0.0) ** 0.75
    # Per-frame shape variation: the whole flame leans, breathes and bends, so a
    # flipbook of these frames reads as motion rather than as a pulsing blob.
    lean = math.sin(seed * 0.9) * 0.22
    breathe = 0.86 + 0.26 * ((seed * 0.37) % 1.0)
    sway = (lean * (1.0 - t) ** 2 + 0.06 * math.sin(seed * 1.7)) * w * 0.30
    bend = 1.0 + 0.14 * np.sin(t * 4.3 + seed * 2.3)
    half = (w * 0.30) * prof * breathe * bend

    d = np.abs(x - (cx + sway)) / np.maximum(half, 0.5)
    body = np.clip(1.0 - d, 0.0, 1.0)

    # Colour ramp up the flame: white-hot low, amber mid, orange tip.
    r = np.where(t > 0.66, CORE[0], np.where(t > 0.3, BODY[0], TIP[0]))
    g = np.where(t > 0.66, CORE[1], np.where(t > 0.3, BODY[1], TIP[1]))
    b = np.where(t > 0.66, CORE[2], np.where(t > 0.3, BODY[2], TIP[2]))

    # Falloff toward the silhouette, then a touch of internal variation so the
    # body is not a flat gradient.
    shade = body ** 0.55
    noise = 0.9 + 0.1 * np.sin(x * 1.3 + y * 0.7 + seed * 3.1)
    r = r * shade * noise
    g = g * shade * noise
    b = b * shade * noise

    a = np.where(body > 0.16, 255.0, 0.0)      # binary: 5551-friendly
    cell = np.dstack([r, g, b, a]).clip(0, 255).astype(np.uint8)
    # A fully transparent border ring: whatever a filter tap reaches for at the
    # cell edge, it cannot pick up the neighbouring frame.
    cell[0, :, 3] = 0
    cell[-1, :, 3] = 0
    cell[:, 0, 3] = 0
    cell[:, -1, 3] = 0
    return cell


def gen_flame_atlas(cell=32):
    """A 2x2 flipbook of flame frames, laid out row-major like the runtime's
    frame index (frame = row * cols + col)."""
    cols = rows = 2
    size = cell * cols
    img = np.zeros((size, size, 4), dtype=np.uint8)
    for i in range(cols * rows):
        cx = (i % cols) * cell
        cy = (i // cols) * cell
        img[cy:cy + cell, cx:cx + cell] = _flame_cell(seed=7 + i * 13, w=cell, h=cell)
    return Image.fromarray(img, "RGBA")


def gen_smoke(size=64):
    """A soft puff whose alpha is a real gradient: the BLEND path."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) * 0.5
    d = np.sqrt((x - c) ** 2 + (y - c) ** 2) / c

    # Density: three overlapping lobes give the silhouette an irregular edge, so
    # a spray of them does not read as identical circles.
    lobes = np.zeros_like(d)
    for (ox, oy, r, w) in ((-0.22, -0.16, 0.55, 1.0),
                           (0.26, 0.06, 0.48, 0.85),
                           (-0.04, 0.28, 0.42, 0.75)):
        dd = np.sqrt((x - (c + ox * c)) ** 2 + (y - (c + oy * c)) ** 2) / c
        lobes += w * np.clip(1.0 - dd / r, 0.0, 1.0)

    density = np.clip(lobes / 2.1, 0.0, 1.0)
    density = _smoothstep(density) * _smoothstep(1.0 - d)
    # Break the surface up so the puff has internal structure rather than being
    # a single soft blob.
    density *= 0.85 + 0.15 * np.sin(x * 0.9 + 1.7) * np.sin(y * 1.1 - 0.6)

    r = 205.0 * density + 30.0
    g = 215.0 * density + 32.0
    b = 225.0 * density + 34.0
    a = density * 235.0

    img = np.dstack([r, g, b, a]).clip(0, 255).astype(np.uint8)
    out = Image.fromarray(img, "RGBA")
    return out.filter(ImageFilter.GaussianBlur(0.6))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="project/addons/poibuilder/materials/textures")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    outputs = {
        "particle_glow.png": gen_glow(),
        "particle_flame.png": gen_flame_atlas(),
        "particle_smoke.png": gen_smoke(),
    }
    for name, img in outputs.items():
        path = os.path.join(args.out, name)
        img.save(path)
        # Objective check: the additive art must keep a 1-bit alpha so it stays
        # RGBA5551 on the device, and every texture must be power-of-two.
        arr = np.asarray(img)
        alpha = arr[:, :, 3]
        binary = bool(np.all((alpha == 0) | (alpha == 255)))
        w, h = img.size
        pot = (w & (w - 1)) == 0 and (h & (h - 1)) == 0
        print(f"{name}: {w}x{h} pot={pot} binary_alpha={binary} "
              f"opaque_px={int((alpha > 0).sum())}")


if __name__ == "__main__":
    main()
