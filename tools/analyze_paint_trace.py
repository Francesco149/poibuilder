#!/usr/bin/env python3
"""Analyze a PBPaintTrace session (/tmp/pb_paint_trace.log).

Turns the per-frame trace of a live paint session into the jank story:
frame-time distribution, hitch attribution (paint handler vs render/editor),
input-to-drawn latency, and an ASCII timeline so a stutter rhythm is visible.
Stdlib only. Exit code 0 always (a report, not a test).
"""
import re
import statistics
import sys

FRAME = re.compile(r"^F f=(\d+) dt=([\d.]+)(?: in=([\d.]+))?(?: ev=(\d+))?(?: h=([\d.]+))?(.*)$")
KV = re.compile(r"(\w+)=([\d.]+)(?:/(\d+))?")
BUDGET = 16.7  # 60 fps


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pb_paint_trace.log"
    frames = []          # dicts: dt, in, ev, h, stages{}, px
    strokes = []         # dicts: wall, label
    sessions = 0
    header = ""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("# session"):
                    sessions += 1
                    header = header or line[2:]
                    frames = []          # only analyze the LAST session
                    strokes = []
                elif line.startswith("#S session begin"):
                    frames = []
                    strokes = []
                elif line.startswith("#S end wall="):
                    m = re.match(r"#S end wall=([\d.]+) (.*)", line)
                    if m:
                        strokes.append({"wall": float(m.group(1)), "label": m.group(2)})
                elif line.startswith("F "):
                    m = FRAME.match(line)
                    if not m:
                        continue
                    fr = {
                        "f": int(m.group(1)), "dt": float(m.group(2)),
                        "in": float(m.group(3)) if m.group(3) else None,
                        "ev": int(m.group(4) or 0), "h": float(m.group(5) or 0.0),
                        "stages": {}, "px": 0,
                    }
                    for k, v, n in KV.findall(m.group(6) or ""):
                        if k == "px":
                            fr["px"] = int(float(v))
                        else:
                            fr["stages"][k] = (float(v), int(n or 0))
                    frames.append(fr)
    except FileNotFoundError:
        print(f"no trace at {path} — run ./trace_paint.sh (or any editor with "
              f"PB_PAINT_TRACE=1) and paint first")
        return 0
    if not frames:
        print(f"trace at {path} holds no frames — was a paint mode active? ({header or 'no header'})")
        return 0

    dts = [f["dt"] for f in frames]
    dur = sum(dts) / 1000.0
    print(f"== PB paint trace: {path} ==")
    print(f"{header}   |   sessions-in-file analyzed: last of {sessions}")
    print(f"paint-active window: {dur:.1f}s, {len(frames)} drawn frames")
    if strokes:
        walls = [s["wall"] for s in strokes]
        print(f"strokes: {len(strokes)}  wall ms: mean {statistics.mean(walls):.1f}  "
              f"max {max(walls):.1f}  (all: {' '.join(f'{w:.0f}' for w in walls)})")

    def pct(xs, p):
        xs = sorted(xs)
        return xs[min(len(xs) - 1, int(len(xs) * p))]

    print(f"frame ms: mean {statistics.mean(dts):.1f}  p50 {pct(dts, .5):.1f}  "
          f"p90 {pct(dts, .9):.1f}  p99 {pct(dts, .99):.1f}  max {max(dts):.1f}")
    over = [d for d in dts if d > BUDGET]
    over2 = [d for d in dts if d > 2 * BUDGET]
    print(f"budget {BUDGET}ms: {len(over)} frames over ({100.0 * len(over) / len(dts):.1f}%), "
          f"{len(over2)} over 2x budget")

    ins = [f["in"] for f in frames if f["in"] is not None and f["ev"] > 0]
    if ins:
        print(f"input->drawn latency (frames that delivered events): mean {statistics.mean(ins):.1f}  "
              f"p90 {pct(ins, .9):.1f}  max {max(ins):.1f} ms  (n={len(ins)})")

    # Hitch attribution: what was inside the long frames? Frames with NO
    # events and NO paint stages are silent gaps (window unfocused / editor
    # stall) — reported separately, never attributed to the paint path.
    hitches = [f for f in frames if f["dt"] > 25.0]
    attributable = [f for f in hitches if f["ev"] > 0 or f["stages"]]
    silent = [f for f in hitches if not (f["ev"] > 0 or f["stages"])]
    handler_bound, render_bound = [], []
    for f in attributable:
        dab = f["stages"].get("dab_total", (0, 0))[0] + f["stages"].get("splat_dab", (0, 0))[0]
        total = dab + f["stages"].get("handler", (0, 0))[0] + f["stages"].get("interp_walk", (0, 0))[0]
        (handler_bound if total > 0.6 * f["dt"] else render_bound).append(f)
    print(f"hitches > 25ms: {len(hitches)} attributable (paint-handler-bound: {len(handler_bound)}, "
          f"render/editor-side: {len(render_bound)}) + {len(silent)} silent gaps "
          f"(no events, no paint stages — window idle/stall, not paint jank)")
    top = sorted(attributable, key=lambda f: -f["dt"])[:12]
    if top:
        print("worst frames (dt | paint handler share | what ran inside):")
        for f in top:
            inner = " ".join(f"{k}={v[0]:.1f}ms" for k, v in sorted(f["stages"].items(),
                             key=lambda kv: -kv[1][0]) if v[0] > 0.3)
            if not inner:
                inner = f"px={f['px']}" if f["px"] else "(no paint stage — render/editor cost)"
            share = 100.0 * min(f["h"], f["dt"]) / f["dt"]
            print(f"  dt={f['dt']:7.1f}ms  handler={share:5.1f}%  ev={f['ev']}  {inner}")

    # ASCII timeline: one char per frame (sampled to ~240 chars), around the whole window.
    if len(dts) > 3:
        step = max(1, len(dts) // 240)
        strip = "".join(
            "." if d <= BUDGET else "-" if d <= 25 else "+" if d <= 50 else "#" if d <= 200 else "@"
            for d in dts[::step])
        print("timeline (per frame: '.' <=16ms  '-' 16-25  '+' 25-50  '#' 50-200  '@' >200):")
        for i in range(0, len(strip), 120):
            print("  " + strip[i:i + 120])

    # Verdict
    dab_frames = [f for f in frames if f["stages"].get("dab_total", (0, 0))[0] > 15.0]
    print("verdict:", end=" ")
    if not attributable:
        print("no attributable hitches in this window"
              + (f" ({len(silent)} silent gaps excluded)" if silent else "") + ".")
    elif handler_bound and len(handler_bound) >= len(render_bound):
        print("jank is PAINT-HANDLER-BOUND: long frames are long because the dab/walk "
              "pixel work blocks the main thread inside the plugin.")
    elif render_bound:
        print("jank is RENDER/EDITOR-SIDE: the long frames carry almost no paint handler "
              "work — look at redraw/GPU cost (adapter, scene, viewport), not the paint loop.")
    else:
        print("no significant hitches in this window.")
    if dab_frames:
        gaps = [b["f"] - a["f"] for a, b in zip(dab_frames, dab_frames[1:]) if b["f"] > a["f"]]
        cadence = f", cadence ~every {statistics.mean(gaps):.0f} painted frames" if gaps else ""
        print(f"  heavy dab frames (>15ms of dab work): {len(dab_frames)}{cadence}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
