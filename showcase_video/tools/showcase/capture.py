"""Reading what a showcase session recorded.

A session directory (``showcase_video/bake/<session>/``) holds:

  frames/NNNNNN.png   the full editor window, one file per captured frame
  cursor.bin          int32 x, int32 y per captured frame
  events.jsonl        clicks / keys / shot markers with frame numbers
  manifest.json       window size, named regions, shot ranges, checks
"""

from __future__ import annotations

import json
import math
import struct
from fractions import Fraction
from dataclasses import dataclass
from functools import cached_property
from pathlib import Path


# --- time mapping ----------------------------------------------------------
# A clip at `speed` reads its frames at fps*speed and the graph resamples them
# to fps (build.resolve / ffmpeg.clip_filter). ONE rule says which source
# frame lands on output frame i, and the overlay (cursor, clicks, zoom
# progress) samples with it, so the drawn cursor and the footage cannot drift.
# `cursor_check --timing` verifies the rule against ffmpeg itself.

# Cursor auto-hide (Session.cursor_visibility), in source frames at 60 fps.
CURSOR_LEAD = 14     # appear this long before the pointer starts doing something
CURSOR_HOLD = 50     # stay this long after it stops (results land, hovers read)
CURSOR_FADE = 10     # fade in / out over this many frames


def speed_ratio(speed: float) -> Fraction:
    """`speed` as the exact ratio ffmpeg is given (1.15 -> 23/20)."""
    return Fraction(speed).limit_denominator(1000)


def ffmpeg_rate(fps: int, speed: float) -> str:
    r = fps * speed_ratio(speed)
    return str(r.numerator) if r.denominator == 1 else f"{r.numerator}/{r.denominator}"


def src_index(i: int, speed: float) -> int:
    """Source frame (from the clip's first) shown on output frame i.

    ffmpeg's `fps=round=near` puts source frame k in output slot round(k/speed)
    and keeps the LAST frame per slot, so slot i holds the largest k with
    k/speed < i + 1/2:  k = ceil((i + 1/2) * speed) - 1.  (Not round(i*speed):
    that disagreed on one frame in eight at 1.15x.)
    """
    r = speed_ratio(speed)
    if r == 1:
        return i
    return max(0, math.ceil((Fraction(2 * i + 1, 2)) * r) - 1)



class CaptureError(Exception):
    pass


@dataclass(frozen=True)
class Shot:
    """One recorded beat: its own frame sequence, cursor track and events."""

    name: str
    directory: str
    frames: int
    regions: dict[str, list[int]]
    wall_seconds: float = 0.0

    @property
    def seconds(self) -> float:
        return self.frames / 60.0

    def region(self, name: str) -> list[int]:
        if name in self.regions:
            return self.regions[name]
        raise CaptureError(f"shot '{self.name}' has no region '{name}' "
                           f"(have: {sorted(self.regions)})")


class Session:
    """One rendered showcase session, read back from disk."""

    def __init__(self, name: str, root: Path):
        self.name = name
        self.root = Path(root)
        mpath = self.root / "manifest.json"
        if not mpath.exists():
            raise CaptureError(
                f"session '{name}' has no manifest at {mpath} — render it first "
                f"(./showcase_video/render.sh {name})")
        self.data = json.loads(mpath.read_text())
        self._cursor: dict[str, memoryview] = {}

    # --- basics ------------------------------------------------------------
    @property
    def fps(self) -> int:
        return int(self.data.get("fps", 60))

    @property
    def frames(self) -> int:
        return int(self.data.get("frames", 0))

    @property
    def window(self) -> tuple[int, int]:
        w, h = self.data.get("window", [1920, 1080])
        return int(w), int(h)

    @property
    def checks(self) -> list[dict]:
        return self.data.get("checks", [])

    @property
    def failed_checks(self) -> list[dict]:
        return [c for c in self.checks if not c.get("ok")]

    # --- shots -------------------------------------------------------------
    @cached_property
    def shots(self) -> dict[str, Shot]:
        out: dict[str, Shot] = {}
        for s in self.data.get("shots", []):
            out[s["name"]] = Shot(
                name=s["name"],
                directory=s.get("dir", f"shots/{s['name'].replace('/', '_')}"),
                frames=int(s.get("frames", 0)),
                regions={k: [int(v) for v in val] for k, val in s.get("regions", {}).items()},
                wall_seconds=float(s.get("wall_seconds", 0.0)),
            )
        return out

    def shot(self, name: str) -> Shot:
        if name not in self.shots:
            raise CaptureError(f"session '{self.name}' has no shot '{name}' "
                               f"(have: {sorted(self.shots)})")
        return self.shots[name]

    def shot_names(self) -> list[str]:
        return [s["name"] for s in self.data.get("shots", [])]

    def shot_by_dir(self, directory: str) -> Shot | None:
        for s in self.shots.values():
            if s.directory == directory:
                return s
        return None

    def frames_dir(self, shot: Shot) -> Path:
        return self.root / shot.directory / "frames"

    # --- cursor ------------------------------------------------------------
    def _cursor_mv(self, shot: Shot) -> memoryview:
        key = shot.name
        if key not in self._cursor:
            path = self.root / shot.directory / "cursor.bin"
            self._cursor[key] = memoryview(path.read_bytes()) if path.exists() else memoryview(b"")
        return self._cursor[key]

    def cursor_at(self, shot: Shot, index: int) -> tuple[int, int]:
        mv = self._cursor_mv(shot)
        off = index * 8
        if off + 8 > len(mv):
            return (0, 0)
        x, y = struct.unpack_from("<ii", mv, off)
        return x, y

    def cursor_range(self, shot: Shot, first: int, count: int,
                     speed: float = 1.0) -> list[tuple[int, int]]:
        """Cursor positions sampled at the clip's output rate."""
        return [self.cursor_at(shot, first + src_index(i, speed)) for i in range(count)]

    def cursor_visibility(self, shot: Shot) -> list[float]:
        """Per SOURCE frame of the shot, how visible the drawn cursor should be.

        The pointer is a hand: it is there when it is doing something. A frame
        is ACTIVE when the pointer moved since the last frame, a button went
        down or up, or a button is held. The cursor shows from LEAD frames
        before activity until HOLD frames after it, and fades over FADE frames
        either side. Computed over the whole shot (not the clip's span), so a
        clip that starts mid-rest still knows activity is coming.
        """
        key = ("vis", shot.name)
        if key in self._cursor:
            return self._cursor[key]  # type: ignore[return-value]
        n = shot.frames
        active = [False] * n
        prev = None
        for f in range(n):
            p = self.cursor_at(shot, f)
            if prev is not None and (abs(p[0] - prev[0]) + abs(p[1] - prev[1])) >= 1:
                active[f] = True
            prev = p
        down = None
        for e in self.events(shot):
            t = e.get("t")
            f = int(e.get("f", 0))
            if t == "mousedown":
                down = f
            elif t == "mouseup":
                for g in range((down if down is not None else f), min(f + 1, n)):
                    active[g] = True
                down = None
            if t in ("mousedown", "mouseup") and 0 <= f < n:
                active[f] = True
        if down is not None:
            for g in range(down, n):
                active[g] = True
        vis = [0.0] * n
        # distance (frames) to the previous / next active frame
        last = -10 ** 9
        back = [0] * n
        for f in range(n):
            if active[f]:
                last = f
            back[f] = f - last
        nxt = 10 ** 9
        fwd = [0] * n
        for f in range(n - 1, -1, -1):
            if active[f]:
                nxt = f
            fwd[f] = nxt - f
        for f in range(n):
            a_back = 1.0 - (back[f] - CURSOR_HOLD) / CURSOR_FADE
            a_fwd = 1.0 - (fwd[f] - CURSOR_LEAD) / CURSOR_FADE
            vis[f] = max(0.0, min(1.0, max(a_back, a_fwd)))
        self._cursor[key] = vis  # type: ignore[assignment]
        return vis

    def events(self, shot: Shot) -> list[dict]:
        path = self.root / shot.directory / "events.jsonl"
        if not path.exists():
            return []
        out = []
        for line in path.read_text().splitlines():
            line = line.strip()
            if line:
                out.append(json.loads(line))
        return out

    def clicks(self, shot: Shot) -> list[tuple[int, int, int]]:
        """(frame, x, y) for every mousedown in the shot."""
        out = []
        for e in self.events(shot):
            if e.get("t") == "mousedown":
                out.append((int(e.get("f", 0)), int(e.get("x", 0)), int(e.get("y", 0))))
        return out
