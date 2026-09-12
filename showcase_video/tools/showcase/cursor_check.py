"""Cursor/geometry verification for the showcase pipeline.

The drawn cursor is composited in post from the recorded pointer track, so it
has to land where the recorded click was AFTER the clip's own transform: the
region crop, the animated zoom crop, and the fit into the clip's box (`cover`
fills and crops; `contain` letterboxes — and either can sit at an `into`
offset). Two checks, both against ground truth rather than against the mapper's
own arithmetic:

1. ``check_mapper`` drives a SYNTHETIC frame through the clip's real ffmpeg
   filtergraph with a marker drawn at the recorded click, finds the marker in
   the output, and compares it with ``draw.make_mapper``'s prediction. This is
   the check that would have caught the letterboxed clips the old mapper placed
   the cursor on as if they were full-frame covers.
2. ``check_hotspot`` draws the real cursor sprite at a known point and measures
   the arrow's tip in the raster, so the sprite/hotspot pair is verified too
   (the hotspot used to be two guessed fractions of the sprite size, which put
   the tip ~8 px away from the click).

Run:  python -m showcase.cursor_check [clip_id ...]
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

from . import build, draw, edl, ffmpeg, overlay

MARK = (255, 0, 255)


def _marker_frame(size: tuple[int, int], at: tuple[int, int], radius: int = 3) -> Image.Image:
    img = Image.new("RGB", size, (10, 10, 14))
    d = ImageDraw.Draw(img)
    x, y = at
    d.ellipse([x - radius, y - radius, x + radius, y + radius], fill=MARK)
    return img


def _find_marker(img: Image.Image, radius: int = 3) -> tuple[float, float] | None:
    """Marker position from its bounding box, or None when it was cropped away.

    The box's top-left plus `radius` is used instead of the centroid: a marker
    near the frame edge gets clipped, and a clipped centroid reads as an offset
    that has nothing to do with the mapping.
    """
    px = img.convert("RGB").load()
    w, h = img.size
    xs: list[int] = []
    ys: list[int] = []
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if r > 150 and b > 150 and g < 110:
                xs.append(x)
                ys.append(y)
    if len(xs) < 4:
        return None
    if min(xs) == 0 or min(ys) == 0 or max(xs) == w - 1 or max(ys) == h - 1:
        return None            # clipped by an edge: unmeasurable
    return float(min(xs) + radius), float(min(ys) + radius)


def check_mapper(clip: edl.Clip, proj: edl.Project, src: build.Source, fit: ffmpeg.Fit,
                 point: tuple[int, int], frames: int = 6) -> tuple[float, float, bool]:
    """(max residual px, span, ok) for one clip's transform."""
    speed = float(clip.speed or 1.0)
    # The clip walks `speed` source frames per output frame, so the input needs
    # enough of them for the zoom crop's `n` to advance the way it will in the
    # real bake (which feeds the shot's whole frame range).
    n_in = max(frames, int(frames * speed) + 2)
    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        for i in range(n_in):
            _marker_frame((1920, 1080), point).save(tdp / f"{i:04d}.png")
        graph = ffmpeg.clip_filter(
            region=list(src.crop), zoom=list(clip.zoom) if clip.zoom else None,
            out_frames=frames, fit=fit, fps=proj.fps, duration=frames / proj.fps,
            fade_in=0.0, fade_out=0.0, has_overlay=False,
            zoom_span=max(src.span_src, 1))
        out = tdp / "out"
        out.mkdir()
        cmd = ["ffmpeg", "-v", "error", "-y", "-framerate", str(proj.fps),
               "-i", str(tdp / "%04d.png"), "-filter_complex", graph,
               "-map", "[vout]", "-frames:v", str(frames), str(out / "%04d.png")]
        subprocess.run(cmd, check=True)
        mapper = draw.make_mapper(tuple(src.crop), (proj.width, proj.height),
                                  tuple(clip.zoom) if clip.zoom else None,
                                  max(src.span_src, 1),
                                  (fit.x, fit.y, fit.box_w, fit.box_h), fit.mode)
        frames_out = sorted(out.glob("*.png"))
        if len(frames_out) < frames:
            print(f"  (ffmpeg produced {len(frames_out)} frames)")
            return (999.0, 0.0, False)
        worst = 0.0
        span = 0.0
        measured = 0
        for i in range(frames):
            img = Image.open(frames_out[i])
            want = mapper(float(point[0]), float(point[1]), i * speed)
            inside = 0 <= want[0] < img.width and 0 <= want[1] < img.height
            found = _find_marker(img)
            if found is None:
                # Not visible: fine ONLY if the mapper also puts it off-frame.
                if inside:
                    print(f"  {clip.id}: marker missing at frame {i}, mapper says {want}")
                    return (999.0, 0.0, False)
                continue
            measured += 1
            span = max(span, abs(found[0] - want[0]) + abs(found[1] - want[1]))
            worst = max(worst, ((found[0] - want[0]) ** 2 + (found[1] - want[1]) ** 2) ** 0.5)
        if measured == 0:
            return (0.0, 0.0, True)      # off-frame for the whole clip
        return worst, span, worst <= 2.0


def check_hotspot() -> tuple[int, int]:
    """Draw the sprite at a known point and measure where its tip landed."""
    canvas = Image.new("RGBA", (200, 120), (0, 0, 0, 0))
    draw.draw_cursor(canvas, (100.0, 60.0), height=46)
    alpha = canvas.getchannel("A")
    for y in range(canvas.height):
        for x in range(canvas.width):
            if alpha.getpixel((x, y)) > 40:
                return (x - 100, y - 60)
    return (0, 0)


def main(argv: list[str]) -> int:
    proj = edl.load(build.DEFAULT_EDL)
    failures = 0
    tip = check_hotspot()
    # A correct hotspot means the sprite's tip lands ON the requested point.
    print(f"[hotspot] drawn tip offset {tip} (want (0, 0))")
    if abs(tip[0]) + abs(tip[1]) > 2:
        failures += 1
        print("  FAIL the cursor sprite is not drawn at the requested point")
    print(f"{'clip':22} {'mode':8} {'zoom':>6} {'into':>6}  residual")
    for clip in proj.clips:
        if argv and clip.id not in argv:
            continue
        if clip.kind not in ("card", "session") and not str(clip.source or "").startswith(("edit:", "create:", "map:", "paint:", "shapes:", "smoke:")):
            continue
        try:
            src = build.resolve(clip, proj)
        except Exception:
            continue
        if src.session is None:
            continue
        clicks = build.clicks_for(src, clip)
        rx, ry, rw, rh = src.crop
        # Only clicks INSIDE the clip's crop have a pixel to land on; the overlaid
        # cursor is skipped for the others (see overlay.render_frame).
        clicks = [c for c in clicks if rx <= c[1] < rx + rw and ry <= c[2] < ry + rh]
        if not clicks:
            continue
        fit = build.fit_for(clip, proj)
        point = (clicks[0][1], clicks[0][2])
        residual, _span, ok = check_mapper(clip, proj, src, fit, point)
        mode = fit.mode if clip.into else "full"
        into = "yes" if clip.into else "-"
        zoom = "yes" if clip.zoom else "-"
        print(f"{clip.id:22} {mode:8} {zoom:>6} {into:>6}  {residual:6.2f} px  {'ok' if ok else 'FAIL'}")
        if not ok:
            failures += 1
    print(f"[cursor] {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
