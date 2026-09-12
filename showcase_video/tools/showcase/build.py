"""The build CLI: bake clips, concat the master, encode the deliverables, verify.

    ./showcase_video/build.sh                 # everything
    ./showcase_video/build.sh --only a,b      # rebuild two clips (and the master)
    ./showcase_video/build.sh --list          # what the EDL contains
    ./showcase_video/build.sh --preview x     # 2-second preview of one clip
    ./showcase_video/build.sh --verify        # check the finished master
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from . import capture, draw, edl, ffmpeg, overlay

REPO = Path(__file__).resolve().parents[3]
BAKE = REPO / "showcase_video" / "bake"
DEFAULT_EDL = REPO / "showcase_video" / "edl.toml"


class BuildError(Exception):
    pass


@dataclass
class Source:
    """A clip's resolved input."""

    input_args: list[str]
    out_frames: int
    crop: tuple[int, int, int, int]
    span_src: int                       # source frames the clip walks through
    session: capture.Session | None = None
    shot: capture.Shot | None = None
    first_frame: int = 0                # first source frame inside the shot
    still: bool = False
    label: str = ""


def _session(name: str) -> capture.Session:
    return capture.Session(name, BAKE / name)


def resolve_media(path: str) -> Path:
    """Locate an external source file.

    Absolute paths are used as given. A relative name is looked up in
    showcase_video/source/ first — where footage is dropped without editing the
    EDL — and if the named file is not there, the NEWEST video in that directory
    is used instead, so a fresh capture can replace the shipped one by simply
    being dropped in.
    """
    p = Path(path)
    if p.is_absolute():
        return p
    src_dir = REPO / "showcase_video" / "source"
    named = src_dir / path
    if named.exists():
        return named
    if src_dir.is_dir():
        cands = sorted(
            (f for f in src_dir.iterdir()
             if f.suffix.lower() in (".mp4", ".mov", ".mkv", ".webm", ".m4v")),
            key=lambda f: f.stat().st_mtime, reverse=True)
        if cands:
            print(f"[media] {path} not found in {src_dir}; "
                  f"using the newest capture there: {cands[0].name}")
            return cands[0]
    for base in (REPO, Path.cwd()):
        cand = base / path
        if cand.exists():
            return cand
    return p


def resolve(clip: edl.Clip, proj: edl.Project, preview_seconds: float = 0.0) -> Source:
    fps = proj.fps
    dur = clip.dur or 0.0
    if preview_seconds > 0:
        dur = min(dur if dur else preview_seconds, preview_seconds)
    out_frames = max(1, int(round(dur * fps)))

    if clip.kind == "frames":
        sess_name, _, shot_name = clip.source.partition(":")
        sess = _session(sess_name)
        shot = sess.shot(shot_name)
        # `at` counts from the shot's start; a NEGATIVE `at` counts back from its
        # end (-2.0 = the last two seconds), which is how most beats are cut:
        # the setup is at the head, the payoff at the tail.
        first = int(round(clip.at * fps))
        if clip.at < 0:
            first = max(0, shot.frames - int(round(-clip.at * fps)))
        avail = shot.frames - first
        crop = tuple(clip.crop) if clip.crop else tuple(
            shot.region(clip.region) if clip.region else sess.data["regions"]["window"])
        need = int(round(out_frames * clip.speed))
        if need > avail:
            raise BuildError(
                f"clip '{clip.id}': wants {need} source frames from {clip.source} "
                f"but only {avail} are available (shot has {shot.frames} frames, "
                f"at={clip.at}s) — shorten dur or lengthen the shot")
        return Source(
            input_args=["-framerate", str(fps), "-start_number", str(first),
                        "-i", str(sess.frames_dir(shot) / "%06d.png")],
            out_frames=out_frames,
            crop=crop,                      # type: ignore[arg-type]
            span_src=need,
            session=sess, shot=shot, first_frame=first,
            label=f"{sess_name}:{shot_name}",
        )

    if clip.kind == "video":
        path = resolve_media(clip.file)
        if not path.exists():
            raise BuildError(f"clip '{clip.id}': missing source video {path}")
        st = ffmpeg.video_stream(path)
        crop = tuple(clip.crop) if clip.crop else (0, 0, int(st["width"]), int(st["height"]))
        return Source(
            input_args=["-ss", f"{clip.at:.3f}", "-i", str(path), "-t", f"{dur:.3f}"],
            out_frames=out_frames,
            crop=crop,                      # type: ignore[arg-type]
            span_src=out_frames,
            label=str(path.name),
        )

    if clip.kind == "card":
        W, H = proj.width, proj.height
        # Rendered oversized so the optional push-in never softens the type.
        cw, ch = int(W * 1.45), int(H * 1.45)
        img = draw.card_background(
            cw, ch,
            clip.card.get("title", ""),
            clip.card.get("sub", ""),
            clip.card.get("kicker", ""),
            tuple(clip.card.get("bullets", [])),
        )
        cdir = BAKE / "cards"
        cdir.mkdir(parents=True, exist_ok=True)
        cpath = cdir / f"{draw.slug(clip.id)}.png"
        img.convert("RGB").save(cpath)
        return Source(
            input_args=["-loop", "1", "-framerate", str(fps), "-i", str(cpath), "-t", f"{dur:.3f}"],
            out_frames=out_frames,
            crop=(0, 0, cw, ch),
            span_src=out_frames,
            still=True,
            label=str(cpath.name),
        )

    raise BuildError(f"clip '{clip.id}': unknown kind {clip.kind!r}")


def _even(v: int) -> int:
    """libx264 requires even dimensions; round down and never below 2."""
    return max(2, int(v) - (int(v) % 2))


def fingerprint(clip: edl.Clip, proj: edl.Project, src: Source) -> str:
    """A hash of everything that decides what a segment looks like.

    Stored next to the segment: a re-cut (crop, window, caption, grade) or a
    re-recorded source must rebuild it, and "the file exists" cannot see either.
    """
    import dataclasses
    import hashlib
    payload = {
        "clip": dataclasses.asdict(clip),
        "frame": [proj.width, proj.height, proj.fps],
        "source": src.label,
        "out_frames": src.out_frames,
        "first": src.first_frame,
        "crop": src.crop,
        "span": src.span_src,
    }
    if src.shot is not None:
        payload["shot"] = [src.shot.directory, src.shot.frames]
    elif clip.kind == "video":
        f = resolve_media(clip.file)
        if f.exists():
            st = f.stat()
            payload["file"] = [str(f), int(st.st_mtime), st.st_size]
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()[:20]


def _stamp(seg: Path) -> Path:
    return seg.with_suffix(seg.suffix + ".stamp")


def segment_is_current(clip: edl.Clip, proj: edl.Project, seg: Path) -> bool:
    if not seg.exists():
        return False
    stamp = _stamp(seg)
    if not stamp.exists():
        return False
    try:
        src = resolve(clip, proj)
    except Exception:
        return True                     # cannot resolve: leave it to the bake
    return stamp.read_text().strip() == fingerprint(clip, proj, src)


def fit_for(clip: edl.Clip, proj: edl.Project) -> ffmpeg.Fit:
    if clip.into:
        x, y, w, h = clip.into
        return ffmpeg.Fit(proj.width, proj.height, _even(w), _even(h),
                          _even(x), _even(y), clip.fit, clip.bg)
    return ffmpeg.Fit(proj.width, proj.height, proj.width, proj.height,
                      0, 0, clip.fit, clip.bg)


def clicks_for(src: Source, clip: edl.Clip) -> list[tuple[int, int, int]]:
    if not src.session or src.shot is None or not clip.cursor:
        return []
    return [c for c in src.session.clicks(src.shot)
            if src.first_frame - 2 <= c[0] < src.first_frame + src.span_src + 4]


def bake_clip(clip: edl.Clip, proj: edl.Project, workers: int = 0,
              preview_seconds: float = 0.0) -> Path:
    src = resolve(clip, proj, preview_seconds)
    fit = fit_for(clip, proj)
    seg_dir = BAKE / "segments"
    seg_dir.mkdir(parents=True, exist_ok=True)
    out = seg_dir / f"{draw.slug(clip.id)}.mp4"
    dur = src.out_frames / proj.fps
    zoom = list(clip.zoom) if clip.zoom else None

    overlay_dir: Path | None = None
    needs_overlay = clip.cursor or bool(clip.captions) or bool(clip.frame)
    if needs_overlay:
        plan = overlay.plan_overlay(clip, src.session, src.shot, src.crop,
                                    (proj.width, proj.height),
                                    src.first_frame, src.out_frames,
                                    clicks_for(src, clip),
                                    (fit.x, fit.y, fit.box_w, fit.box_h),
                                    fit.mode)
        plan.zoom_span = src.span_src
        overlay_dir = BAKE / "overlays" / draw.slug(clip.id)
        n = overlay.render_sequence(plan, overlay_dir, workers=workers)
        print(f"  overlay: {n} frames -> {overlay_dir}")

    graph = ffmpeg.clip_filter(
        region=list(src.crop),
        zoom=zoom,
        out_frames=src.out_frames,
        fit=fit,
        fps=proj.fps,
        duration=dur,
        fade_in=clip.fade_in,
        fade_out=clip.fade_out,
        has_overlay=overlay_dir is not None,
        grade=clip.grade or None,
        zoom_span=src.span_src,
    )
    cmd = [ffmpeg.ffmpeg(), "-hide_banner", "-loglevel", "error", "-y"]
    cmd += src.input_args
    if overlay_dir is not None:
        cmd += ["-framerate", str(proj.fps), "-start_number", "1",
                "-i", str(overlay_dir / "%06d.png")]
    cmd += ["-filter_complex", graph, "-map", "[vout]",
            "-frames:v", str(src.out_frames),
            "-c:v", "libx264", "-crf", "14", "-preset", "veryfast",
            "-pix_fmt", "yuv420p", "-r", str(proj.fps),
            "-g", "120", "-keyint_min", "60", "-sc_threshold", "0",
            str(out)]
    print(f"[clip] {clip.id}  ({src.label}, {src.out_frames} frames, {dur:.2f}s)")
    ffmpeg.run(cmd)
    _stamp(out).write_text(fingerprint(clip, proj, src))
    return out


def concat(segments: list[Path], out: Path) -> Path:
    out.parent.mkdir(parents=True, exist_ok=True)
    listfile = out.parent / "segments.txt"
    listfile.write_text("".join(f"file '{s.resolve()}'\n" for s in segments))
    ffmpeg.run([ffmpeg.ffmpeg(), "-hide_banner", "-loglevel", "error", "-y",
                "-f", "concat", "-safe", "0", "-i", str(listfile),
                "-c", "copy", "-movflags", "+faststart", str(out)])
    return out


def encode_readme(master: Path, out: Path, proj: edl.Project) -> Path:
    out.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg.run([ffmpeg.ffmpeg(), "-hide_banner", "-loglevel", "error", "-y",
                "-i", str(master),
                "-vf", f"scale={proj.readme_width}:{proj.readme_height}:flags=lanczos",
                "-c:v", "libx264", "-crf", "26", "-preset", "slower",
                "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                "-an", str(out)])
    return out


def poster(master: Path, out: Path, at: float) -> Path:
    out.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg.run([ffmpeg.ffmpeg(), "-hide_banner", "-loglevel", "error", "-y",
                "-ss", f"{at:.3f}", "-i", str(master), "-frames:v", "1", str(out)])
    return out


# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------

def verify(master: Path, proj: edl.Project) -> bool:
    ok = True
    dur = ffmpeg.duration(master)
    expected = sum(c.dur or 0.0 for c in proj.clips)
    print(f"[verify] master {dur:.2f}s (EDL says {expected:.2f}s), "
          f"{ffmpeg.frames_of(master)} frames")
    if abs(dur - expected) > 0.35:
        print(f"[verify] FAIL: duration off by {abs(dur - expected):.2f}s")
        ok = False

    vs = ffmpeg.video_stream(master)
    if (int(vs["width"]), int(vs["height"])) != (proj.width, proj.height):
        print(f"[verify] FAIL: size {vs['width']}x{vs['height']} != {proj.width}x{proj.height}")
        ok = False

    # Sample stills across the timeline: every one must have real content
    # (not a black or frozen frame).
    stills = BAKE / "verify"
    stills.mkdir(parents=True, exist_ok=True)
    prev: Image.Image | None = None
    for i in range(12):
        t = dur * (i + 0.5) / 12.0
        p = stills / f"sample_{i:02d}.png"
        ffmpeg.run([ffmpeg.ffmpeg(), "-hide_banner", "-loglevel", "error", "-y",
                    "-ss", f"{t:.2f}", "-i", str(master), "-frames:v", "1", str(p)])
        img = Image.open(p).convert("RGB").resize((160, 90))
        px = list(img.getdata() if hasattr(img, 'getdata') else [])
        mean = sum(sum(p) for p in px) / (len(px) * 3)
        if mean < 6:
            print(f"[verify] FAIL: frame at {t:.1f}s is black (mean {mean:.1f})")
            ok = False
        if prev is not None:
            diff = sum(abs(a[0] - b[0]) for a, b in zip(px, list(prev.getdata()))) / max(len(px), 1)
            if diff < 0.5:
                print(f"[verify] WARN: frames at {t:.1f}s look identical to the previous sample")
        prev = img
    return ok


# ---------------------------------------------------------------------------
# cli
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="showcase build")
    ap.add_argument("--edl", default=str(DEFAULT_EDL))
    ap.add_argument("--only", default="", help="comma-separated clip ids")
    ap.add_argument("--from", dest="start_at", default="", help="start at this clip id")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--preview", default="", help="render N-second previews of the clips")
    ap.add_argument("--preview-clips", default="", help="limit --preview to these ids")
    ap.add_argument("--concat", action="store_true", help="only re-concat existing segments")
    ap.add_argument("--clips-only", action="store_true",
                    help="bake the selected clips and stop (no master)")
    ap.add_argument("--verify", action="store_true", help="only verify the existing master")
    ap.add_argument("--workers", type=int, default=0)
    args = ap.parse_args(argv)

    proj = edl.load(args.edl)
    out_dir = REPO / "showcase_video" / proj.out_dir
    master = out_dir / proj.master

    if args.list:
        total = 0.0
        for c in proj.clips:
            print(f"  {c.id:34s} {c.kind:7s} {c.dur or 0:6.2f}s  {c.source or c.file or 'card'}")
            total += c.dur or 0.0
        print(f"  {'TOTAL':34s} {'':7s} {total:6.2f}s "
              f"({total * proj.fps:.0f} frames at {proj.fps} fps)")
        return 0

    if args.verify:
        return 0 if verify(master, proj) else 1

    only = {s.strip() for s in args.only.split(",") if s.strip()}

    if args.preview:
        secs = float(args.preview)
        clips = [c for c in proj.clips if not only or c.id in only]
        if args.preview_clips:
            want = {s.strip() for s in args.preview_clips.split(",")}
            clips = [c for c in clips if c.id in want]
        for c in clips:
            try:
                bake_clip(c, proj, args.workers, preview_seconds=secs)
            except BuildError as e:
                print(f"  skip {c.id}: {e}")
        return 0

    segments: list[Path] = []
    failed: list[str] = []
    for c in proj.clips:
        seg = BAKE / "segments" / f"{draw.slug(c.id)}.mp4"
        if only:
            need = c.id in only
        elif args.concat:
            need = False
        else:
            need = not segment_is_current(c, proj, seg)
        if need:
            try:
                seg = bake_clip(c, proj, args.workers)
            except BuildError as e:
                print(f"[error] {e}")
                failed.append(c.id)
        if not seg.exists():
            if args.clips_only:
                continue
            print(f"[error] clip '{c.id}' has no segment; the master would be incomplete")
            return 1
        segments.append(seg)

    if failed:
        print(f"[error] {len(failed)} clip(s) failed: {failed}")
        return 1

    if args.clips_only:
        print(f"[clips] {len(segments)} segment(s) baked")
        return 0

    concat(segments, master)
    print(f"[master] {master}")

    readme = encode_readme(master, out_dir / proj.readme, proj)
    print(f"[readme] {readme}")
    p = poster(master, out_dir / proj.poster, min(4.0, ffmpeg.duration(master) / 3))
    print(f"[poster] {p}")

    print(f"[size] master {master.stat().st_size / 1e6:.1f} MB, "
          f"readme {readme.stat().st_size / 1e6:.1f} MB")

    ok = verify(master, proj)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
