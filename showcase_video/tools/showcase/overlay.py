"""Rendering a clip's overlay frame sequence: captions, cursor, click ripples.

One RGBA PNG per output frame at the output resolution. ffmpeg then composites
the sequence over the (cropped, scaled) capture, so the overlay is always
pixel-exact and costs nothing to restyle.
"""

from __future__ import annotations

from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from . import draw
from .capture import Session
from .edl import Caption, Clip


@dataclass
class OverlayPlan:
    """Everything a worker needs to draw one frame (picklable)."""

    session_dir: str
    shot_dir: str
    clip_id: str
    region: tuple[int, int, int, int]
    out_size: tuple[int, int]
    zoom: tuple[float, float] | None
    first_frame: int            # first source frame of the clip
    speed: float
    frames: int                 # output frames
    captions: list[Caption]
    cursor: bool
    clicks: list[tuple[int, int, int]]   # (source frame, x, y)
    # Source frames the clip walks through (out_frames * speed); the zoom
    # progress and the cursor mapping are both indexed by SOURCE frame, which
    # is what the ffmpeg crop expression sees.
    zoom_span: int = 0
    frame_style: str = ""
    frame_rect: tuple[int, int, int, int] = (0, 0, 0, 0)
    # "cover" or "contain" — part of the mapping, because a letterboxed clip
    # scales to FIT its box while a covering one scales to FILL it.
    fit_mode: str = "cover"


def plan_overlay(clip: Clip, session: Session | None, shot, crop: tuple[int, int, int, int],
                 out_size: tuple[int, int], first: int, frames: int,
                 clicks: list[tuple[int, int, int]],
                 frame_rect: tuple[int, int, int, int] = (0, 0, 0, 0),
                 fit_mode: str = "cover") -> OverlayPlan:
    return OverlayPlan(
        session_dir=str(session.root) if session is not None else "",
        shot_dir=shot.directory if shot is not None else "",
        clip_id=clip.id,
        region=crop,
        out_size=out_size,
        zoom=tuple(clip.zoom) if clip.zoom else None,  # type: ignore[arg-type]
        first_frame=first,
        speed=clip.speed,
        frames=frames,
        captions=list(clip.captions),
        cursor=clip.cursor and session is not None,
        clicks=clicks,
        frame_style=clip.frame,
        frame_rect=frame_rect,
        fit_mode=fit_mode,
    )


def caption_alpha(cap: Caption, t: float, clip_dur: float) -> tuple[float, float]:
    """(alpha, slide) for a caption at clip-local time t (seconds)."""
    start = cap.at
    end = clip_dur if cap.dur is None else min(clip_dur, cap.at + cap.dur)
    if t < start or t > end:
        return 0.0, 0.0
    fade = max(0.001, min(cap.fade, (end - start) / 2.0))
    a_in = draw.clamp01((t - start) / fade)
    a_out = draw.clamp01((end - t) / fade)
    a = min(a_in, a_out)
    slide = (1.0 - draw.ease_out(a_in)) * 10.0 if a_in < 1.0 else 0.0
    return a, slide


def render_frame(plan: OverlayPlan, index: int, cursors: list[tuple[int, int]]) -> Image.Image:
    W, H = plan.out_size
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    fps = 60.0
    t = index / fps
    clip_dur = plan.frames / fps
    src = plan.first_frame + int(round(index * plan.speed))

    map_pt = draw.make_mapper(plan.region, plan.out_size, plan.zoom,
                              plan.zoom_span or plan.frames)

    if plan.frame_style and plan.frame_rect != (0, 0, 0, 0):
        canvas.alpha_composite(draw.frame_layer(plan.frame_rect, (W, H), 22))

    for cap in plan.captions:
        a, slide = caption_alpha(cap, t, clip_dur)
        if a <= 0.001:
            continue
        layer = draw.caption_layer(cap.text, cap.sub, cap.label, W, H, cap.style)
        if a < 0.999:
            layer = layer.copy()
            alpha = layer.getchannel("A").point(lambda v: int(v * a))
            layer.putalpha(alpha)
        x, y = draw.place(layer, (W, H), cap.pos, 44)
        canvas.alpha_composite(layer, (int(x), int(y + slide)))

    if plan.cursor:
        wx, wy = cursors[index] if index < len(cursors) else (0, 0)
        rx, ry, rw, rh = plan.region
        # A click recorded OUTSIDE the clip's crop (a toolbar click on a clip that
        # only shows the viewport) has no pixel to sit on: drawing it anyway put a
        # stray cursor on the frame's edge.
        if not (rx <= wx < rx + rw and ry <= wy < ry + rh):
            return canvas
        px, py = map_pt(float(wx), float(wy), index * plan.speed)
        if -80 < px < W + 80 and -80 < py < H + 80:
            click = 0.0
            for (cf, _x, _y) in plan.clicks:
                age = (src - cf) / max(plan.speed, 1e-6)
                if 0 <= age <= 24:
                    click = max(click, draw.ripple_alpha(age, 24.0))
            idle = draw.soft_pulse(abs(src - plan.clicks[-1][0]) if plan.clicks else 0.0)
            draw.draw_cursor(canvas, (px, py), height=max(30, int(H * 0.064)),
                             glow=0.35 + 0.5 * click, click=click)
    return canvas


def _render_chunk(args: tuple[OverlayPlan, int, int, str, int]) -> int:
    plan, start, count, out_dir, shard = args
    cursors: list[tuple[int, int]] = []
    if plan.session_dir and plan.shot_dir:
        # Opened per worker: a Session is not picklable, and each process
        # memory-maps the cursor track for itself.
        session = Session("worker", Path(plan.session_dir))
        shot = session.shot_by_dir(plan.shot_dir)
        if shot is not None:
            cursors = session.cursor_range(shot, plan.first_frame, plan.frames, plan.speed)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for i in range(start, start + count):
        img = render_frame(plan, i, cursors)
        img.save(out / f"{i + 1:06d}.png")
    return count


def render_sequence(plan: OverlayPlan, out_dir: str | Path, workers: int = 0,
                    progress: bool = True) -> int:
    """Write the whole overlay sequence; returns the frame count."""
    import os

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.png"):
        old.unlink()
    if workers <= 0:
        workers = max(1, min(os.cpu_count() or 4, 8))
    n = plan.frames
    if n == 0:
        return 0
    chunk = max(1, n // (workers * 4))
    jobs = []
    i = 0
    shard = 0
    while i < n:
        c = min(chunk, n - i)
        jobs.append((plan, i, c, str(out_dir), shard))
        i += c
        shard += 1
    if workers == 1 or len(jobs) == 1:
        done = 0
        for job in jobs:
            done += _render_chunk(job)
        return done
    done = 0
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for k, res in enumerate(pool.map(_render_chunk, jobs), start=1):
            done += res
            if progress and k % 4 == 0:
                print(f"    overlay {done}/{n}", flush=True)
    return done
