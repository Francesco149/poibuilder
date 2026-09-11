"""Reading what a showcase session recorded.

A session directory (``showcase_video/bake/<session>/``) holds:

  frames/NNNNNN.png   the full editor window, one file per captured frame
  cursor.bin          int32 x, int32 y per captured frame
  events.jsonl        clicks / keys / shot markers with frame numbers
  manifest.json       window size, named regions, shot ranges, checks
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from functools import cached_property
from pathlib import Path


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
        return [self.cursor_at(shot, first + int(round(i * speed))) for i in range(count)]

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
