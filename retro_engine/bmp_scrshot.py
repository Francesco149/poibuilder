#!/usr/bin/env python3
"""Convert a PSPLink `scrshot` dump to PNG, optionally cropped and magnified.

`pspsh -e "scrshot host0:/shot.bmp"` writes the PSP's *real* framebuffer as a
480x272 24-bit BMP (top-down row order is handled here). This turns it into
something inspectable, with nearest-neighbour zoom so individual texels and
seams stay visible instead of being smoothed away.

Usage:
  python3 bmp_scrshot.py shot.bmp                       # whole frame -> shot.png
  python3 bmp_scrshot.py shot.bmp --crop 230,205,330,240 --zoom 8
  python3 bmp_scrshot.py shot.bmp --crop 140,180,420,272 --zoom 3 --out floor.png
"""

import argparse
import struct
import zlib


def read_bmp(path):
    d = open(path, "rb").read()
    if d[:2] != b"BM":
        raise SystemExit(f"{path}: not a BMP (scrshot output expected)")
    off = struct.unpack_from("<I", d, 10)[0]
    w, h = struct.unpack_from("<ii", d, 18)
    bpp = struct.unpack_from("<H", d, 28)[0]
    if bpp not in (24, 32):
        raise SystemExit(f"{path}: unsupported {bpp}-bit BMP")
    row = ((w * bpp // 8) + 3) // 4 * 4
    px_per = bpp // 8
    bottom_up = h > 0
    h = abs(h)
    px = d[off:]

    def get(x, y):
        ry = (h - 1 - y) if bottom_up else y
        i = ry * row + x * px_per
        return (px[i + 2], px[i + 1], px[i])

    return w, h, get


def write_png(path, w, h, rows):
    raw = b"".join(rows)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bmp")
    ap.add_argument("--crop", help="x0,y0,x1,y1 in source pixels")
    ap.add_argument("--zoom", type=int, default=1, help="integer nearest-neighbour magnify")
    ap.add_argument("--out")
    args = ap.parse_args()

    w, h, get = read_bmp(args.bmp)
    if args.crop:
        x0, y0, x1, y1 = (int(v) for v in args.crop.split(","))
        x0, y0 = max(0, x0), max(0, y0)
        x1, y1 = min(w, x1), min(h, y1)
    else:
        x0, y0, x1, y1 = 0, 0, w, h
    z = max(1, args.zoom)
    cw, ch = (x1 - x0) * z, (y1 - y0) * z
    rows = []
    for yy in range(ch):
        row = bytearray(b"\x00")
        sy = y0 + yy // z
        for xx in range(cw):
            row += bytes(get(x0 + xx // z, sy))
        rows.append(bytes(row))

    out = args.out or (args.bmp.rsplit(".", 1)[0] + ".png")
    write_png(out, cw, ch, rows)
    print(f"{out}  {cw}x{ch}  (source {args.bmp} {w}x{h}, crop {x0},{y0}-{x1},{y1}, zoom {z})")


if __name__ == "__main__":
    main()
