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
    # The waterfall foot — the app's worst view, where the scene is the same
    # 1526 triangles and 27 draw calls as the spawn view, so every delta here is
    # per-fragment work and nothing else.
    "wf_notex":           ("texture sampling", "wf_base"),
    "wf_tex64":           ("texture *cache footprint* (64x64 stand-in)", "wf_base"),
    "wf_nomip":           ("mip chain", "wf_base"),
    "wf_vertcol":         ("textures (vertex-colour mode)", "wf_base"),
    "wf_wire":            ("filled triangles (wireframe mode)", "wf_base"),
    "wf_noemit":          ("both emitters", "wf_base"),
    "wf_blend_only":      ("additive emitters only (blended still drawn)", "wf_base"),
    "wf_add_only":        ("blended emitter only (additive still drawn)", "wf_base"),
    "wf_noscroll":        ("animated UV scroll", "wf_base"),
    "wf_noclip":          ("GE clip planes", "wf_base"),
    "wf_nodepth":         ("depth test", "wf_base"),
    "wf_nocull":          ("face culling", "wf_base"),
    "wf_noalpha":         ("the whole transparent pass (water + foliage)", "wf_base"),
    "wf_skip_wetwall":    ("the wet courtyard wall", "wf_base"),
    "wf_skip_sheet":      ("the waterfall sheet", "wf_base"),
    "wf_skip_core":       ("the waterfall core", "wf_base"),
    "wf_skip_spray":      ("the spray billboard", "wf_base"),
    "wf_skip_pool":       ("the ripple pool", "wf_base"),
    "wf_skip_foam":       ("the foam ribbon", "wf_base"),
    "wf_skip_allwater":   ("every water surface at once", "wf_base"),
    "wf_skip_tiles":      ("the tiling base-material chunks", "wf_base"),
    "wf_skip_floor":      ("the floor splat layer", "wf_base"),
    "wf_skip_atlas":      ("the baked tile atlas quads", "wf_base"),
}

# LOD policy curve, measured at the waterfall foot. The level the GE picks is
# per-primitive and the cache is ~8 KB, so this is where "sample it sharper"
# stops being free — and it stops hard (a cache cliff, not a slope).
LOD_POLICY = [
    ("wf_const0",         "const level 0 (no chain use at all)"),
    ("wf_old_default",    "trilinear, bias -1.0   <-- the replaced default"),
    ("wf_filt_miplin",    "mip_linear, bias -1.0"),
    ("wf_filt_nearest",   "nearest, bias -1.0"),
    ("wf_filt_miplin_b0", "mip_linear, bias  0.0"),
    ("wf_bias_p05",       "mip_linear, bias +0.5"),
    ("wf_near_p1",        "nearest, bias +1.0"),
    ("wf_bias_p1",        "mip_linear, bias +1.0"),
    ("wf_base",           "the shipped default (mip_linear, bias +1.0)"),
    ("wf_tri_p1",         "trilinear, bias +1.0"),
    ("wf_bias_p2",        "mip_linear, bias +2.0"),
    ("wf_bias_p3",        "mip_linear, bias +3.0"),
    ("wf_const3",         "const level 3"),
    ("wf_const4",         "const level 4"),
]


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


def show_lod_policy(rows):
    present = [(k, label) for k, label in LOD_POLICY if k in rows]
    if not present:
        return
    print("\n=== LOD policy at the waterfall foot (the app's worst view) ===")
    for k, label in present:
        r = rows[k]
        flag = "  <-- OVER the 16.67 ms budget" if r["frame"] > 16.67 else ""
        print(f"  {label:<52}{r['gpu']:7.2f} gpu{r['frame']:8.2f} frame{flag}")


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
    if "wf_base" in rows:
        w = rows["wf_base"]
        ok = w["frame"] <= 16.67
        print(f"\nworst view (waterfall foot) frame={w['frame']:.2f} ms "
              f"(cpu {w['cpu']:.2f} / gpu {w['gpu']:.2f})"
              f"  {'-> inside the 16.67 ms budget' if ok else '-> OVER BUDGET'}")
        if "wf_old_default" in rows:
            print(f"  the replaced LOD policy (trilinear, bias -1.0) costs "
                  f"{rows['wf_old_default']['frame'] - w['frame']:+.2f} ms more on that same view")


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
    show_lod_policy(rows)
    show_probes(rows)
    verdict(rows)


if __name__ == "__main__":
    main()
