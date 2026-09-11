"""The edit decision list: what the showcase video is made of.

A clip is one continuous piece of video. It comes from exactly one of:

* ``source = "session:shot"``  — frames captured by a Godot showcase session
* ``file   = "path.mp4"``      — an external video (the PSP device footage)
* ``card   = "title"``         — a generated card (text rendered by Pillow)

Everything else (crop region, time trim, speed, push-in, fades, captions) is
declarative, so the whole timeline can be re-cut without touching the renderer.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

FPS = 60


class EdlError(Exception):
    pass


@dataclass
class Caption:
    """A caption shown over part of a clip. Rendered by Pillow at output size."""

    text: str
    sub: str = ""
    label: str = ""
    at: float = 0.0
    dur: float | None = None       # None → until the clip ends
    fade: float = 0.18
    pos: str = "bl"                # bl | bc | tl | tr | mid
    style: str = "chip"            # chip | banner | plain
    accent: str = ""


@dataclass
class Clip:
    id: str
    kind: str                      # frames | video | card
    source: str = ""               # "session:shot" for frames
    file: str = ""
    card: dict[str, Any] = field(default_factory=dict)
    region: str = ""               # named region from the session manifest
    crop: list[int] | None = None  # explicit source crop (x, y, w, h)
    at: float = 0.0                # start offset into the source
    dur: float | None = None       # None → to the end of the source
    speed: float = 1.0
    zoom: list[float] | None = None  # [z0, z1] slow push-in over the clip
    fade_in: float = 0.0
    fade_out: float = 0.0
    fit: str = "cover"             # cover | contain
    into: list[int] | None = None  # (x, y, w, h) inside the output frame
    bg: str = "#0a0d13"
    frame: str = ""                # "" | "rounded" — dress placed content
    cursor: bool = True
    muted: bool = True
    grade: dict[str, Any] = field(default_factory=dict)
    captions: list[Caption] = field(default_factory=list)
    notes: str = ""

    # --- derived -----------------------------------------------------------
    @property
    def palette(self) -> tuple[str, str]:
        return ("#0a0d13", "#33e0ff")


@dataclass
class Project:
    path: Path
    name: str = "poibuilder-showcase"
    width: int = 1280
    height: int = 720
    fps: int = FPS
    readme_width: int = 960
    out_dir: str = "out"
    master: str = "poibuilder-showcase.mp4"
    readme: str = "poibuilder-showcase-960.mp4"
    poster: str = "poibuilder-showcase-poster.png"
    clips: list[Clip] = field(default_factory=list)

    @property
    def readme_height(self) -> int:
        return int(round(self.readme_width * self.height / self.width / 2) * 2)

    @property
    def total_seconds(self) -> float:
        return sum(c.dur or 0.0 for c in self.clips)


def _caption(raw: dict[str, Any]) -> Caption:
    return Caption(
        text=raw.get("text", ""),
        sub=raw.get("sub", ""),
        label=raw.get("label", ""),
        at=float(raw.get("at", 0.0)),
        dur=float(raw["dur"]) if "dur" in raw else None,
        fade=float(raw.get("fade", 0.18)),
        pos=raw.get("pos", "bl"),
        style=raw.get("style", "chip"),
        accent=raw.get("accent", ""),
    )


def _clip(raw: dict[str, Any]) -> Clip:
    cid = raw.get("id")
    if not cid:
        raise EdlError(f"clip without id: {raw}")
    kind = raw.get("kind")
    if kind is None:
        if raw.get("source"):
            kind = "frames"
        elif raw.get("file"):
            kind = "video"
        elif raw.get("card"):
            kind = "card"
        else:
            raise EdlError(f"clip '{cid}' has no source/file/card")
    caps = [_caption(c) for c in raw.get("captions", [])]
    if "caption" in raw:
        caps.insert(0, _caption(raw["caption"]))
    return Clip(
        id=cid,
        kind=kind,
        source=raw.get("source", ""),
        file=raw.get("file", ""),
        card=(raw["card"] if isinstance(raw.get("card"), dict)
              else ({"title": raw["card"]} if raw.get("card") else {})),
        region=raw.get("region", ""),
        crop=list(raw["crop"]) if "crop" in raw else None,
        at=float(raw.get("at", 0.0)),
        dur=float(raw["dur"]) if "dur" in raw else None,
        speed=float(raw.get("speed", 1.0)),
        zoom=list(raw["zoom"]) if "zoom" in raw else None,
        fade_in=float(raw.get("fade_in", 0.0)),
        fade_out=float(raw.get("fade_out", 0.0)),
        fit=raw.get("fit", "cover"),
        into=list(raw["into"]) if "into" in raw else None,
        bg=raw.get("bg", "#0a0d13"),
        frame=raw.get("frame", ""),
        cursor=bool(raw.get("cursor", True)),
        grade=dict(raw.get("grade", {})),
        captions=caps,
        notes=raw.get("notes", ""),
    )


def load(path: str | Path) -> Project:
    path = Path(path)
    with path.open("rb") as fh:
        raw = tomllib.load(fh)
    proj = Project(path=path)
    meta = raw.get("project", {})
    for key in ("name", "out_dir", "master", "readme", "poster"):
        if key in meta:
            setattr(proj, key, str(meta[key]))
    for key in ("width", "height", "fps", "readme_width"):
        if key in meta:
            setattr(proj, key, int(meta[key]))
    proj.clips = [_clip(c) for c in raw.get("clip", [])]
    if not proj.clips:
        raise EdlError("the EDL has no [[clip]] entries")
    ids = [c.id for c in proj.clips]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        raise EdlError(f"duplicate clip ids: {sorted(dupes)}")
    for c in proj.clips:
        if c.kind == "frames" and ":" not in c.source:
            raise EdlError(f"clip '{c.id}': frames clips need source = \"session:shot\"")
        if c.kind == "video" and not c.file:
            raise EdlError(f"clip '{c.id}': video clips need file")
        if c.kind == "card" and not c.card:
            raise EdlError(f"clip '{c.id}': card clips need card data")
        if c.kind != "card" and c.dur is None:
            raise EdlError(f"clip '{c.id}': dur is required for {c.kind} clips")
    return proj
