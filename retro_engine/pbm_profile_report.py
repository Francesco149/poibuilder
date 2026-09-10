#!/usr/bin/env python3
"""Turn a PoiRetro on-device profile log into a verdict.

Reads ms0:/poi_profile.txt (produced by psp_prof.c) and reports:

  * the camera sweep, worst first — where the frame budget actually goes
  * the ablation deltas at each measured camera: how many ms each pipeline
    stage (textures, texture cache footprint, mip chain, filtering, depth,
    culling, clip planes, near plane, billboards, HUD) costs per frame
  * a calibration check: the synthetic probes give the machine's per-fragment
    and per-draw-call cost, so the scene's own cost can be predicted from its
    measured fragment count and compared with what it really costs. A large
    unexplained remainder is the signature of a locality/bandwidth term that
    per-fragment throughput cannot account for.

Usage: python3 pbm_profile_report.py poi_profile.txt [--fragments 165695,135486,...]
"""

import argparse
import re
import sys

ROW = re.compile(
    r"^(?P<name>[\w.+-]+)\s+cpu=\s*(?P<cpu>[\d.]+)\s+gpu=\s*(?P<gpu>[\d.]+)\s+"
    r"frame=\s*(?P<frame>[\d.]+)\s+maxfps=\s*(?P<fps>[\d.]+)\s+draws=\s*(?P<draws>\d+)\s+"
    r"verts=\s*(?P<verts>\d+)")
SWEEP = re.compile(
    r"^sweep:(?P<name>\S+)\s+cpu=\s*(?P<cpu>[\d.]+)\s+gpu=\s*(?P<gpu>[\d.]+)\s+"
    r"frame=\s*(?P<frame>[\d.]+)\s+maxfps=\s*(?P<fps>[\d.]+)")
HDR = re.compile(r"^(map|frames|textures)")

# ablation name -> (what it removes, the row it is compared against)
ABLATIONS = {
    "abi_notex":          ("texture sampling", "scene_stairs"),
    "abi_tex64":          ("texture *cache footprint* (64x64 stand-in)", "scene_stairs"),
    "abi_nomip":          ("mip chain (A/B for the fix)", "scene_stairs"),
    "abi_mipmap_nearest": ("filtering taps (nearest-mipmin vs linear-mipmin)", "scene_stairs"),
    "abi_filt_nearest":   ("minification filtering (nearest vs linear)", "scene_stairs"),
    "abi_nodepth":        ("depth test", "scene_stairs"),
    "abi_nocull":         ("face culling", "scene_stairs"),
    "abi_noclip":         ("GE clip planes", "scene_stairs"),
    "abi_near050":        ("tight 0.08 near plane (vs 0.5)", "scene_stairs"),
    "abi_noalpha":        ("billboard alpha pass", "scene_stairs"),
    "abi_noentity":       ("scripted entity", "scene_stairs"),
    "abi_nohud":          ("2D HUD", "scene_stairs"),
    "abi_vertcol":        ("textures (vertex-colour mode)", "scene_stairs"),
    "abi_wire":           ("filled triangles (wireframe mode)", "scene_stairs"),
    "abi2_notex":         ("texture sampling", "scene_below_up"),
    "abi2_tex64":         ("texture *cache footprint* (64x64 stand-in)", "scene_below_up"),
    "abi2_nomip":         ("mip chain (A/B for the fix)", "scene_below_up"),
    "abi2_filt_nearest":  ("minification filtering", "scene_below_up"),
    "abi2_noclip":        ("GE clip planes", "scene_below_up"),
    "abi2_near050":       ("tight 0.08 near plane", "scene_below_up"),
    "abi2_alpha_off":     ("billboard alpha pass", "scene_below_up"),
}


def parse(path):
    rows, sweeps, header = {}, [], []
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        m = ROW.match(line)
        if m:
            rows[m["name"]] = {k: float(m[k]) for k in ("cpu", "gpu", "frame", "fps")} | {
                "draws": int(m["draws"]), "verts": int(m["verts"])}
            continue
        m = SWEEP.match(line)
        if m:
            sweeps.append({k: (m[k] if k == "name" else float(m[k]))
                           for k in ("name", "cpu", "gpu", "frame", "fps")})
            continue
        if HDR.match(line):
            header.append(line)
    return rows, sweeps, header


def show_sweep(sweeps):
    if not sweeps:
        return
    print("\n=== camera sweep: worst frame cost first (ms) ===")
    print(f"{'pose':<16}{'cpu':>8}{'gpu':>8}{'frame':>8}{'max fps':>10}")
    for r in sorted(sweeps, key=lambda r: -r["frame"]):
        flag = "  <-- over the 16.67 ms budget" if r["frame"] > 16.67 else ""
        print(f"{r['name']:<16}{r['cpu']:8.2f}{r['gpu']:8.2f}{r['frame']:8.2f}{r['fps']:10.1f}{flag}")


def show_ablations(rows):
    print("\n=== ablation deltas (ms/frame saved by removing the stage) ===")
    by_base = {}
    for name, (label, base) in ABLATIONS.items():
        if name not in rows or base not in rows:
            continue
        by_base.setdefault(base, []).append(
            (label, name, rows[base]["gpu"] - rows[name]["gpu"],
             rows[base]["cpu"] - rows[name]["cpu"]))
    for base, items in by_base.items():
        print(f"\n-- vs {base} (gpu={rows[base]['gpu']:.2f} ms, "
              f"cpu={rows[base]['cpu']:.2f} ms, frame={rows[base]['frame']:.2f} ms) --")
        print(f"{'stage removed':<50}{'gpu saved':>11}{'cpu saved':>11}")
        for label, name, dg, dc in sorted(items, key=lambda t: -t[2]):
            mark = " **" if dg > 1.0 else ""
            print(f"{label:<50}{dg:11.2f}{dc:11.2f}{mark}")


def show_probes(rows):
    probes = [k for k in rows if k.startswith(("fill", "clear", "min512", "mag",
                                               "drawcalls", "tris"))]
    if not probes:
        return
    print("\n=== synthetic probes (device calibration) ===")
    print(f"{'probe':<22}{'cpu':>8}{'gpu':>8}{'frame':>8}{'draws':>8}{'verts':>8}")
    for k in sorted(probes):
        r = rows[k]
        print(f"{k:<22}{r['cpu']:8.2f}{r['gpu']:8.2f}{r['frame']:8.2f}"
              f"{r['draws']:8d}{r['verts']:8d}")
    base = rows.get("clear_only")
    if base is None:
        return
    print(f"\nclear_only (the per-frame floor: clear + swap): frame {base['frame']:.2f} ms")
    for probe, frags in (("fill2d_1x_plain", 130560), ("fill2d_4x_plain", 4 * 130560),
                         ("fill2d_1x_tex512", 130560), ("fill2d_4x_tex512_d", 4 * 130560),
                         ("fill2d_4x_tex64_d", 4 * 130560)):
        if probe not in rows:
            continue
        # linear fit through clear_only isolates the probe's own per-frame cost
        ms = rows[probe]["frame"] - base["frame"]
        if ms > 0:
            print(f"  {probe:<20} {ms:6.2f} ms for {frags:>7} fragments -> "
                  f"{frags / ms / 1000.0:6.2f} Mfrag/s  ({ms * 166.0 / frags:4.1f} cycles/frag @166MHz)")


def verdict(rows):
    print("\n=== verdict ===")
    if "scene_stairs" not in rows:
        print("no scene_stairs row; cannot form a verdict")
        return
    b = rows["scene_stairs"]
    print(f"scene_stairs frame={b['frame']:.2f} ms  (cpu {b['cpu']:.2f} / gpu {b['gpu']:.2f})")
    cpu_share = 100.0 * b["cpu"] / max(b["frame"], 0.001)
    print(f"  CPU share of the frame: {cpu_share:.0f}%  -> "
          f"{'CPU-bound (display-list construction)' if cpu_share > 55 else 'GPU-bound'}")

    def d(name):
        return b["gpu"] - rows[name]["gpu"] if name in rows else None

    terms = [("textures (sampling at all)", d("abi_notex")),
             ("texture cache footprint", d("abi_tex64")),
             ("minification filtering taps", d("abi_filt_nearest")),
             ("depth test", d("abi_nodepth")),
             ("clip planes", d("abi_noclip")),
             ("near plane 0.08 vs 0.5", d("abi_near050")),
             ("billboard alpha pass", d("abi_noalpha")),
             ("HUD", d("abi_nohud"))]
    terms = [(n, v) for n, v in terms if v is not None]
    for n, v in sorted(terms, key=lambda t: -t[1]):
        if v > 0.3:
            print(f"  {n:<32} {v:6.2f} ms")
    if "abi_nomip" in rows:
        gain = rows["abi_nomip"]["gpu"] - b["gpu"]
        print(f"  mip chain benefit (nomip - current): {gain:+.2f} ms"
              f"{'  <-- the fix is working' if gain > 1.0 else '  <-- the fix is NOT paying off'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    args = ap.parse_args()
    rows, sweeps, header = parse(args.log)
    if not rows:
        sys.exit(f"{args.log}: no measurement rows found")
    for h in header:
        print(h)
    show_sweep(sweeps)
    show_ablations(rows)
    show_probes(rows)
    verdict(rows)


if __name__ == "__main__":
    main()
