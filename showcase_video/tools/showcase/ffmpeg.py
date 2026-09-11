"""ffmpeg plumbing: binary resolution, filtergraph assembly, running, probing.

The toolchain is resolved self-contained-first: a vendored binary under
``showcase_video/tools/ffmpeg/`` wins, then ``$SHOWCASE_FFMPEG``, then whatever
is on PATH. Nothing here requires a system-wide install.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
TOOLS_DIR = REPO_ROOT / "showcase_video" / "tools"


class FfmpegError(Exception):
    pass


def _find(name: str) -> str:
    override = os.environ.get("SHOWCASE_" + name.upper())
    if override:
        return override
    vendored = TOOLS_DIR / "ffmpeg" / name
    if vendored.exists():
        return str(vendored)
    found = shutil.which(name)
    if found:
        return found
    raise FfmpegError(
        f"{name} not found: install it, drop a static build into "
        f"{TOOLS_DIR / 'ffmpeg'}, or set SHOWCASE_{name.upper()}")


def ffmpeg() -> str:
    return _find("ffmpeg")


def ffprobe() -> str:
    return _find("ffprobe")


@dataclass
class RunResult:
    cmd: list[str]
    stdout: str
    stderr: str
    code: int

    @property
    def ok(self) -> bool:
        return self.code == 0


def run(cmd: list[str], quiet: bool = False, echo: bool = False) -> RunResult:
    if echo or os.environ.get("SHOWCASE_ECHO"):
        print("$ " + " ".join(cmd), flush=True)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    res = RunResult(cmd=cmd, stdout=proc.stdout, stderr=proc.stderr, code=proc.returncode)
    if not res.ok:
        tail = "\n".join(res.stderr.strip().splitlines()[-25:])
        raise FfmpegError(f"ffmpeg failed ({res.code}):\n{tail}\n$ {' '.join(cmd)}")
    if not quiet:
        for line in res.stderr.splitlines():
            if line.strip():
                print("  " + line.strip()[:180], flush=True)
    return res


# ---------------------------------------------------------------------------
# probing
# ---------------------------------------------------------------------------

def probe(path: str | Path) -> dict:
    res = subprocess.run(
        [ffprobe(), "-v", "error", "-print_format", "json",
         "-show_format", "-show_streams", str(path)],
        capture_output=True, text=True)
    if res.returncode != 0:
        raise FfmpegError(f"ffprobe failed on {path}: {res.stderr.strip()}")
    return json.loads(res.stdout)


def video_stream(path: str | Path) -> dict:
    data = probe(path)
    for s in data.get("streams", []):
        if s.get("codec_type") == "video":
            return s
    raise FfmpegError(f"no video stream in {path}")


def duration(path: str | Path) -> float:
    return float(probe(path)["format"].get("duration", 0.0))


def frames_of(path: str | Path) -> int:
    s = video_stream(path)
    if "nb_frames" in s and s["nb_frames"] not in ("N/A", None):
        return int(s["nb_frames"])
    d = duration(path)
    num, _, den = s.get("avg_frame_rate", "0/1").partition("/")
    fps = float(num) / float(den or 1) if float(den or 1) else 0.0
    return int(round(d * fps))


# ---------------------------------------------------------------------------
# filter assembly
# ---------------------------------------------------------------------------

@dataclass
class Fit:
    """Where a clip's picture lands inside the output frame.

    ``box_w``/``box_h`` is the rectangle the picture is fitted into, ``x``/``y``
    where that box sits in the frame, and ``frame_w``/``frame_h`` the output
    frame itself (the pad target, filled with ``bg``).
    """

    frame_w: int
    frame_h: int
    box_w: int
    box_h: int
    x: int = 0
    y: int = 0
    mode: str = "cover"       # cover → fill the box, cropping overflow; contain → letterbox
    bg: str = "#0a0d13"

    @property
    def full(self) -> bool:
        return (self.x == 0 and self.y == 0 and self.mode == "cover"
                and self.box_w == self.frame_w and self.box_h == self.frame_h)


def fit_filter(fit: Fit) -> list[str]:
    """Scale/crop/pad a stream into the clip's box inside the output frame."""
    parts: list[str] = []

    def frames_from_box() -> list[str]:
        """Content is box-sized; place it in the frame."""
        if fit.box_w == fit.frame_w and fit.box_h == fit.frame_h and fit.x == 0 and fit.y == 0:
            return []
        return [f"pad={fit.frame_w}:{fit.frame_h}"
                f":'max(0,{fit.x}+({fit.box_w}-iw)/2)':'max(0,{fit.y}+({fit.box_h}-ih)/2)'"
                f":color={fit.bg}"]

    if fit.mode == "cover":
        parts.append(f"scale={fit.box_w}:{fit.box_h}:force_original_aspect_ratio=increase:flags=lanczos")
        parts.append(f"crop={fit.box_w}:{fit.box_h}")
        parts.extend(frames_from_box())
        return parts

    # contain: fit inside the box, pad the remainder with the background
    parts.append(f"scale={fit.box_w}:{fit.box_h}:force_original_aspect_ratio=decrease:flags=lanczos")
    parts.extend(frames_from_box())
    return parts


def zoom_filter(zoom: list[float], span: int) -> str:
    """A slow push-in/pull-out that keeps the stream's own size.

    ``crop`` re-evaluates its size expressions every frame (they are timeline
    options), which is the cheapest way to animate a scale-and-centre; zoompan
    would also work but quantises the window to whole pixels and judders.
    """
    z0, z1 = float(zoom[0]), float(zoom[1])
    d = (z1 - z0) / max(span, 1)
    return (f"crop=w='iw/({z0:.6f}+({d:.8f})*n)':h='ih/({z0:.6f}+({d:.8f})*n)'"
            f":x='(iw-ow)/2':y='(ih-oh)/2'")


def grade_filter(grade: dict) -> str:
    """A white-balance / tone pass for footage shot under warm room light.

    Keys (all optional): ``temperature`` (target kelvin; the footage is assumed
    to be ~6500 K, so a LOWER value cools it), ``mix`` (0..1 blend with the
    original), ``saturation``, ``contrast``, ``brightness``, ``gamma``.
    """
    parts: list[str] = []
    if "temperature" in grade:
        temp = float(grade["temperature"])
        mix = float(grade.get("mix", 0.8))
        parts.append(f"colortemperature=temperature={temp:.0f}:mix={mix:.3f}")
    eq = []
    for key, fkey in (("saturation", "saturation"), ("contrast", "contrast"),
                      ("brightness", "brightness"), ("gamma", "gamma")):
        if key in grade:
            eq.append(f"{fkey}={float(grade[key]):.4f}")
    if eq:
        parts.append("eq=" + ":".join(eq))
    return ",".join(parts)


def clip_filter(
    *,
    region: list[int] | None,
    zoom: list[float] | None,
    out_frames: int,
    fit: Fit,
    fps: int,
    duration: float,
    fade_in: float,
    fade_out: float,
    has_overlay: bool,
    grade: dict | None = None,
    zoom_span: int | None = None,
    src_label: str = "0:v",
    ov_label: str = "1:v",
) -> str:
    """The filter_complex for one clip."""
    chain: list[str] = []
    if region:
        x, y, w, h = region
        chain.append(f"crop={w}:{h}:{x}:{y}")
    if zoom and abs(float(zoom[1]) - float(zoom[0])) > 1e-4:
        # The crop expressions count SOURCE frames, so the zoom span is the
        # clip's source span (out_frames * speed), not its output length.
        chain.append(zoom_filter(zoom, max((zoom_span or out_frames) - 1, 1)))
    chain.extend(fit_filter(fit))
    chain.append("setsar=1")
    if grade:
        # Graded BEFORE the overlay: the captions and the cursor are drawn in
        # post and must not inherit the footage's colour cast.
        g = grade_filter(grade)
        if g:
            chain.append(g)

    graph = [f"[{src_label}]{','.join(chain)}[base]"]
    if has_overlay:
        graph.append(f"[base][{ov_label}]overlay=0:0:format=auto:repeatlast=0[ovd]")
        vlabel = "ovd"
    else:
        vlabel = "base"

    tail: list[str] = []
    if fade_in > 0.001:
        tail.append(f"fade=t=in:st=0:d={fade_in:.3f}")
    if fade_out > 0.001:
        start = max(0.0, duration - fade_out)
        tail.append(f"fade=t=out:st={start:.3f}:d={fade_out:.3f}")
    tail.append(f"fps={fps}")
    tail.append("format=yuv420p")
    graph.append(f"[{vlabel}]{','.join(tail)}[vout]")
    return ";".join(graph)
