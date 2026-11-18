#!/usr/bin/env python3
"""Capture a .pbm's own camera poses (lump "camera_path") in PPSSPP and lay
them out on one contact sheet.

LOOKS ONLY. PPSSPP rasterises on the host and says nothing about what a frame
costs on a PSP (retro_engine/psp/HARDWARE-TESTING.md) — use it to check that a
map renders as intended, then price it with ./run_psp_hw.sh.

    python3 retro_engine/capture_pbm_poses.py map.pbm [--out DIR] [--only NAME]

Each pose runs the headless benchmark binary with a frozen camera
(poi_cam.txt) and keeps two frames 0.6 s apart, so animation is visible as the
difference between the pair.
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys

from PIL import Image, ImageDraw

PSP_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "psp")


def camera_poses(path):
    with open(path, "rb") as f:
        data = f.read()
    ntex, nmesh, ncol, nmeta = struct.unpack_from("<4I", data, 8)
    off = 64
    for _ in range(ntex):
        size = struct.unpack_from("<I", data, off + 40)[0]
        off += 44 + size
    for _ in range(nmesh):
        nv = struct.unpack_from("<I", data, off + 36)[0]
        off += 72 + nv * 24
    for _ in range(ncol):
        ntri = struct.unpack_from("<I", data, off + 60)[0]
        off += 64 + ntri * 36
    for _ in range(nmeta):
        tag = data[off:off + 32].split(b"\0")[0].decode()
        size = struct.unpack_from("<I", data, off + 36)[0]
        body = data[off + 40: off + 40 + size]
        off += 40 + size + (4 - size % 4) % 4
        if tag == "camera_path":
            n = struct.unpack_from("<I", body, 8)[0]
            poses = []
            for i in range(n):
                o = 16 + i * 44
                name = body[o:o + 16].split(b"\0")[0].decode()
                x, y, z, yaw, pitch = struct.unpack_from("<5f", body, o + 16)
                poses.append((name, x, y, z, yaw, pitch))
            return poses
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pbm")
    ap.add_argument("--out", default="/tmp/pbm_pose_captures")
    ap.add_argument("--only")
    args = ap.parse_args()
    poses = camera_poses(args.pbm)
    if not poses:
        sys.exit("no camera_path lump in " + args.pbm)
    os.makedirs(args.out, exist_ok=True)
    map_name = "capture_map.pbm"
    shutil.copy(args.pbm, os.path.join(PSP_DIR, map_name))
    # The app resolves poi_map.txt ahead of its argument (PPSSPP may not pass
    # one at all): point it at the capture map for the run, restore it after.
    pointer = os.path.join(PSP_DIR, "poi_map.txt")
    saved_pointer = open(pointer).read() if os.path.exists(pointer) else None
    with open(pointer, "w") as fh:
        fh.write(map_name + "\n")
    shots = []
    for name, x, y, z, yaw, pitch in poses:
        if args.only and name != args.only:
            continue
        for f in os.listdir(PSP_DIR):
            if f.startswith("screenshot_psp_f") and f.endswith(".tga"):
                os.remove(os.path.join(PSP_DIR, f))
        with open(os.path.join(PSP_DIR, "poi_cam.txt"), "w") as fh:
            fh.write(f"{x} {y} {z} {yaw} {pitch}\n")
        subprocess.run(["timeout", "-k", "10", "240", "PPSSPPHeadless", "./poiretro_psp_test.elf",
                        map_name, "--graphics=software", "--timeout=40"], cwd=PSP_DIR,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pair = []
        for fr in ("screenshot_psp_f060.tga", "screenshot_psp_f096.tga"):
            p = os.path.join(PSP_DIR, fr)
            if os.path.exists(p):
                im = Image.open(p).convert("RGB")
                dst = os.path.join(args.out, f"{name}_{fr[-8:-4]}.png")
                im.save(dst)
                pair.append(im)
        print(f"{name}: {len(pair)} frames", flush=True)
        shots.append((name, pair))
    os.remove(os.path.join(PSP_DIR, "poi_cam.txt"))
    os.remove(os.path.join(PSP_DIR, map_name))
    if saved_pointer is None:
        os.remove(pointer)
    else:
        with open(pointer, "w") as fh:
            fh.write(saved_pointer)
    w, h = 480, 272
    sheet = Image.new("RGB", (w * 2 + 6, (h + 16) * len(shots)), (30, 30, 30))
    d = ImageDraw.Draw(sheet)
    for i, (name, pair) in enumerate(shots):
        for j, im in enumerate(pair):
            sheet.paste(im, (j * (w + 6), i * (h + 16) + 16))
        d.text((4, i * (h + 16) + 2), f"{name}  (frame 60 | frame 96)", fill=(255, 230, 120))
    out = os.path.join(args.out, "sheet.png")
    sheet.save(out)
    print("sheet:", out)


if __name__ == "__main__":
    main()
