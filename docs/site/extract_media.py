#!/usr/bin/env python3
"""Copy showcase sheets + cut short clips into docs/site/assets (gitignored)."""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
ASSETS = ROOT / "assets"
SHEETS = REPO / "showcase_video" / "bake" / "sheet"
VIDEO = REPO / "showcase_video" / "out" / "poibuilder-showcase.mp4"
CREATE_SHEETS = REPO / "showcase_video" / "bake" / "create" / "sheets"

# Docs name → showcase sheet filename (no extension).
SHOTS = {
    "hero-courtyard": "68-map-night",
    "create-floor": "10-create-floor",
    "create-wall": "11-create-wall",
    "create-stairs": "13-create-stairs",
    "create-door": "15-create-door",
    "create-params": "14-create-params",
    "shapes-lineup": "50-shapes-lineup",
    "shapes-torus": "51-shapes-torus",
    "select-modes": "20-edit-select",
    "edge-loop": "21-edit-loop",
    "edit-move": "22-edit-move",
    "edit-extrude": "23-edit-extrude",
    "edit-inset": "24-edit-inset",
    "edit-subdiv": "25-edit-subdiv",
    "toolbar": "25-toolbar",
    "edit-loopcut": "26-edit-loopcut",
    "edit-merge": "27-edit-merge",
    "edit-weld": "28-edit-weld",
    "edit-detach": "29-edit-detach",
    "edit-delete": "30-edit-delete",
    "edit-knife": "31-edit-knife",
    "edit-ngon": "32-edit-ngon",
    "paint-splat": "40-paint-splat",
    "paint-stamp": "41-paint-stamp",
    "paint-scroll": "42-paint-scroll",
    "map-arch": "61-map-arch",
    "map-waterfall": "64-map-waterfall",
    "map-export": "67-map-export",
    "psp-court": "70-psp-court",
    "psp-hud": "75-psp-hud",
    "uv-editor": "80-uv",
    "edit-bevel": "81-bevel",
    "trim-walls": "83-trim-walls",
    "csg-booleans": "84-csg",
    "select-smart": "85-select-snap",
    "poibuilderize": "86-poibuilderize",
}

# Short loops cut from the assembled master (seconds).
# Times are approximate; extract uses -ss/-t so a missing master is non-fatal.
CLIPS = {
    "create-floor.mp4": (12.0, 3.2),
    "edit-extrude.mp4": (38.0, 2.4),
    "paint-splat.mp4": (78.0, 1.8),
    "map-waterfall.mp4": (118.0, 3.2),
}


def ffmpeg() -> str | None:
    for c in ("ffmpeg", shutil.which("ffmpeg")):
        if c and Path(c).name == "ffmpeg":
            w = shutil.which("ffmpeg")
            return w
    return shutil.which("ffmpeg")


def main() -> int:
    ASSETS.mkdir(parents=True, exist_ok=True)
    (ASSETS / "clips").mkdir(exist_ok=True)
    copied = 0
    for dest, src_stem in SHOTS.items():
        src = SHEETS / f"{src_stem}.png"
        if not src.is_file():
            alt = CREATE_SHEETS / f"{src_stem.replace('-', '_')}.png"
            src = alt if alt.is_file() else src
        if src.is_file():
            shutil.copy2(src, ASSETS / f"{dest}.png")
            copied += 1
        else:
            print(f"skip shot {dest}: no {src_stem}.png")
    ff = ffmpeg()
    if ff and VIDEO.is_file():
        for name, (start, dur) in CLIPS.items():
            out = ASSETS / "clips" / name
            cmd = [
                ff, "-y", "-ss", f"{start:.2f}", "-t", f"{dur:.2f}",
                "-i", str(VIDEO), "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart", str(out),
            ]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0:
                print(f"ffmpeg {name} failed: {r.stderr[-400:]}")
            else:
                print(f"clip {name}")
    elif not VIDEO.is_file():
        print(f"no master video at {VIDEO} — clips skipped")
    print(f"extracted {copied} stills -> {ASSETS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
