"""Review strips: what a beat DOES over time, in one image.

The review sheet (one frame per clip) cannot show the failures the owner kept
finding by watching: a texture that never starts scrolling, a cut that lands
before the action finishes, a panel hidden under a caption. A strip shows a
clip as N timestamped frames, ALWAYS including its last frame (so an early
cut is visible), and an optional motion row under it: the difference to the
frame `--gap` seconds earlier, brightened, so "nothing moves here" reads at
a glance (a scrolling sheet glows; a frozen one is black).

  # a recorded shot (source frames, full window or a crop)
  python -m showcase.strip shot v2_surface v2s/scroll [--n 10] [--crop x,y,w,h]
                                  [--from 3.0 --to 4.0]  (find exact in/out points)
  # a BUILT clip segment (what the viewer sees: crop, captions, cursor)
  python -m showcase.strip seg l42-scroll [--motion]
  # every clip of an EDL, one strip per clip, into one directory
  python -m showcase.strip edl showcase_video/edl_v2.toml [--only s11-edge,...]

Strips land in showcase_video/bake/strips/ (printed). Read them with the
image viewer (the Read tool) — one image per beat, not a scrubbed video.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parents[3]
BAKE = REPO / "showcase_video" / "bake"
OUT = BAKE / "strips"
FONT = REPO / "showcase_video" / "fonts"
TILE_W = 384


def _font(size: int):
    for f in sorted(FONT.glob("*.ttf")) + sorted(FONT.glob("*.otf")):
        try:
            return ImageFont.truetype(str(f), size)
        except OSError:
            continue
    return ImageFont.load_default()


def _pick(n_frames: int, n: int) -> list[int]:
    """n indices spread over [0, n_frames-1], first and LAST always included."""
    if n_frames <= n:
        return list(range(n_frames))
    return [round(i * (n_frames - 1) / (n - 1)) for i in range(n)]


def _label(im: Image.Image, text: str) -> None:
    d = ImageDraw.Draw(im)
    f = _font(15)
    box = d.textbbox((0, 0), text, font=f)
    d.rectangle((0, 0, box[2] + 8, box[3] + 6), fill=(0, 0, 0))
    d.text((4, 2), text, fill=(255, 220, 0), font=f)


def _motion(a: Image.Image, b: Image.Image) -> Image.Image:
    d = ImageChops.difference(a.convert("RGB"), b.convert("RGB")).convert("L")
    # x6: a slow scroll or a 1-px slide still shows; static UI stays black.
    return d.point(lambda v: min(255, v * 6)).convert("RGB")


def build_strip(frames: list[Image.Image], times: list[float], prev: list[Image.Image | None],
                title: str, out: Path, cols: int) -> Path:
    tiles = []
    for im, t in zip(frames, times):
        tile = im.convert("RGB")
        tile = tile.resize((TILE_W, round(tile.height * TILE_W / tile.width)), Image.LANCZOS)
        _label(tile, f"{t:5.2f}s")
        tiles.append(tile)
    mtiles = []
    if any(p is not None for p in prev):
        for im, p in zip(frames, prev):
            m = _motion(im, p) if p is not None else Image.new("RGB", im.size)
            m = m.resize(tiles[0].size, Image.BILINEAR)
            _label(m, "motion")
            mtiles.append(m)
    th = tiles[0].height
    rows_f = (len(tiles) + cols - 1) // cols
    per_row = 2 if mtiles else 1
    W = cols * (TILE_W + 2)
    H = 28 + rows_f * per_row * (th + 2)
    sheet = Image.new("RGB", (W, H), (24, 24, 24))
    ImageDraw.Draw(sheet).text((6, 5), title, fill=(230, 230, 230), font=_font(17))
    for i, tile in enumerate(tiles):
        r, c = divmod(i, cols)
        y = 28 + r * per_row * (th + 2)
        sheet.paste(tile, (c * (TILE_W + 2), y))
        if mtiles:
            sheet.paste(mtiles[i], (c * (TILE_W + 2), y + th + 2))
    # The last tile is the cut point: frame it so an early cut is unmissable.
    r, c = divmod(len(tiles) - 1, cols)
    y = 28 + r * per_row * (th + 2)
    ImageDraw.Draw(sheet).rectangle((c * (TILE_W + 2), y, c * (TILE_W + 2) + TILE_W - 1, y + th - 1),
                                    outline=(255, 60, 60), width=3)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    return out


def strip_shot(session: str, shot: str, n: int, crop: list[int] | None, gap: float,
               motion: bool, cols: int, t0: float = 0.0, t1: float = -1.0) -> Path:
    slug = shot.replace("/", "_").replace(" ", "_").replace("-", "_")
    d = BAKE / session / "shots" / slug / "frames"
    files = sorted(d.glob("*.png"))
    if not files:
        sys.exit(f"no frames in {d}")
    lo = max(0, round(t0 * 60))
    hi = len(files) - 1 if t1 < 0 else min(len(files) - 1, round(t1 * 60))
    idx = [lo + i for i in _pick(hi - lo + 1, n)]
    k = max(1, round(gap * 60))

    def load(i):
        im = Image.open(files[i])
        return im.crop((crop[0], crop[1], crop[0] + crop[2], crop[1] + crop[3])) if crop else im

    frames = [load(i) for i in idx]
    prev = [load(i - k) if motion and i - k >= 0 else None for i in idx]
    out = OUT / f"shot-{session}-{slug}.png"
    title = f"{session}:{shot}  {len(files)} frames ({len(files) / 60:.2f}s)  red = last frame"
    return build_strip(frames, [i / 60 for i in idx], prev, title, out, cols)


def _video_frames(path: Path, times: list[float]) -> list[Image.Image]:
    out = []
    with tempfile.TemporaryDirectory() as td:
        for j, t in enumerate(times):
            f = Path(td) / f"{j}.png"
            # A seek at the very end can decode nothing: step back a frame
            # at a time (the "last frame" is the last DECODABLE one).
            for back in range(8):
                subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{max(0.0, t - back / 60):.3f}",
                                "-i", str(path), "-frames:v", "1", str(f)], check=True)
                if f.exists():
                    break
            out.append(Image.open(f).copy())
    return out


def _duration(path: Path) -> float:
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                        str(path)], capture_output=True, text=True, check=True)
    return float(r.stdout.strip())


def strip_video(path: Path, n: int, gap: float, motion: bool, cols: int, name: str) -> Path:
    dur = _duration(path)
    last = max(0.0, dur - 1.0 / 60)
    times = [last * i / (n - 1) for i in range(n)]
    frames = _video_frames(path, times)
    prev = _video_frames(path, [t - gap for t in times]) if motion else [None] * n
    if motion:
        prev = [p if t - gap >= 0 else None for p, t in zip(prev, times)]
    out = OUT / f"{name}.png"
    return build_strip(frames, times, prev, f"{name}  {dur:.2f}s  red = last frame (the cut)", out, cols)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="showcase.strip")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("shot")
    a.add_argument("session")
    a.add_argument("shot")
    a.add_argument("--crop", default="", help="x,y,w,h in window pixels")
    a.add_argument("--from", dest="t0", type=float, default=0.0, help="seconds into the take")
    a.add_argument("--to", dest="t1", type=float, default=-1.0, help="seconds into the take (default: end)")
    b = sub.add_parser("seg")
    b.add_argument("clip_id")
    c = sub.add_parser("edl")
    c.add_argument("edl")
    c.add_argument("--only", default="")
    for p in (a, b, c):
        p.add_argument("--n", type=int, default=10)
        p.add_argument("--cols", type=int, default=5)
        p.add_argument("--motion", action="store_true", help="add a frame-difference row")
        p.add_argument("--gap", type=float, default=0.25, help="motion: seconds between compared frames")
    args = ap.parse_args(argv)

    if args.cmd == "shot":
        crop = [int(v) for v in args.crop.split(",")] if args.crop else None
        print(strip_shot(args.session, args.shot, args.n, crop, args.gap, args.motion, args.cols,
                         args.t0, args.t1))
    elif args.cmd == "seg":
        seg = BAKE / "segments" / f"{args.clip_id}.mp4"
        print(strip_video(seg, args.n, args.gap, args.motion, args.cols, f"seg-{args.clip_id}"))
    else:
        from . import edl as edl_mod
        proj = edl_mod.load(Path(args.edl))
        only = set(filter(None, args.only.split(",")))
        for clip in proj.clips:
            if only and clip.id not in only:
                continue
            seg = BAKE / "segments" / f"{clip.id}.mp4"
            if not seg.exists():
                print(f"  (no segment for {clip.id}; build it first)")
                continue
            print(strip_video(seg, args.n, args.gap, args.motion, args.cols, f"seg-{clip.id}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
