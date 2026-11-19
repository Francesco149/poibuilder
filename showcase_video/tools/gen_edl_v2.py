"""showcase_video/tools/gen_edl_v2.py — Writes showcase_video/edl_v2.toml (README cut) and edl_v2_long.toml (YouTube /
Asset Library cut) from one clip spec, reading every take's real length from
the session manifests so a re-render cannot silently break the timing."""
import json, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BAKE = REPO / "showcase_video" / "bake"
CROP = [287, 44, 1633, 918]          # toolbar + 3D view + dock, 16:9
_len = {}

def shot_len(src):
    sess, shot = src.split(":")
    if sess not in _len:
        m = json.load(open(BAKE / sess / "manifest.json"))
        _len[sess] = {s["name"]: s["frames"] / 60.0 for s in m["shots"]}
    return _len[sess][shot]

def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

SPEED = {"long": 1.0}

def clip(cid, src, at=0.0, dur=None, tail=0.0, caps=(), crop=CROP, speed=None, **kw):
    """at < 0 counts from the end; dur None = to the end of the take minus
    `tail`. `dur` is OUTPUT time: at speed s the clip walks dur*s of source."""
    n = shot_len(src)
    sp = speed if speed is not None else SPEED["long"]
    start = n + at if at < 0 else at
    if dur is None:
        dur = (n - start - tail) / sp
    dur = round(min(dur, (n - start) / sp) - 0.02, 2)
    if sp != 1.0:
        kw = dict(kw, speed=sp)
    out = [f'[[clip]]', f'id = {q(cid)}', f'source = {q(src)}', f'at = {round(start, 2)}',
           f'dur = {dur}', f'crop = {crop}']
    for k, v in kw.items():
        out.append(f'{k} = {json.dumps(v) if not isinstance(v, bool) else str(v).lower()}')
    if caps:
        out.append('captions = [')
        for c in caps:
            label, text, cat = c[0], c[1], c[2]
            cdur = f', dur = {c[3]}' if len(c) > 3 else ''
            # Bottom-centre: bottom-left is where PoiBuilder's floating panel
            # (selection readout, parameter modals) lives.
            out.append(f'  {{ label = {q(label)}, text = {q(text)}, at = {cat}{cdur}, pos = "bc" }},')
        out.append(']')
    return "\n".join(out), dur

def card(cid, dur, card_dict, **kw):
    body = ", ".join(f'{k} = {q(v) if isinstance(v, str) else "[" + ", ".join(q(x) for x in v) + "]"}'
                     for k, v in card_dict.items())
    out = [f'[[clip]]', f'id = {q(cid)}', 'kind = "card"', f'dur = {dur}', 'cursor = false']
    for k, v in kw.items():
        out.append(f'{k} = {v}')
    out.append(f'card = {{ {body} }}')
    return "\n".join(out), dur

GRADE = '{ contrast = 1.10, saturation = 1.22, gamma = 0.93, brightness = -0.015 }'

def psp(cid, at, dur, caps=(), extra=""):
    out = [f'[[clip]]', f'id = {q(cid)}', 'kind = "video"', 'file = "psp-seashore.mp4"',
           f'at = {at}', f'dur = {dur}', 'cursor = false', f'grade = {GRADE}']
    if extra:
        out.append(extra)
    if caps:
        out.append('captions = [')
        for c in caps:
            out.append(f'  {{ label = {q(c[0])}, text = {q(c[1])}, at = {c[2]} }},')
        out.append(']')
    return "\n".join(out), dur

TITLE = {"kicker": "Godot 4 editor plugin", "title": "PoiBuilder", "sub": "Build levels inside the editor"}
END = {"kicker": "Free and open source", "title": "PoiBuilder",
       "sub": "ProBuilder-style level building for Godot 4",
       "bullets": ["Pure GDScript: drop the addon in and enable it",
                   "Modern glTF export, and a retro export that runs on a real PSP",
                   "github.com/Francesco149/poibuilder"]}

def header(name, out_dir, master, readme, poster, comment):
    return f'''# {comment}
#
# GENERATED from one clip spec (both cuts share the takes); every `dur` is
# the take's real length from the session manifests. Sessions:
#   project/showcase/sessions/v2_{{create,edit,surface,tools,map}}.gd
# Render (all five, pinned layout):
#   PB_SHOWCASE_LAYOUT=showcase_video/layouts/tour.cfg ./showcase_video/render.sh v2_edit   (etc.)
# Regenerate (after a re-render): python3 showcase_video/tools/gen_edl_v2.py
# Build:
#   ./showcase_video/build.sh --edl showcase_video/{name}
#
# One framing for every editor clip: crop {CROP} = the PoiBuilder
# toolbar (when shown), the 3D view and the Material & UV dock, exactly 16:9.

[project]
name = "{out_dir}"
width = 1280
height = 720
fps = 60
readme_width = 960
out_dir = "{out_dir}"
master = "{master}"
readme = "{readme}"
poster = "{poster}"
'''

def write(path, head, clips):
    total = sum(d for _, d in clips)
    body = "\n\n".join(c for c, _ in clips)
    Path(path).write_text(head + f"\n# total {total:.1f} s\n\n" + body + "\n")
    print(f"{path}: {len(clips)} clips, {total:.1f} s")

# ---------------------------------------------------------------- LONG
# The editor chapters run 15% fast in the long cut: the pointer still reads
# as a hand, and four minutes of takes come down to about three and a half.
SPEED["long"] = 1.15
L = []
L.append(card("l00-title", 2.0, TITLE, fade_in=0.3, fade_out=0.3))
# No teaser montage: the owner cut it ("skip the short clips at the beginning
# and jump into the functionality showcase") — the title goes straight to Create.
# CREATE
L.append(clip("l10-cube", "v2_create:v2c/cube", fade_in=0.25,
              caps=[("Create", "Pick a shape in the dock, drag it out, pull its height", 0.2)]))
L.append(clip("l11-surfaces", "v2_create:v2c/surfaces",
              caps=[("Create", "The same drag on a wall, or on a slope: it grows along the surface", 0.1)]))
L.append(clip("l12-stairs", "v2_create:v2c/stairs",
              caps=[("Parameters", "Stairs with a live preview: the steps update as you type", 0.2)]))
L.append(clip("l13-reedit", "v2_create:v2c/reedit",
              caps=[("Parameters", "Re-open any placed shape: 12 steps become 20", 0.2)]))
L.append(clip("l14-door", "v2_create:v2c/door",
              caps=[("Create", "An arched doorway, straight from its parameters", 0.2)]))
L.append(clip("l15-edge", "v2_create:v2c/edge", tail=0.8,
              caps=[("New", "Edge-first placement: click an edge at any angle, then depth and height", 0.2)]))
L.append(clip("l16-lineup", "v2_create:v2c/lineup", at=1.2, tail=0.6,
              caps=[("Shapes", "Every primitive is generated from parameters", 0.2)]))
# EDIT
L.append(clip("l20-modes", "v2_edit:v2e/modes",
              caps=[("Select", "Vertex, edge, face. The doorway's front is ONE n-gon, arch and all", 0.2)]))
L.append(clip("l21-portal", "v2_edit:v2e/portal", tail=1.2,
              caps=[("Extrude", "Shift+drag the whole n-gon: the arch deepens with it", 0.1, 2.6),
                    ("Extrude", "Extrude, scale, extrude, taper: a cornice and a roof", 2.9)]))
L.append(clip("l22-chimney", "v2_edit:v2e/chimney",
              caps=[("Inset", "Inset, extrude, inset, extrude down: a hollow chimney", 0.2)]))
L.append(clip("l23-loopcut", "v2_edit:v2e/loopcut", tail=0.5,
              caps=[("Loop cut", "One loop round all four sides; Alt+click selects it, a drag slides it", 0.2)]))
L.append(clip("l24-subdiv", "v2_edit:v2e/subdiv",
              caps=[("Subdivide", "Split a face in four, then pull one quarter out", 0.2)]))
L.append(clip("l25-merge", "v2_edit:v2e/merge",
              caps=[("Merge", "Two faces become one, and move as one", 0.2)]))
L.append(clip("l26-crease", "v2_edit:v2e/crease",
              caps=[("Merge", "Even across a crease: one bent n-gon", 0.2)]))
L.append(clip("l27-bevel", "v2_edit:v2e/bevel",
              caps=[("Bevel", "Live preview: the width, then the segments", 0.2)]))
L.append(clip("l28-weld", "v2_edit:v2e/weld",
              caps=[("Weld", "Two corners welded into one: the cube becomes a wedge", 0.2)]))
L.append(clip("l29-cube", "v2_edit:v2e/cube",
              caps=[("Delete & detach", "Open the box, then lift a face off as its own object", 0.2)]))
L.append(clip("l30-knife", "v2_edit:v2e/knife",
              caps=[("Knife", "Cut any path across a face, then extrude one side", 0.2)]))
L.append(clip("l31-ngon", "v2_edit:v2e/ngon",
              caps=[("N-gon", "Draw any polygon, then pull up its height", 0.2)]))
L.append(clip("l32-smart", "v2_edit:v2e/smart",
              caps=[("Select", "Face loop, grow, shrink, coplanar, invert", 0.2)]))
# SURFACES
L.append(clip("l40-card", "v2_surface:v2s/card",
              caps=[("Materials", "Select a face, click a card", 0.2)]))
L.append(clip("l41-drop", "v2_surface:v2s/drop",
              caps=[("Materials", "...or filter the palette and drag a card onto any face", 0.1)]))
L.append(clip("l42-scroll", "v2_surface:v2s/scroll",
              caps=[("Animated", "A scroll speed on a face: the water flows live in the editor", 0.2)]))
L.append(clip("l43-uv", "v2_surface:v2s/uv", crop=[0, 0, 1920, 1080],
              caps=[("UV editor", "Rotate, flip and project UVs; the 3D view follows", 0.2)]))
L.append(clip("l44-paint", "v2_surface:v2s/paint",
              caps=[("Paint", "Brush texture layers onto any surface", 0.2)]))
L.append(clip("l45-stamp", "v2_surface:v2s/stamp",
              caps=[("Stamp", "Press decals into the surface", 0.2)]))
L.append(clip("l46-sprite", "v2_surface:v2s/sprite",
              caps=[("Sprites", "Billboards: click, raise, scale", 0.2)]))
L.append(clip("l47-particles", "v2_surface:v2s/particles",
              caps=[("Particles", "Click to place an emitter: fire, mist, embers", 0.2)]))
# TOOLS
L.append(clip("l50-trim", "v2_tools:v2t/trim",
              caps=[("Trim", "A skirting in one drag, with a rounded profile", 0.2)]))
L.append(clip("l51-trimwalls", "v2_tools:v2t/trimwalls",
              caps=[("Trim Walls", "Click the walls: one run, mitred at every corner", 0.2)]))
L.append(clip("l52-csg", "v2_tools:v2t/csg",
              caps=[("CSG", "Subtract, Ctrl+Z, Ctrl+Shift+Z: booleans with real undo", 0.2)]))
L.append(clip("l53-import", "v2_tools:v2t/import",
              caps=[("Poibuilderize", "Any imported GLB becomes a mesh you can edit", 0.2)]))
# MAP
L.append(clip("l60-fly", speed=1.0, src="v2_map:v2m/fly",
              caps=[("A whole map", "Splats, decals, a waterfall, emitters, billboards: all live in the editor", 0.3)]))
L.append(clip("l61-env", speed=1.0, src="v2_map:v2m/env",
              caps=[("Time of day", "One click re-lights the whole map", 0.4)]))
L.append(clip("l62-export", speed=1.0, src="v2_map:v2m/export", fade_out=0.3,
              caps=[("Export", "...and one click to a retro .pbm map", 0.2)]))
# HARDWARE
L.append(psp("l70-psp-beach", 0.4, 2.6, [("Hardware", "Exported to a real Sony PSP: a whole bay at 60 fps", 0.2)],
             'zoom = [1.0, 1.04]\nfade_in = 0.25'))
L.append(psp("l71-psp-surf", 3.6, 3.0, [("Water", "Rolling swell, breaking surf and spray, animated by the PSP's GPU", 0.2)]))
L.append(psp("l72-psp-rocks", 15.8, 2.8, [("Effects", "Foam rings and splashes timed to every wave", 0.2)]))
L.append(psp("l73-psp-palms", 24.4, 2.8, [("Wind", "Palms sway, and their shadows sway with them", 0.2)]))
L.append(psp("l74-psp-hud", 46.5, 2.6, [("Measured", "60 fps on the device, around 12,800 triangles a frame", 0.2)],
             'crop = [400, 150, 1100, 619]\nzoom = [1.0, 1.04]'))
L.append(psp("l75-psp-glitter", 55.0, 3.0, (), 'zoom = [1.0, 1.03]\nfade_out = 0.4'))
L.append(card("l90-end", 3.0, END, fade_in=0.3, fade_out=0.5))

# ---------------------------------------------------------------- SHORT
SPEED["long"] = 1.0
S = []
S.append(card("s00-title", 1.6, TITLE, fade_in=0.3, fade_out=0.3))
S.append(clip("s10-door", "v2_create:v2c/door", at=0.4, fade_in=0.2,
              caps=[("Create", "Pick a shape in the dock, drag it out", 0.15)]))
S.append(clip("s11-edge", "v2_create:v2c/edge", at=1.0, dur=4.6,
              caps=[("New", "Edge-first placement: any angle", 0.15)]))
S.append(clip("s20-ngon", "v2_edit:v2e/modes", at=-2.4,
              caps=[("Select", "The doorway's front is one n-gon", 0.1)]))
S.append(clip("s21-portal", "v2_edit:v2e/portal", tail=4.4,
              caps=[("Extrude", "Shift+drag it out, then a cornice and a roof", 0.1)]))
S.append(clip("s22-chimney", "v2_edit:v2e/chimney", at=1.0, dur=5.0,
              caps=[("Inset", "Inset and extrude: a hollow chimney", 0.1)]))
S.append(clip("s23-loopcut", "v2_edit:v2e/loopcut", at=0.9, dur=3.6,
              caps=[("Loop cut", "Round all four sides", 0.1)]))
S.append(clip("s24-bevel", "v2_edit:v2e/bevel", at=1.0, dur=4.2,
              caps=[("Bevel", "With a live preview", 0.1)]))
S.append(clip("s30-drop", "v2_surface:v2s/drop",
              caps=[("Materials", "Drag a card onto any face", 0.1)]))
S.append(clip("s31-paint", "v2_surface:v2s/paint", at=1.0, dur=3.6,
              caps=[("Paint", "Texture layers, brushed on", 0.1)]))
S.append(clip("s32-fire", "v2_surface:v2s/particles", at=-2.6,
              caps=[("Particles", "Emitters in one click", 0.1)]))
S.append(clip("s40-trimwalls", "v2_tools:v2t/trimwalls", at=-4.2, dur=3.4,
              caps=[("Trim Walls", "Mitred at every corner", 0.1)]))
S.append(clip("s41-csg", "v2_tools:v2t/csg", at=1.0, dur=3.4,
              caps=[("CSG", "Booleans with real undo", 0.1)]))
S.append(clip("s50-night", "v2_map:v2m/env", at=0.8, dur=3.4, fade_out=0.3,
              caps=[("Time of day", "One click re-lights the map", 0.1)]))
S.append(psp("s70-psp-beach", 0.4, 2.6, [("Hardware", "Exported to a real Sony PSP: a whole bay at 60 fps", 0.2)],
             'zoom = [1.0, 1.04]\nfade_in = 0.25'))
S.append(psp("s71-psp-surf", 3.6, 3.0, [("Water", "Swell, surf and spray, animated by the PSP's GPU", 0.2)]))
S.append(psp("s74-psp-hud", 46.5, 2.4, [("Measured", "60 fps on the device", 0.2)],
             'crop = [400, 150, 1100, 619]\nzoom = [1.0, 1.04]\nfade_out = 0.3'))
S.append(card("s90-end", 2.4, END, fade_in=0.3, fade_out=0.5))

write(REPO / "showcase_video/edl_v2_long.toml",
      header("edl_v2_long.toml", "out_v2_long", "poibuilder-showcase-v2-long.mp4",
             "poibuilder-showcase-v2-long-960.mp4", "poibuilder-showcase-v2-long-poster.png",
             "Showcase v2, LONG cut (YouTube, Godot Asset Library): every chapter in full."), L)
write(REPO / "showcase_video/edl_v2.toml",
      header("edl_v2.toml", "out_v2", "poibuilder-showcase-v2.mp4",
             "poibuilder-showcase-v2-960.mp4", "poibuilder-showcase-v2-poster.png",
             "Showcase v2, SHORT cut (the README video): the payoff of each chapter."), S)
