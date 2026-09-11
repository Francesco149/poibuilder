"""Everything drawn ON TOP of the captured frames, rendered with Pillow.

Doing this here rather than inside the editor is what makes the edit cheap and
crisp: the capture is raw pixels, the presentation is a pure function of the
timeline, and a caption or a cursor can be restyled without touching Godot.

Rendering happens at the OUTPUT resolution, so the overlay is pixel-exact
regardless of how far the source was cropped or scaled.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT_DIR = Path(__file__).resolve().parents[2] / "fonts"

# The showcase palette is the plugin's own: cyan accent on near-black slate.
BG = (9, 12, 18)
FG = (242, 246, 251)
DIM = (168, 180, 196)
ACCENT = (51, 224, 255)
PANEL = (12, 16, 24, 219)
STROKE = (255, 255, 255, 30)

_FALLBACKS = [
    "/usr/share/fonts/TTF/Roboto-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/Cantarell-Regular.ttf",
]


def _font_path() -> str:
    inter = FONT_DIR / "Inter-Variable.ttf"
    if inter.exists():
        return str(inter)
    for f in _FALLBACKS:
        if Path(f).exists():
            return f
    raise RuntimeError(f"no usable font (looked in {FONT_DIR} and {_FALLBACKS})")


@lru_cache(maxsize=256)
def font(size: int, weight: int = 400) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(_font_path(), size)
    try:
        # Inter is a variable font: [optical size, weight]
        f.set_variation_by_axes([max(14, min(32, size)), weight])
    except Exception:
        pass
    return f


def text_width(s: str, size: int, weight: int = 400) -> float:
    return font(size, weight).getlength(s)


def _hex(color: str) -> tuple[int, int, int]:
    color = color.lstrip("#")
    return tuple(int(color[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def _spaced(d: ImageDraw.ImageDraw, xy, text: str, f, fill, spacing: float) -> float:
    """Draw with manual letter-spacing; returns the advanced x."""
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=f, fill=fill)
        x += f.getlength(ch) + spacing
    return x - spacing


def spaced_width(text: str, f, spacing: float) -> float:
    return sum(f.getlength(c) for c in text) + spacing * max(0, len(text) - 1)


# ---------------------------------------------------------------------------
# cursor
# ---------------------------------------------------------------------------

# Classic arrow, in a 24-unit box.
_ARROW = [(0.0, 0.0), (0.0, 18.6), (4.7, 14.3), (7.5, 20.9),
          (10.4, 19.6), (7.4, 13.1), (12.7, 13.1)]


@lru_cache(maxsize=8)
def cursor_sprite(height: int = 46) -> Image.Image:
    """Anti-aliased arrow cursor with an outline and a soft drop shadow."""
    ss = 4                                     # supersample factor
    h = height * ss
    scale = h / 18.6
    w = int(13.2 * scale) + 4 * ss
    pad = 3 * ss
    img = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pts = [(pad + x * scale, pad + y * scale) for x, y in _ARROW]

    # shadow
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).polygon([(x + 1.2 * ss, y + 1.8 * ss) for x, y in pts],
                               fill=(0, 0, 0, 150))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(1.6 * ss)))
    # body + outline
    d.line(pts + [pts[0]], fill=(12, 15, 21, 255), width=max(2, int(1.9 * ss)),
           joint="curve")
    d.polygon(pts, fill=(255, 255, 255, 255))
    return img.resize((img.width // ss, img.height // ss), Image.LANCZOS)


def cursor_hotspot(sprite: Image.Image) -> tuple[int, int]:
    """Pixel offset of the arrow's tip inside the sprite."""
    return (int(sprite.width * 0.28), int(sprite.height * 0.19))


def draw_cursor(base: Image.Image, pos: tuple[float, float], height: int = 46,
                glow: float = 0.0, click: float = 0.0) -> None:
    """Composite the cursor (plus an optional attention glow / click ripple)."""
    if glow > 0.001:
        r = 54
        g = Image.new("RGBA", (r * 2, r * 2), (0, 0, 0, 0))
        gd = ImageDraw.Draw(g)
        for i in range(9, 0, -1):
            a = int(glow * 16 * (1.0 - i / 9.0) ** 1.5)
            if a > 0:
                k = r * i / 9.0
                gd.ellipse([r - k, r - k, r + k, r + k], fill=(255, 255, 255, a))
        base.alpha_composite(g.filter(ImageFilter.GaussianBlur(9)),
                             (int(pos[0] - r), int(pos[1] - r)))
    if click > 0.001:
        # expanding ring on mousedown
        progress = 1.0 - click
        r = 12 + 40 * progress
        layer = Image.new("RGBA", (int(r * 2 + 8), int(r * 2 + 8)), (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse(
            [4, 4, 4 + r * 2, 4 + r * 2],
            outline=(120, 232, 255, int(200 * click)), width=3)
        base.alpha_composite(layer, (int(pos[0] - r - 4), int(pos[1] - r - 4)))
    sp = cursor_sprite(height)
    hx, hy = cursor_hotspot(sp)
    base.alpha_composite(sp, (int(pos[0] - hx), int(pos[1] - hy)))


# ---------------------------------------------------------------------------
# captions
# ---------------------------------------------------------------------------

@dataclass
class CaptionLook:
    size: int = 1280
    height: int = 720
    text_px: int = 33
    sub_px: int = 22
    label_px: int = 15
    margin: int = 44
    pad: int = 22
    radius: int = 13
    accent: tuple[int, int, int] = ACCENT


def _caption_block(text: str, sub: str, label: str, look: CaptionLook,
                   style: str) -> Image.Image:
    """The caption rendered on its own transparent layer (content-addressed)."""
    W, H = look.size, look.height
    fl = font(look.label_px, 600)
    ft = font(look.text_px, 600)
    fs = font(look.sub_px, 400)

    lines: list[str] = []
    if text:
        lines.append(text)
    if sub:
        lines.append(sub)
    text_w = max([text_width(t, look.text_px, 600) for t in lines] or [0])
    label_w = spaced_width(label, fl, 2.4) if label else 0
    inner_w = max(text_w, label_w)
    inner_h = 0
    if label:
        inner_h += look.label_px + 10
    inner_h += look.text_px + 6
    if sub:
        inner_h += look.sub_px + 4

    if style == "plain":
        w = int(inner_w) + 4
        h = int(inner_h) + 4
        layer = Image.new("RGBA", (w + look.pad * 2, h + look.pad * 2), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        y = look.pad
    else:
        w = int(inner_w) + look.pad * 2 + 16
        h = int(inner_h) + look.pad * 2
        layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        # Shadow + panel + hairline border, then the cyan accent bar.
        sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle([0, 0, w - 1, h - 1], look.radius,
                                             fill=(0, 0, 0, 120))
        layer.alpha_composite(sh.filter(ImageFilter.GaussianBlur(9)), (0, 5))
        d.rounded_rectangle([0, 0, w - 1, h - 1], look.radius, fill=PANEL,
                            outline=STROKE, width=1)
        d.rounded_rectangle([0, 0, 7, h - 1], 3, fill=look.accent + (255,))
        d.rectangle([4, 0, 7, h - 1], fill=look.accent + (255,))
        y = look.pad

    x = look.pad + 16
    if label:
        _spaced(d, (x, y), label.upper(), fl, look.accent + (235,), 2.4)
        y += look.label_px + 10
    if text:
        d.text((x, y), text, font=ft, fill=FG + (255,))
        y += look.text_px + 6
    if sub:
        d.text((x, y), sub, font=fs, fill=DIM + (255,))
    return layer


@lru_cache(maxsize=64)
def caption_layer(text: str, sub: str, label: str, size: int, height: int,
                  style: str) -> Image.Image:
    return _caption_block(text, sub, label, CaptionLook(size, height), style)


def place(layer: Image.Image, canvas_size: tuple[int, int], pos: str,
          margin: int) -> tuple[int, int]:
    W, H = canvas_size
    w, h = layer.size
    if pos == "bl":
        return (margin, H - h - margin)
    if pos == "bc":
        return ((W - w) // 2, H - h - margin)
    if pos == "tl":
        return (margin, margin)
    if pos == "tr":
        return (W - w - margin, margin)
    if pos == "mid":
        return ((W - w) // 2, (H - h) // 2)
    if pos == "br":
        return (W - w - margin, H - h - margin)
    return (margin, H - h - margin)


# ---------------------------------------------------------------------------
# cards (title / end / interstitial)
# ---------------------------------------------------------------------------

@lru_cache(maxsize=16)
def card_background(size: int, height: int, title: str, sub: str,
                    kicker: str, bullets: tuple[str, ...]) -> Image.Image:
    """A full-frame dark card with the plugin's grid motif and a cyan glow."""
    W, H = size, height
    img = Image.new("RGB", (W, H), (7, 10, 15))
    d = ImageDraw.Draw(img, "RGBA")

    # vertical gradient
    for y in range(H):
        t = y / max(H - 1, 1)
        c = (int(11 + 6 * (1 - t)), int(15 + 9 * (1 - t)), int(23 + 14 * (1 - t)))
        d.line([(0, y), (W, y)], fill=c)

    # perspective grid, echoing the plugin's infinite grid
    horizon = int(H * 0.42)
    step = 34
    for i in range(-28, 29):
        x0 = W // 2 + i * step
        d.line([(W // 2 + i * step * 0.06, horizon), (x0, H)], fill=(46, 190, 224, 26), width=1)
    y = horizon
    k = 3
    while y < H:
        d.line([(0, y), (W, y)], fill=(46, 190, 224, 22), width=1)
        y += k
        k = int(k * 1.33) + 1
    for i in range(-14, 15):
        d.line([(W // 2 + i * step * 4, horizon), (W // 2 + i * step, H)],
               fill=(46, 190, 224, 14), width=1)

    # glow behind the type
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W * 0.16, -H * 0.30, W * 0.84, H * 0.55], fill=(40, 190, 235, 46))
    img = Image.alpha_composite(img.convert("RGBA"), glow.filter(ImageFilter.GaussianBlur(90)))

    d = ImageDraw.Draw(img, "RGBA")
    y = int(H * 0.30)
    if kicker:
        fk = font(20, 600)
        w = spaced_width(kicker, fk, 4.0)
        _spaced(d, ((W - w) / 2, y), kicker.upper(), fk, ACCENT + (255,), 4.0)
        y += 46
    if title:
        ft = font(76, 700)
        d.text((W / 2, y), title, font=ft, fill=FG + (255,), anchor="ma")
        y += 96
    if sub:
        fsx = font(27, 400)
        d.text((W / 2, y), sub, font=fsx, fill=DIM + (255,), anchor="ma")
        y += 54
    if bullets:
        fb = font(24, 500)
        for b in bullets:
            d.text((W / 2, y), b, font=fb, fill=(206, 218, 232, 255), anchor="ma")
            y += 38
    # accent rule under the type block
    d.rounded_rectangle([W / 2 - 60, y + 14, W / 2 + 60, y + 18], 2, fill=ACCENT + (255,))
    return img.convert("RGBA")


# ---------------------------------------------------------------------------
# helper: source pixel -> output pixel mapping
# ---------------------------------------------------------------------------

def make_mapper(crop: tuple[int, int, int, int], out_size: tuple[int, int],
                zoom: tuple[float, float] | None, span: int):
    """Maps a window-space point to output pixels, matching the ffmpeg chain.

    Mirrors, in order: the region crop, the animated centre crop (``zoom``) and
    the scale-to-cover of the output frame. ``i`` is a SOURCE frame offset and
    ``span`` the number of source frames the clip walks, because that is what
    the crop expression in the filtergraph counts.
    """
    cx, cy, cw, ch = crop
    W, H = out_size
    z0, z1 = (zoom or (1.0, 1.0))

    def f(x: float, y: float, i: float) -> tuple[float, float]:
        z = z0 + (z1 - z0) * (i / max(span - 1, 1))
        w, h = cw / z, ch / z
        ox, oy = cx + (cw - w) / 2.0, cy + (ch - h) / 2.0
        scale = max(W / w, H / h)
        px = (x - ox - w / 2.0) * scale + W / 2.0
        py = (y - oy - h / 2.0) * scale + H / 2.0
        return px, py

    return f


# ---------------------------------------------------------------------------
# frames (rounded device / inset styling around placed content)
# ---------------------------------------------------------------------------

@lru_cache(maxsize=16)
def frame_layer(rect: tuple[int, int, int, int], canvas: tuple[int, int],
                radius: int = 22, border: bool = True, glow: bool = True) -> Image.Image:
    """Mask the corners of placed content and dress its edge.

    Returns a transparent layer that (a) fades/clears the four corners of
    `rect` — so a rectangle of video reads as a rounded card — and (b) paints a
    hairline border plus a soft cyan bloom that survives only OUTSIDE the rect.
    """
    x, y, w, h = rect
    W, H = canvas
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    corner = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cd = ImageDraw.Draw(corner)
    cd.rectangle([0, 0, w - 1, h - 1], fill=BG + (255,))
    hole = Image.new("L", (w, h), 255)
    ImageDraw.Draw(hole).rounded_rectangle([0, 0, w - 1, h - 1], radius, fill=0)
    layer.paste(corner, (x, y), hole)

    if glow:
        g = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(g).rounded_rectangle([x - 3, y - 3, x + w + 2, y + h + 2],
                                            radius + 3, outline=(46, 190, 224, 130), width=7)
        g = g.filter(ImageFilter.GaussianBlur(16))
        inner = Image.new("L", (w + 24, h + 24), 255)
        ImageDraw.Draw(inner).rounded_rectangle([12, 12, 12 + w, 12 + h], radius, fill=0)
        g.paste((0, 0, 0, 0), (x - 12, y - 12), inner)
        layer.alpha_composite(g)

    if border:
        d = ImageDraw.Draw(layer)
        d.rounded_rectangle([x, y, x + w - 1, y + h - 1], radius,
                            outline=(255, 255, 255, 34), width=2)
        d.rounded_rectangle([x, y, x + w - 1, y + h - 1], radius,
                            outline=(140, 220, 245, 40), width=1)
    return layer


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:48]


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def ease_out(t: float) -> float:
    return 1.0 - (1.0 - t) ** 3


def clamp01(t: float) -> float:
    return 0.0 if t < 0 else (1.0 if t > 1 else t)


def ripple_alpha(age_frames: float, life: float = 26.0) -> float:
    return clamp01(1.0 - age_frames / life)


def soft_pulse(frames_since: float, period: float = 90.0) -> float:
    """A gentle attention glow that breathes while the pointer is still."""
    return 0.35 + 0.25 * math.cos(min(frames_since, period) / period * math.tau)
