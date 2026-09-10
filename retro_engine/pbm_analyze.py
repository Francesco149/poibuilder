#!/usr/bin/env python3
"""PBM view analyzer — predicts PSP GE cost for a camera pose without a PSP.

Reports, for one or more camera poses:
  * projected screen coverage and overdraw (fill-rate demand)
  * per-pixel texture sampling rate R (texels sampled per screen pixel) and its
    histogram — R >> 1 means minification, which thrashes the GE's tiny texture
    cache when the texture has no mip chain
  * per-mesh breakdown of pixels and of "thrashing" pixels

The camera and projection math mirrors retro_engine/psp/main.c exactly:
  sceGumPerspective(65.0f, 16.0f/9.0f, near, far) and the (yaw, pitch) look
  vector used by the interactive camera.

Usage:
  python3 pbm_analyze.py map.pbm                 # all named presets
  python3 pbm_analyze.py map.pbm --cam x y z yaw pitch
  python3 pbm_analyze.py map.pbm --all           # presets + camera grid sweep
"""

import argparse
import math
import struct
import sys

import numpy as np

SCR_W, SCR_H = 480, 272
FOV_Y = math.radians(65.0)
ASPECT = 16.0 / 9.0

PRESETS = {
    # name: (x, y, z, yaw, pitch)  — yaw/pitch in radians, PSP convention
    "spawn":      (0.0, 1.6, 4.2, 0.0, 0.05),
    "arch":       (0.0, 1.6, -2.0, 0.0, 0.0),
    "stairs":     (-2.0, 1.5, 0.0, -math.pi / 2, 0.0),
    "stairs_low": (-2.0, 0.6, 0.0, -math.pi / 2, 0.15),
    "below_up":   (0.0, -1.2, 2.0, 0.0, 1.0),
    "above_down": (0.0, 6.0, 0.0, 0.0, -1.0),
    "balcony":    (-4.5, 3.5, -4.0, 0.0, -0.2),
    "ramp":       (4.5, 1.0, 3.0, math.pi, -0.1),
    "corner":     (5.0, 1.6, 5.0, -2.35, 0.0),
}


# ── PBM parsing ──────────────────────────────────────────────────────────────

class Mesh:
    __slots__ = ("name", "tex_id", "verts", "uv", "pos")

    def __init__(self, name, tex_id, verts, uv, pos):
        self.name, self.tex_id, self.verts, self.uv, self.pos = name, tex_id, verts, uv, pos


def load_pbm(path):
    data = open(path, "rb").read()
    magic, ver, n_tex, n_mesh, n_col, n_meta = struct.unpack_from("<6I", data, 0)
    if magic != 0x324D4250:
        raise SystemExit(f"{path}: bad magic {magic:#x} (need PBM2)")
    off = 64
    textures = []
    for _ in range(n_tex):
        nm, w, h, fmt, alpha, dsz = struct.unpack_from("<32sHHHHI", data, off)
        off += 44 + dsz
        textures.append((nm.split(b"\0")[0].decode(), w, h, fmt, alpha))
    meshes = []
    for _ in range(n_mesh):
        nm, tid, nv = struct.unpack_from("<32siI", data, off)
        off += 64
        v = np.frombuffer(data, dtype=np.dtype([
            ("u", "<f4"), ("v", "<f4"), ("c", "<u4"), ("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
        ]), count=nv, offset=off)
        off += nv * 24
        meshes.append(Mesh(nm.split(b"\0")[0].decode(), tid,
                           v, np.stack([v["u"], v["v"]], 1), np.stack([v["x"], v["y"], v["z"]], 1)))
    return textures, meshes


# ── Camera / projection ──────────────────────────────────────────────────────

def view_matrix(cam, yaw, pitch):
    cx, cy, cz = cam
    cp, sp = math.cos(pitch), math.sin(pitch)
    fwd = np.array([math.sin(yaw) * cp, sp, -math.cos(yaw) * cp])
    up = np.array([0.0, 1.0, 0.0])
    zaxis = -fwd                      # camera looks down -Z
    xaxis = np.cross(up, zaxis)
    xaxis /= np.linalg.norm(xaxis)
    yaxis = np.cross(zaxis, xaxis)
    M = np.eye(4)
    M[0, :3], M[1, :3], M[2, :3] = xaxis, yaxis, zaxis
    M[:3, 3] = -M[:3, :3] @ np.array([cx, cy, cz])
    return M


def project(pts_view, near, far):
    """View-space -> screen pixels (x right, y down) with w for clipping."""
    cot = 1.0 / math.tan(FOV_Y * 0.5)
    sx, sy, sz = cot / ASPECT, cot, far / (far - near)
    x, y, z = pts_view[:, 0], pts_view[:, 1], pts_view[:, 2]
    cx = sx * x
    cy = sy * y
    cz = sz * z + (-(far * near) / (far - near))
    cw = -z
    return np.stack([cx, cy, cz, cw], 1)


# ── Rasterizer ───────────────────────────────────────────────────────────────

class Frame:
    def __init__(self):
        self.pixels = np.zeros((SCR_H, SCR_W), np.uint16)     # overdraw counter
        self.thrash = np.zeros((SCR_H, SCR_W), np.float32)    # max sampling rate seen
        self.by_mesh = {}
        # clipper engagement: the GE guardband is 0..4095 in screen space, which
        # in NDC is |x| < 8.53 and |y| < 15.05 for this viewport/offset pair.
        self.guard_x = 0        # vertices whose |ndc_x| leaves the guardband
        self.guard_y = 0
        self.near_split = 0     # triangles the near plane actually cuts
        self.behind = 0         # triangles entirely behind the near plane
        self.offscreen = 0      # triangles with no pixel coverage
        self.tri_areas = []

    def add(self, name, sub, mask, ratio):
        self.pixels[sub][mask] += 1
        tgt = self.thrash[sub]
        np.maximum(tgt, np.where(mask, ratio, 0.0), out=tgt)
        rec = self.by_mesh.setdefault(name, [0, 0, 0, 0])  # px, px>2, px>4, px>8
        rec[0] += int(mask.sum())
        for i, thr in enumerate((2.0, 4.0, 8.0)):
            rec[1 + i] += int(np.count_nonzero(mask & (ratio > thr)))


def analyze(textures, meshes, cam, yaw, pitch, near, far, cull=True, verbose=False):
    V = view_matrix(cam, yaw, pitch)
    eye = np.array(cam, float)
    frame = Frame()
    total_tris = culled = clipped = 0

    for m in meshes:
        texw = texh = 0
        if 0 <= m.tex_id < len(textures):
            texw, texh = textures[m.tex_id][1], textures[m.tex_id][2]
        pos = np.concatenate([m.pos, np.ones((len(m.pos), 1))], 1) @ V.T
        pos = pos[:, :3]
        uv = m.uv
        n = len(pos)
        for t in range(n // 3):
            idx = [3 * t, 3 * t + 1, 3 * t + 2]
            p = pos[idx]
            total_tris += 1

            # backface cull in world space (GE CCW front faces)
            a, b, c = m.pos[idx]
            nrm = np.cross(b - a, c - a)
            if cull and np.dot(nrm, eye - a) < 0:
                culled += 1
                continue

            # guardband crossings (computed on the unclipped vertices)
            cot = 1.0 / math.tan(FOV_Y * 0.5)
            sx, sy = cot / ASPECT, cot
            nz = -p[:, 2]
            if np.all(nz <= 0):
                frame.behind += 1
                continue
            front = nz > 0
            if front.any():
                ndx = sy * 0 + sx * p[front, 0] / nz[front]
                ndy = sy * p[front, 1] / nz[front]
                frame.guard_x += int(np.count_nonzero(np.abs(ndx) > 8.53))
                frame.guard_y += int(np.count_nonzero(np.abs(ndy) > 15.05))

            # near-plane clip (Sutherland-Hodgman against z = -near)
            poly = [(p[i], uv[idx[i]]) for i in range(3)]
            out = []
            for i in range(3):
                cur, nxt = poly[i], poly[(i + 1) % 3]
                dc, dn = -cur[0][2] - near, -nxt[0][2] - near
                if dc >= 0:
                    out.append(cur)
                if (dc >= 0) != (dn >= 0):
                    t2 = dc / (dc - dn)
                    out.append((cur[0] + (nxt[0] - cur[0]) * t2, cur[1] + (nxt[1] - cur[1]) * t2))
            if len(out) < 3:
                clipped += 1
                frame.offscreen += 1
                continue
            if len(out) > 3:
                clipped += 1
                frame.near_split += 1

            for k in range(1, len(out) - 1):
                tri = [out[0], out[k], out[k + 1]]

                # project
                clip = []
                for pv, tuv in tri:
                    cot = 1.0 / math.tan(FOV_Y * 0.5)
                    z = pv[2]
                    w = -z
                    cx = (cot / ASPECT) * pv[0] / w
                    cy = cot * pv[1] / w
                    sx = (cx * 0.5 + 0.5) * SCR_W
                    sy = (0.5 - cy * 0.5) * SCR_H
                    clip.append((sx, sy, 1.0 / w, tuv))
                (x0, y0, iw0, uv0), (x1, y1, iw1, uv1), (x2, y2, iw2, uv2) = clip

                minx = max(0, int(math.floor(min(x0, x1, x2))))
                maxx = min(SCR_W - 1, int(math.ceil(max(x0, x1, x2))))
                miny = max(0, int(math.floor(min(y0, y1, y2))))
                maxy = min(SCR_H - 1, int(math.ceil(max(y0, y1, y2))))
                if minx > maxx or miny > maxy:
                    continue

                den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
                if abs(den) < 1e-9:
                    continue

                xs = np.arange(minx, maxx + 1) + 0.5
                ys = np.arange(miny, maxy + 1) + 0.5
                gx, gy = np.meshgrid(xs, ys)

                l0 = ((y1 - y2) * (gx - x2) + (x2 - x1) * (gy - y2)) / den
                l1 = ((y2 - y0) * (gx - x2) + (x0 - x2) * (gy - y2)) / den
                l2 = 1.0 - l0 - l1
                inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
                if not inside.any():
                    continue

                # perspective-correct (u/w, v/w, 1/w) gradients
                U = l0 * uv0[0] * iw0 + l1 * uv1[0] * iw1 + l2 * uv2[0] * iw2
                Vv = l0 * uv0[1] * iw0 + l1 * uv1[1] * iw1 + l2 * uv2[1] * iw2
                W = l0 * iw0 + l1 * iw1 + l2 * iw2
                W = np.maximum(W, 1e-9)

                # analytic screen derivatives (lambdas are affine in (x, y))
                dax = (y1 - y2) / den
                dbx = (y2 - y0) / den
                day = (x2 - x1) / den
                dby = (x0 - x2) / den

                dUdx = dax * uv0[0] * iw0 + dbx * uv1[0] * iw1 - (dax + dbx) * uv2[0] * iw2
                dUdy = day * uv0[0] * iw0 + dby * uv1[0] * iw1 - (day + dby) * uv2[0] * iw2
                dVdx = dax * uv0[1] * iw0 + dbx * uv1[1] * iw1 - (dax + dbx) * uv2[1] * iw2
                dVdy = day * uv0[1] * iw0 + dby * uv1[1] * iw1 - (day + dby) * uv2[1] * iw2
                dWdx = dax * iw0 + dbx * iw1 - (dax + dbx) * iw2
                dWdy = day * iw0 + dby * iw1 - (day + dby) * iw2

                u = U / W
                v = Vv / W
                dudx = (dUdx - u * dWdx) / W
                dudy = (dUdy - u * dWdy) / W
                dvdx = (dVdx - v * dWdx) / W
                dvdy = (dVdy - v * dWdy) / W

                jac = np.abs(dudx * dvdy - dudy * dvdx)
                ratio = np.sqrt(jac) * max(texw, texh)

                frame.tri_areas.append(float(inside.sum()))
                sub = (slice(miny, maxy + 1), slice(minx, maxx + 1))
                frame.add(m.name, sub, inside, np.where(inside, ratio, 0.0))

    return frame, total_tris, culled, clipped


# ── Reporting ────────────────────────────────────────────────────────────────

def report(name, frame, cams, textures, meshes, near, far):
    drawn = frame.pixels
    cover = np.count_nonzero(drawn)
    total = int(drawn.sum())
    px = SCR_W * SCR_H
    t_masks = [(2, 2.0), (4, 4.0), (8, 8.0), (16, 16.0)]
    print(f"\n=== {name} @ cam=({cams[0]:.2f}, {cams[1]:.2f}, {cams[2]:.2f}) yaw={cams[3]:.2f} pitch={cams[4]:.2f} ===")
    print(f"  screen coverage : {cover:6d} px ({100.0*cover/px:5.1f}% of {px})")
    print(f"  fragments drawn : {total:6d} px  -> overdraw {total/max(cover,1):5.2f}x")
    print(f"  fill demand     : {total/px:5.2f} screens/frame")
    for thr, _ in t_masks:
        c = int(np.count_nonzero(frame.thrash > thr))
        print(f"  minified >{thr:2d}x   : {c:6d} px ({100.0*c/max(cover,1):5.1f}% of covered)")
    print(f"  clipper         : guardband-crossing verts x={frame.guard_x} y={frame.guard_y},"
          f" near-split tris {frame.near_split}, behind-near {frame.behind}, offscreen {frame.offscreen}")
    if frame.tri_areas:
        ar = np.array(frame.tri_areas)
        big = np.count_nonzero(ar > 0.25 * px)
        print(f"  triangles       : {len(ar)} drawn, largest {ar.max():.0f} px"
              f" ({100.0*ar.max()/px:.1f}% of screen), >25% screen: {big},"
              f" top-5 share {100.0*ar.sum() and 100.0*np.sort(ar)[-5:].sum()/ar.sum():.1f}%")
    tsum = float(frame.thrash.sum())
    print(f"  sum of sampling rates: {tsum/1e6:6.1f} Mtexel/frame (bilinear x4 = {4*tsum/1e6:.1f} M/frame)")

    print("  --- worst meshes by minified pixels (>2x) ---")
    rows = sorted(frame.by_mesh.items(), key=lambda kv: -kv[1][1])[:8]
    print(f"  {'mesh':32s} {'pixels':>8s} {'>2x':>8s} {'>4x':>8s} {'>8x':>8s}  tex")
    for mname, (p, b2, b4, b8) in rows:
        tid = next((m.tex_id for m in meshes if m.name == mname), -1)
        tn = textures[tid][0] if 0 <= tid < len(textures) else "-"
        print(f"  {mname:32s} {p:8d} {b2:8d} {b4:8d} {b8:8d}  {tn}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pbm")
    ap.add_argument("--cam", nargs=5, type=float, metavar=("X", "Y", "Z", "YAW", "PITCH"))
    ap.add_argument("--preset", action="append", default=None)
    ap.add_argument("--all", action="store_true", help="presets + grid sweep")
    ap.add_argument("--near", type=float, default=0.08)
    ap.add_argument("--far", type=float, default=200.0)
    ap.add_argument("--no-cull", action="store_true")
    args = ap.parse_args()

    textures, meshes = load_pbm(args.pbm)
    nv = sum(len(m.pos) for m in meshes)
    print(f"{args.pbm}: {len(textures)} textures, {len(meshes)} meshes, {nv} verts, {nv//3} tris")
    print(f"projection: fovy=65deg aspect=16:9 near={args.near} far={args.far}  screen={SCR_W}x{SCR_H}")

    views = {}
    if args.cam:
        views["custom"] = tuple(args.cam)
    for p in (args.preset or (list(PRESETS) if not args.cam else [])):
        views[p] = PRESETS[p]
    if args.all:
        for p, v in PRESETS.items():
            views[p] = v
        for cam_y in (0.5, 1.6, 3.0):
            for yaw_i in range(8):
                for pitch in (-0.6, -0.1, 0.4):
                    nm = f"grid y={cam_y} yaw={yaw_i*45} pitch={pitch}"
                    views[nm] = (0.0, cam_y, 2.0, yaw_i * math.pi / 4, pitch)

    summary = []
    for nm, cams in views.items():
        frame, nt, nc, nclip = analyze(textures, meshes, cams[:3], cams[3], cams[4],
                                       args.near, args.far, cull=not args.no_cull)
        report(nm, frame, cams, textures, meshes, args.near, args.far)
        cover = int(np.count_nonzero(frame.pixels))
        summary.append((nm, cover, int(frame.pixels.sum()), float(frame.thrash.sum())))

    print("\n\n=== SUMMARY (fill demand and texel sampling) ===")
    print(f"{'view':22s} {'coverage':>9s} {'fragments':>10s} {'overdraw':>9s} {'Mtexel/frame':>13s}")
    for nm, cover, frag, tsum in sorted(summary, key=lambda r: -r[2]):
        print(f"{nm:22s} {cover:9d} {frag:10d} {frag/max(cover,1):9.2f} {tsum/1e6:13.1f}")


if __name__ == "__main__":
    main()
