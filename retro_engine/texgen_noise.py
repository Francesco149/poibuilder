"""Seamless (toroidal) noise helpers shared by the stock-texture generators.

Every stock texture tiles, and the water ones scroll, so every field here is
periodic on the image rectangle BY CONSTRUCTION rather than by blending edges:

  * `pnoise` low-passes white noise in the frequency domain. The FFT treats
    the image as a torus, so the result wraps exactly in both axes, and an
    anisotropic Gaussian filter (different sigma per axis) gives streaks.
  * `warp` resamples with wraparound indexing (bilinear, indices modulo the
    size), so a domain warp of a periodic field stays periodic.
  * `voronoi` measures distances on the torus (nearest of the 9 images of
    every feature point), so its cells continue across the edges.

All sizes are in PIXELS, which keeps the features at a predictable scale for
the retro exporter (the PSP samples these at their native size; anything much
under ~2 px wide turns to shimmer once the device builds its mip chain).

Deterministic: every function takes an explicit numpy Generator or seed.
"""
import numpy as np


def pnoise(h, w, rng, sigma_y, sigma_x):
    """Zero-mean, unit-std periodic noise; features ~sigma pixels across."""
    white = rng.standard_normal((h, w))
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    # Frequency response of a Gaussian blur with the given sigma (pixels).
    filt = np.exp(-2.0 * np.pi ** 2 * ((fy * sigma_y) ** 2 + (fx * sigma_x) ** 2))
    out = np.real(np.fft.ifft2(np.fft.fft2(white) * filt))
    out -= out.mean()
    sd = out.std()
    return out / sd if sd > 0 else out


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def blur(field, sigma_y, sigma_x=None):
    """Periodic Gaussian blur of a 2-D field (or of each channel of a 3-D one)."""
    if sigma_x is None:
        sigma_x = sigma_y
    if field.ndim == 3:
        return np.stack([blur(field[..., c], sigma_y, sigma_x)
                         for c in range(field.shape[2])], axis=-1)
    h, w = field.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    filt = np.exp(-2.0 * np.pi ** 2 * ((fy * sigma_y) ** 2 + (fx * sigma_x) ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(field) * filt))


def warp(field, dx, dy):
    """Samples `field` at (x + dx, y + dy) with wraparound bilinear filtering."""
    h, w = field.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    sx = xx + dx
    sy = yy + dy
    x0 = np.floor(sx).astype(int)
    y0 = np.floor(sy).astype(int)
    tx = sx - x0
    ty = sy - y0
    x0 %= w
    y0 %= h
    x1 = (x0 + 1) % w
    y1 = (y0 + 1) % h
    if field.ndim == 3:
        tx = tx[..., None]
        ty = ty[..., None]
    a = field[y0, x0]
    b = field[y0, x1]
    c = field[y1, x0]
    d = field[y1, x1]
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty


def voronoi(h, w, rng, count, xx=None, yy=None):
    """Torus Voronoi: returns (F1, F2) distance fields in pixels.

    `xx`/`yy` may be warped sample coordinates (same shape as the image)."""
    if xx is None or yy is None:
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    pts = rng.uniform(0.0, 1.0, (count, 2)) * np.array([w, h])
    f1 = np.full((h, w), np.inf)
    f2 = np.full((h, w), np.inf)
    for px, py in pts:
        ddx = np.abs(xx - px) % w
        ddx = np.minimum(ddx, w - ddx)
        ddy = np.abs(yy - py) % h
        ddy = np.minimum(ddy, h - ddy)
        d = np.sqrt(ddx * ddx + ddy * ddy)
        f2 = np.where(d < f1, f1, np.minimum(f2, d))
        f1 = np.minimum(f1, d)
    return f1, f2


def mix(a, b, t):
    """Per-pixel lerp between colours/arrays; t broadcasts over channels."""
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    t = np.asarray(t, dtype=np.float64)
    if t.ndim == 2:
        t = t[..., None]
    return a + (b - a) * t


def to_u8(arr):
    return np.clip(np.rint(arr), 0, 255).astype(np.uint8)
