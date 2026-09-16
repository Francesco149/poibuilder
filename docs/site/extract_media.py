#!/usr/bin/env python3
"""Extract high-resolution, uncompressed documentation screenshots from raw showcase frames.

Crops specifically for documentation: shows 3D models with relevant UI (toolbars,
parameter modals, UV editor floating window, material docks) in crisp 1080p source
resolution with zero text captions/watermarks.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
ASSETS = ROOT / "assets"
BAKE = REPO / "showcase_video" / "bake"
SOURCE_VIDEO = REPO / "showcase_video" / "source" / "psp-day.mp4"
MASTER_VIDEO = REPO / "showcase_video" / "out" / "poibuilder-showcase.mp4"

# Standard 16:9 crop framing 3D viewport + top toolbar:
# (x=287, y=80, w=1266, h=712)
STD_VIEWPORT_CROP = (287, 80, 1266, 712)

# Shot specifications: (session, shot_slug, frame_num, crop_box)
# crop_box is (x, y, w, h) in 1920x1080 coordinate space.
DOC_SHOTS: dict[str, tuple[str, str, int, tuple[int, int, int, int]]] = {
    # Bevel: show modal with 8 segments & distance 0.35m + smooth rounded fillet preview
    "edit-bevel": ("more", "more_bevel", 310, (140, 60, 1400, 788)),
    # UV editor: 16:9 view showing 3D cube on left + full floating UV Editor on right
    "uv-editor": ("more", "more_uv", 350, (280, 75, 1280, 720)),
    # Trim: show live Trim Parameters modal on wall
    "trim-one-drag": ("more", "more_trim", 200, (140, 60, 1400, 788)),
    # Trim walls: close-up on the mitred corner showing round wood skirting against stone
    "trim-walls": ("more", "more_trim_walls", 400, (287, 80, 1266, 712)),
    # Poibuilderize: medieval wooden barrel with face pulled up and element gizmos
    "poibuilderize": ("more", "more_poibuilderize", 210, (287, 80, 1266, 712)),
    # CSG booleans: clean circular tunnel cut through stone wall with brick interior
    "csg-booleans": ("more", "more_csg", 120, (287, 80, 1266, 712)),
    # Smart select: dark charcoal cube with yellow coplanar face highlight
    "select-smart": ("more", "more_select_snap", 360, (287, 80, 1266, 712)),
    
    # Creation beats
    "create-floor": ("create", "create_surfaces", 140, (287, 80, 1266, 712)),
    "create-wall": ("create", "create_surfaces", 380, (287, 80, 1266, 712)),
    "create-stairs": ("create", "create_stairs", 220, (287, 80, 1266, 712)),
    "create-door": ("create", "create_door", 200, (287, 80, 1266, 712)),
    "create-params": ("create", "create_params", 60, (140, 100, 1380, 750)),
    
    # Shapes
    "shapes-lineup": ("shapes", "shapes_lineup", 260, (287, 80, 1266, 712)),
    "shapes-torus": ("shapes", "shapes_torus", 120, (287, 80, 1266, 712)),
    
    # Edit operations
    "select-modes": ("edit", "edit_select", 110, (287, 80, 1266, 712)),
    "edge-loop": ("edit", "edit_edge_loop", 180, (287, 80, 1266, 712)),
    "edit-move": ("edit", "edit_move", 200, (287, 80, 1266, 712)),
    "edit-extrude": ("edit", "edit_extrude", 150, (287, 80, 1266, 712)),
    "edit-inset": ("edit", "edit_inset", 260, (287, 80, 1266, 712)),
    "edit-subdiv": ("edit", "edit_subdivide", 220, (287, 80, 1266, 712)),
    # Toolbar: crop around the full 4-row 3D toolbar layout
    "toolbar": ("more", "more_select_snap", 50, (287, 44, 1266, 230)),
    "edit-loopcut": ("edit", "edit_loopcut", 320, (287, 80, 1266, 712)),
    "edit-merge": ("edit", "edit_merge", 280, (287, 80, 1266, 712)),
    "edit-weld": ("edit", "edit_weld", 190, (287, 80, 1266, 712)),
    "edit-detach": ("edit", "edit_detach", 200, (287, 80, 1266, 712)),
    "edit-delete": ("edit", "edit_delete", 200, (287, 80, 1266, 712)),
    "edit-knife": ("edit", "edit_knife", 310, (287, 80, 1266, 712)),
    "edit-ngon": ("edit", "edit_ngon", 220, (287, 80, 1266, 712)),
    
    # Paint: wide crop showing 3D viewport AND the Material & UV dock on the right
    "paint-splat": ("paint", "paint_splat", 160, (287, 44, 1620, 740)),
    "paint-stamp": ("paint", "paint_stamp", 140, (287, 44, 1620, 740)),
    
    # Map
    "hero-courtyard": ("map", "map_night", 180, (287, 44, 1266, 712)),
    "map-waterfall": ("map", "map_waterfall", 500, (287, 80, 1266, 712)),
    # Export: shows the Export dialog modal open over the map
    "map-export": ("map", "map_export", 160, (287, 44, 1266, 712)),
}

# Short loops cut from the assembled master (seconds)
CLIPS = {
    "create-floor.mp4": (9.10, 7.80),
    "edit-extrude.mp4": (34.20, 2.60),
    "paint-splat.mp4": (72.80, 1.85),
    "paint-scroll.mp4": (77.25, 2.00),
    "map-waterfall.mp4": (102.05, 3.60),
}


def extract_psp_shots() -> None:
    """Extract crisp PSP hardware stills from the raw source video."""
    if not SOURCE_VIDEO.exists():
        return
    ff = shutil.which("ffmpeg")
    if not ff:
        return
    # psp-court: frame at 2.0s
    out_court = ASSETS / "psp-court.png"
    cmd1 = [
        ff, "-hide_banner", "-loglevel", "error", "-y",
        "-ss", "2.0", "-i", str(SOURCE_VIDEO),
        "-frames:v", "1", "-vf", "scale=1280:720", str(out_court)
    ]
    subprocess.run(cmd1)

    # psp-hud: close-up crop of the HUD text
    out_hud = ASSETS / "psp-hud.png"
    cmd2 = [
        ff, "-hide_banner", "-loglevel", "error", "-y",
        "-ss", "14.5", "-i", str(SOURCE_VIDEO),
        "-frames:v", "1", "-vf", "crop=1096:190:462:220,scale=1096:190", str(out_hud)
    ]
    subprocess.run(cmd2)


def main() -> int:
    ASSETS.mkdir(parents=True, exist_ok=True)
    (ASSETS / "clips").mkdir(exist_ok=True)
    extracted = 0

    for dest_stem, (sess, shot, frame_num, (x, y, w, h)) in DOC_SHOTS.items():
        frames_dir = BAKE / sess / "shots" / shot / "frames"
        src_path = frames_dir / f"{frame_num:06d}.png"
        if not src_path.is_file():
            # Fallback to nearest available frame if exact number is slightly out
            all_frames = sorted(frames_dir.glob("*.png")) if frames_dir.is_dir() else []
            if all_frames:
                src_path = all_frames[min(frame_num, len(all_frames) - 1)]
            else:
                print(f"skip {dest_stem}: no frames in {frames_dir}")
                continue

        try:
            with Image.open(src_path) as img:
                # Crop specifically for docs: [left, top, right, bottom]
                crop_box = (x, y, x + w, y + h)
                cropped = img.crop(crop_box)
                out_path = ASSETS / f"{dest_stem}.png"
                cropped.save(out_path, format="PNG", optimize=True)
                extracted += 1
        except Exception as e:
            print(f"error extracting {dest_stem}: {e}")

    extract_psp_shots()

    # Video clip loops for animated doc figures
    ff = shutil.which("ffmpeg")
    if ff and MASTER_VIDEO.is_file():
        for name, (start, dur) in CLIPS.items():
            out = ASSETS / "clips" / name
            cmd = [
                ff, "-hide_banner", "-loglevel", "error", "-y",
                "-ss", f"{start:.2f}", "-t", f"{dur:.2f}",
                "-i", str(MASTER_VIDEO), "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart", str(out),
            ]
            subprocess.run(cmd)

    print(f"extracted {extracted} high-res documentation stills -> {ASSETS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
