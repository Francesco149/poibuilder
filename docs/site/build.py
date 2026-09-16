#!/usr/bin/env python3
"""PoiBuilder docs builder. Stdlib only. Deterministic output."""
from __future__ import annotations

import argparse
import hashlib
import html
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
PAGES = ROOT / "pages"
NAV_FILE = ROOT / "nav.txt"
TEMPLATE = ROOT / "template.html"
OUT = ROOT / "out"
ASSETS = ROOT / "assets"
PLUGIN_CFG = REPO / "project" / "addons" / "poibuilder" / "plugin.cfg"
ACTIONS_GD = REPO / "project" / "addons" / "poibuilder" / "editor" / "pb_actions.gd"
FONT_SRC = REPO / "showcase_video" / "fonts"
ADDON_BUNDLE = REPO / "project" / "addons" / "poibuilder" / "docs-site"

KEY_NAMES = {
    "KEY_H": "H", "KEY_J": "J", "KEY_K": "K", "KEY_X": "X", "KEY_Y": "Y",
    "KEY_G": "G", "KEY_I": "I", "KEY_C": "C", "KEY_L": "L", "KEY_R": "R",
    "KEY_E": "E", "KEY_B": "B", "KEY_6": "6", "KEY_EQUAL": "=", "KEY_MINUS": "-",
    "KEY_BRACKETRIGHT": "]", "KEY_BRACKETLEFT": "[", "KEY_BACKSLASH": "\\",
}

ICONS_SRC = REPO / "project" / "addons" / "poibuilder" / "icons"

# Complete catalog of operations, modes, and tools with toolbar location metadata.
OPS_CATALOG: dict[str, dict] = {
    # Row 1: Mesh Operations
    "extrude": {
        "label": "Extrude", "icon": "icon_extrude.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Shift + Move / Alt + E", "req": "Face or Edge selection",
        "desc": "Extrude selected faces outward along normals, or pull edge fins to extend boundaries."
    },
    "inset": {
        "label": "Inset", "icon": "icon_inset.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Shift + Scale / I", "req": "Face selection",
        "desc": "Insets selected faces, creating an outer border and shrinking the inner face."
    },
    "bevel": {
        "label": "Bevel", "icon": "icon_bevel.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Ctrl + B", "req": "Face or Edge selection",
        "desc": "Chamfer or fillet selected edges or face perimeters into smooth rounded bands."
    },
    "bridge": {
        "label": "Bridge", "icon": "icon_bridge.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + B", "req": "2 open boundary edges",
        "desc": "Connects two open boundary edges with bridging quad faces."
    },
    "connect": {
        "label": "Connect", "icon": "icon_connect.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + E", "req": "2+ vertices or edges",
        "desc": "Inserts an edge connecting selected vertices or edge midpoints."
    },
    "collapse": {
        "label": "Collapse", "icon": "icon_collapse.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + C", "req": "Vertices, edges, or faces",
        "desc": "Collapses selected vertices, edges, or faces to a single geometric center."
    },
    "fill_hole": {
        "label": "Fill Hole", "icon": "icon_fill_hole.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + F", "req": "Open boundary edge loop",
        "desc": "Fills open mesh holes and perimeter loops with a new polygon face."
    },
    "knife": {
        "label": "Knife Tool", "icon": "icon_knife.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "K", "req": "Face selection",
        "desc": "Cuts across faces along an interactive clicked path, splitting geometry."
    },
    "loopcut": {
        "label": "Insert Edge Loop", "icon": "icon_loop_cut.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + R", "req": "Edge selection",
        "desc": "Inserts a continuous edge loop that turns all four corners of a quad mesh."
    },
    "merge": {
        "label": "Merge Faces", "icon": "icon_merge.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + M", "req": "Coplanar faces",
        "desc": "Merges adjacent coplanar faces into a single flat n-gon."
    },
    "subdivide": {
        "label": "Subdivide", "icon": "icon_subdivide.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + S", "req": "Face or edge selection",
        "desc": "Splits selected faces or edges into smaller subdivisions."
    },
    "weld": {
        "label": "Weld Vertices", "icon": "icon_weld.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + V", "req": "2+ vertices",
        "desc": "Welds coincident vertices together within a distance threshold."
    },
    "detach": {
        "label": "Detach Faces", "icon": "icon_detach.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Alt + D", "req": "Face selection",
        "desc": "Detaches selected faces into a separate new PBMesh object."
    },
    "delete": {
        "label": "Delete Elements", "icon": "icon_delete.svg", "row": 1, "row_name": "Row 1 · Mesh Operations",
        "key": "Delete", "req": "Selected elements",
        "desc": "Deletes selected faces, edges, or vertices from the mesh."
    },
    # Row 2: Modes & Docks
    "object": {
        "label": "Object Mode", "icon": "icon_object.svg", "row": 2, "row_name": "Row 2 · Modes & Docks",
        "key": "Click empty / Esc", "req": "Node selection",
        "desc": "Transforms whole PBMesh nodes with the engine transform gizmo."
    },
    "vertex": {
        "label": "Vertex Mode", "icon": "icon_vertex.svg", "row": 2, "row_name": "Row 2 · Modes & Docks",
        "key": "H", "req": "PBMesh active",
        "desc": "Picks and transforms shared vertices with hold-V vertex snapping."
    },
    "edge": {
        "label": "Edge Mode", "icon": "icon_edge.svg", "row": 2, "row_name": "Row 2 · Modes & Docks",
        "key": "J", "req": "PBMesh active",
        "desc": "Picks and transforms common edges; supports Alt-click loop and Shift-Alt ring."
    },
    "face": {
        "label": "Face Mode", "icon": "icon_face.svg", "row": 2, "row_name": "Row 2 · Modes & Docks",
        "key": "K", "req": "PBMesh active",
        "desc": "Picks and transforms faces; Shift-move extrudes and Shift-scale insets live."
    },
    "texture": {
        "label": "Texture Mode", "icon": "icon_texture_mode.svg", "row": 2, "row_name": "Row 2 · Modes & Docks",
        "key": "6", "req": "Face selection",
        "desc": "In-scene 3D viewport planar gizmo to slide, rotate, and scale face UVs live."
    },
    "uv": {
        "label": "UV Editor", "icon": "icon_uv_unwrap.svg", "row": 2, "row_name": "Row 2 · Modes & Docks",
        "key": "Toolbar UV", "req": "PBMesh active",
        "desc": "Opens the dedicated 2D UV canvas panel or floating window with full 2D/3D sync."
    },
    "materials": {
        "label": "Material Dock", "icon": "icon_materials.svg", "row": 2, "row_name": "Row 2 · Modes & Docks",
        "key": "Toolbar Material", "req": "PBMesh active",
        "desc": "Opens the material palette dock for texture assignment, texture splatting, and decals."
    },
    "ngon": {
        "label": "N-Gon Tool", "icon": "icon_ngon.svg", "row": 2, "row_name": "Row 2 · Modes & Docks",
        "key": "Toolbar N-Gon", "req": "None",
        "desc": "Click points on any surface to draw a custom polygon base, Enter to extrude height."
    },
    # Row 3: Selection Suite
    "select_all": {
        "label": "Select All", "icon": "icon_select_all.svg", "row": 3, "row_name": "Row 3 · Selection Suite",
        "key": "Ctrl + A", "req": "Active mode",
        "desc": "Selects all elements of the current mode on the active mesh."
    },
    "invert_selection": {
        "label": "Invert Selection", "icon": "icon_invert_selection.svg", "row": 3, "row_name": "Row 3 · Selection Suite",
        "key": "Ctrl + I", "req": "Active selection",
        "desc": "Inverts selection between unselected and selected elements."
    },
    "grow_selection": {
        "label": "Grow Selection", "icon": "icon_grow_selection.svg", "row": 3, "row_name": "Row 3 · Selection Suite",
        "key": "Alt + G", "req": "Active selection",
        "desc": "Expands the current selection outward by one ring of adjacent elements."
    },
    "shrink_selection": {
        "label": "Shrink Selection", "icon": "icon_shrink_selection.svg", "row": 3, "row_name": "Row 3 · Selection Suite",
        "key": "Shift + Alt + G", "req": "Active selection",
        "desc": "Contracts the current selection by peeling away boundary elements."
    },
    "select_coplanar": {
        "label": "Select Coplanar", "icon": "icon_select_coplanar.svg", "row": 3, "row_name": "Row 3 · Selection Suite",
        "key": "Alt + C", "req": "Face selection",
        "desc": "Flood-selects all adjacent coplanar faces sharing the same geometric plane."
    },
    "face_loop": {
        "label": "Select Face Loop", "icon": "icon_face_loop.svg", "row": 3, "row_name": "Row 3 · Selection Suite",
        "key": "Alt + L", "req": "Face selection",
        "desc": "Selects the full quad-strip face loop passing through the selected face."
    },
    # Row 4: Objects, CSG & Trims
    "poibuilderize": {
        "label": "Poibuilderize", "icon": "icon_poibuilderize.svg", "row": 4, "row_name": "Row 4 · Objects & CSG",
        "key": "Toolbar Poibuilderize", "req": "MeshInstance3D or CSG selected",
        "desc": "Converts any standard MeshInstance3D or CSGShape3D into an editable native PBMesh."
    },
    "csg_subtract": {
        "label": "CSG Subtract", "icon": "icon_csg_subtract.svg", "row": 4, "row_name": "Row 4 · Objects & CSG",
        "key": "Toolbar Subtract", "req": "Target mesh + cutter mesh",
        "desc": "Boolean subtract: cuts the second mesh out of the first mesh with full undo/redo."
    },
    "csg_union": {
        "label": "CSG Union", "icon": "icon_csg_union.svg", "row": 4, "row_name": "Row 4 · Objects & CSG",
        "key": "Toolbar Union", "req": "2 selected meshes",
        "desc": "Boolean union: merges two meshes into a single solid watertight volume."
    },
    "csg_intersect": {
        "label": "CSG Intersect", "icon": "icon_csg_intersect.svg", "row": 4, "row_name": "Row 4 · Objects & CSG",
        "key": "Toolbar Intersect", "req": "2 selected meshes",
        "desc": "Boolean intersection: retains only the overlapping volume of two meshes."
    },
    "trim_walls": {
        "label": "Trim Walls", "icon": "icon_trim_walls.svg", "row": 4, "row_name": "Row 4 · Objects & CSG",
        "key": "Toolbar Trim Walls", "req": "Wall face clicks",
        "desc": "Interactive wall-clicking tool that generates continuous mitred skirting and cornices."
    },
}

ROW_BUTTON_LISTS = {
    1: [
        ("move", "icon_move.svg", "Move"), ("rotate", "icon_rotate.svg", "Rotate"), ("scale", "icon_scale.svg", "Scale"),
        ("extrude", "icon_extrude.svg", "Extrude"), ("inset", "icon_inset.svg", "Inset"),
        ("bevel", "icon_bevel.svg", "Bevel"), ("bridge", "icon_bridge.svg", "Bridge"),
        ("connect", "icon_connect.svg", "Connect"), ("collapse", "icon_collapse.svg", "Collapse"),
        ("fill_hole", "icon_fill_hole.svg", "Fill Hole"), ("knife", "icon_knife.svg", "Knife"),
        ("loopcut", "icon_loop_cut.svg", "Loop Cut"), ("merge", "icon_merge.svg", "Merge"),
        ("subdivide", "icon_subdivide.svg", "Subdivide"), ("weld", "icon_weld.svg", "Weld"),
        ("detach", "icon_detach.svg", "Detach"), ("delete", "icon_delete.svg", "Delete")
    ],
    2: [
        ("object", "icon_object.svg", "Object"), ("vertex", "icon_vertex.svg", "Vertex"),
        ("edge", "icon_edge.svg", "Edge"), ("face", "icon_face.svg", "Face"),
        ("texture", "icon_texture_mode.svg", "Texture"), ("new_shape", "icon_new_shape.svg", "New Shape"),
        ("ngon", "icon_ngon.svg", "N-Gon"), ("edit_params", "icon_edit_params.svg", "Edit Params"),
        ("materials", "icon_materials.svg", "Materials"), ("uv", "icon_uv_unwrap.svg", "UV Editor"),
        ("export", "icon_docs.svg", "Export")
    ],
    3: [
        ("select_all", "icon_select_all.svg", "All"), ("invert_selection", "icon_invert_selection.svg", "Invert"),
        ("grow_selection", "icon_grow_selection.svg", "Grow"), ("shrink_selection", "icon_shrink_selection.svg", "Shrink"),
        ("select_coplanar", "icon_select_coplanar.svg", "Coplanar"), ("select_similar", "icon_select_similar.svg", "Similar"),
        ("select_boundary", "icon_select_boundary.svg", "Boundary"), ("face_loop", "icon_face_loop.svg", "Loop"),
        ("face_ring", "icon_face_ring.svg", "Ring"), ("smooth_auto", "icon_auto_smooth.svg", "Smooth")
    ],
    4: [
        ("merge_objects", "icon_merge_objects.svg", "Merge"), ("mirror", "icon_mirror.svg", "Mirror"),
        ("center_pivot", "icon_center_pivot.svg", "Center"), ("freeze_transform", "icon_freeze_transform.svg", "Freeze"),
        ("poibuilderize", "icon_poibuilderize.svg", "Poibuilderize"), ("csg_union", "icon_csg_union.svg", "Union"),
        ("csg_subtract", "icon_csg_subtract.svg", "Subtract"), ("csg_intersect", "icon_csg_intersect.svg", "Intersect"),
        ("trim_walls", "icon_trim_walls.svg", "Trim Walls")
    ]
}


def render_toolbar_locator(op_id: str, custom_desc: str = "") -> str:
    info = OPS_CATALOG.get(op_id)
    if not info:
        return f"<!-- unknown operation: {html.escape(op_id)} -->"

    row_num = info["row"]
    buttons = ROW_BUTTON_LISTS.get(row_num, [])
    
    btn_html = []
    target_idx = 0
    for idx, (bid, icon_name, name) in enumerate(buttons):
        is_target = (bid == op_id)
        if is_target:
            target_idx = idx
        cls = "tl-btn tl-target" if is_target else "tl-btn"
        ring = '<span class="tl-target-ring"></span>' if is_target else ""
        btn_html.append(
            f'<div class="{cls}" title="{html.escape(name)}">'
            f'<img src="assets/icons/{icon_name}" width="16" height="16" alt="{html.escape(name)}">'
            f'{ring}</div>'
        )

    strip_markup = "".join(btn_html)
    # Button is 28px wide with 3px gap = 31px pitch; padding is ~10px
    target_x = 24 + target_idx * 31

    desc_text = custom_desc if custom_desc else info["desc"]

    svg_arrow = f'''<svg class="tl-arrow-svg">
      <defs>
        <marker id="tl-arr-{op_id}" markerWidth="8" markerHeight="8" refX="5" refY="3" orient="auto">
          <path d="M0 0 L6 3 L0 6 Z" fill="#7c5cff" />
        </marker>
      </defs>
      <path d="M 46 36 C 46 16, {target_x} 24, {target_x} 4"
            fill="none" stroke="#7c5cff" stroke-width="2.4" stroke-linecap="round"
            marker-end="url(#tl-arr-{op_id})" />
    </svg>'''

    key_badge = f'<kbd class="tl-key">{html.escape(info["key"])}</kbd>' if info.get("key") else ""

    return f'''<div class="toolbar-locator">
  <div class="tl-bar-wrapper">
    <div class="tl-bar-header">
      <span class="tl-bar-title"><span class="tl-bar-dot"></span> PoiBuilder Toolbar</span>
      <span class="tl-bar-row">{html.escape(info["row_name"])}</span>
    </div>
    <div class="tl-strip">
      {strip_markup}
    </div>
  </div>
  
  <div class="tl-pointer-track">
    {svg_arrow}
  </div>

  <div class="tl-card">
    <div class="tl-zoom-icon">
      <img src="assets/icons/{info['icon']}" width="38" height="38" alt="{html.escape(info['label'])}">
    </div>
    <div class="tl-card-body">
      <div class="tl-card-header">
        <strong class="tl-card-title">{html.escape(info['label'])}</strong>
        {key_badge}
      </div>
      <p class="tl-card-desc">{inline(desc_text)}</p>
      <div class="tl-card-badges">
        <span class="tl-badge tl-badge-req">✓ {html.escape(info['req'])}</span>
        <span class="tl-badge tl-badge-row">{html.escape(info['row_name'].split('·')[0].strip())}</span>
      </div>
    </div>
  </div>
</div>'''
def plugin_version() -> str:
    text = PLUGIN_CFG.read_text(encoding="utf-8")
    m = re.search(r'^version="([^"]+)"', text, re.M)
    if not m:
        raise SystemExit("plugin.cfg has no version")
    return m.group(1)


def parse_front(text: str) -> tuple[dict, str]:
    meta: dict = {}
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            block = text[4:end]
            body = text[end + 5:]
            for line in block.splitlines():
                if ":" in line:
                    k, v = line.split(":", 1)
                    meta[k.strip()] = v.strip().strip('"')
            return meta, body
    return meta, text


def inline(s: str) -> str:
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", lambda m: f"<code>{m.group(1)}</code>", s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"<em>\1</em>", s)
    s = re.sub(
        r"!\[([^\]]*)\]\(([^)]+)\)",
        lambda m: f'<img src="{m.group(2)}" alt="{m.group(1)}">',
        s,
    )
    s = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>',
        s,
    )
    s = re.sub(r"\[\[kbd:([^\]]+)\]\]", lambda m: "".join(
        f"<kbd>{html.escape(p.strip())}</kbd>" for p in m.group(1).split("+")
    ), s)
    return s


def is_pot_image_missing(src: str, out_dir: Path) -> bool:
    if src.startswith(("http://", "https://", "data:")):
        return False
    return not (out_dir / src).is_file() and not (ASSETS / src).is_file() and not (ASSETS / Path(src).name).is_file()


def render_md(src: str, out_dir: Path, strict: bool) -> str:
    lines = src.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    i = 0
    in_html = 0

    def flush_para(buf: list[str]) -> None:
        if buf:
            out.append("<p>" + inline(" ".join(buf)) + "</p>")
            buf.clear()

    para: list[str] = []
    while i < len(lines):
        line = lines[i]
        if line.strip() == "<!-- KEYS_TABLE -->":
            flush_para(para)
            out.append(keys_table())
            i += 1
            continue
        if line.strip().startswith("<") and not line.strip().startswith("</"):
            flush_para(para)
            chunk = [line]
            tag = re.match(r"</?([a-zA-Z0-9]+)", line.strip())
            name = tag.group(1) if tag else ""
            if name in {"div", "figure", "section", "video", "ol", "ul", "blockquote"} and f"</{name}>" not in line:
                i += 1
                while i < len(lines) and f"</{name}>" not in lines[i]:
                    chunk.append(lines[i])
                    i += 1
                if i < len(lines):
                    chunk.append(lines[i])
            out.append("\n".join(chunk))
            i += 1
            continue
        if line.startswith("```"):
            flush_para(para)
            lang = html.escape(line[3:].strip())
            i += 1
            body: list[str] = []
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            out.append(f'<pre><code class="lang-{lang}">' + html.escape("\n".join(body)) + "</code></pre>")
            i += 1
            continue
        if re.match(r"^:::video\s+", line):
            flush_para(para)
            path = line.split(None, 1)[1].strip()
            cap = ""
            i += 1
            while i < len(lines) and lines[i].strip() != ":::":
                cap += lines[i] + " "
                i += 1
            missing = is_pot_image_missing(path, out_dir)
            if missing:
                if strict:
                    raise SystemExit(f"missing video {path}")
                out.append(f'<figure><div class="placeholder">Clip not built yet — run ./docs/site/build.sh --assets</div><figcaption>{inline(cap.strip())}</figcaption></figure>')
            else:
                out.append(
                    f'<figure><video class="shot" autoplay loop muted playsinline controls src="{html.escape(path)}"></video>'
                    f"<figcaption>{inline(cap.strip())}</figcaption></figure>"
                )
            i += 1
            continue
        if re.match(r"^:::shot\s+", line):
            flush_para(para)
            path = line.split(None, 1)[1].strip()
            cap = ""
            i += 1
            while i < len(lines) and lines[i].strip() != ":::":
                cap += lines[i] + " "
                i += 1
            missing = is_pot_image_missing(path, out_dir)
            if missing:
                if strict:
                    raise SystemExit(f"missing image {path}")
                out.append(f'<figure><div class="placeholder">Screenshot not built yet — run ./docs/site/build.sh --assets</div><figcaption>{inline(cap.strip())}</figcaption></figure>')
            else:
                out.append(
                    f'<figure><img class="shot" src="{html.escape(path)}" alt="{html.escape(cap.strip())}">'
                    f"<figcaption>{inline(cap.strip())}</figcaption></figure>"
                )
            i += 1
        if re.match(r"^:::(?:op|toolbar)\s+", line):
            flush_para(para)
            op_id = line.split(None, 1)[1].strip()
            custom_desc = ""
            i += 1
            while i < len(lines) and lines[i].strip() != ":::":
                custom_desc += lines[i] + " "
                i += 1
            if i < len(lines) and lines[i].strip() == ":::":
                i += 1
            out.append(render_toolbar_locator(op_id, custom_desc.strip()))
            continue
        if line.strip() == "<!-- KEYS_TABLE -->":
            flush_para(para)
            out.append(keys_table())
            i += 1
            continue
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|?\s*-+", lines[i + 1]):
            flush_para(para)
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append([c.strip() for c in lines[i].strip("|").split("|")])
                i += 1
            # drop align row
            head, body = rows[0], rows[2:] if len(rows) > 2 else []
            html_rows = ["<table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead><tbody>"]
            for r in body:
                html_rows.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
            html_rows.append("</tbody></table>")
            out.append("".join(html_rows))
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            flush_para(para)
            lvl = len(m.group(1))
            title = m.group(2).strip()
            slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
            out.append(f'<h{lvl} id="{slug}">{inline(title)}</h{lvl}>')
            i += 1
            continue
        if line.strip() in {"---", "***"}:
            flush_para(para)
            out.append("<hr>")
            i += 1
            continue
        if line.startswith("> "):
            flush_para(para)
            kind = ""
            buf = []
            while i < len(lines) and lines[i].startswith("> "):
                t = lines[i][2:]
                if t.startswith("[gotcha]"):
                    kind = " gotcha"
                    t = t[len("[gotcha]"):].strip()
                elif t.startswith("[limit]"):
                    kind = " limit"
                    t = t[len("[limit]"):].strip()
                buf.append(t)
                i += 1
            out.append(f'<blockquote class="{kind.strip()}">{inline(" ".join(buf))}</blockquote>')
            continue
        if re.match(r"^[-*]\s+", line) or re.match(r"^\d+\.\s+", line):
            flush_para(para)
            ordered = bool(re.match(r"^\d+\.\s+", line))
            cls = "steps" if ordered else ""
            tag = "ol" if ordered else "ul"
            items = []
            while i < len(lines) and (re.match(r"^[-*]\s+", lines[i]) or re.match(r"^\d+\.\s+", lines[i])):
                items.append(re.sub(r"^([-*]|\d+\.)\s+", "", lines[i]))
                i += 1
            cls_attr = f' class="{cls}"' if cls else ""
            out.append(f"<{tag}{cls_attr}>" + "".join(f"<li>{inline(it)}</li>" for it in items) + f"</{tag}>")
            continue
        if not line.strip():
            flush_para(para)
            i += 1
            continue
        para.append(line.strip())
        i += 1
    flush_para(para)
    return "\n".join(out)


def parse_nav() -> list[tuple[str | None, str | None, str]]:
    """Return list of (file_stem or None, href or None, title). Section headers have no href."""
    items = []
    for raw in NAV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.endswith(".md") or ".md " in line:
            path, title = line.split(None, 1)
            stem = Path(path).stem
            items.append((stem, f"{stem}.html", title))
        else:
            items.append((None, None, line))
    return items
def get_page_sections() -> dict[str, str]:
    sections = {}
    cur = "Docs"
    for stem, href, title in parse_nav():
        if href is None:
            cur = title
        else:
            sections[stem] = cur
    return sections


GROUP_GLYPHS = {
    "Start here": "◈",
    "Create": "⬡",
    "Edit": "❖",
    "Surface": "◬",
    "Objects": "⬢",
    "Retro": "▲",
    "Reference": "≡",
}


def nav_html(current: str) -> str:
    chunks = []
    open_group = False
    for stem, href, title in parse_nav():
        if href is None:
            if open_group:
                chunks.append("</div>")
            glyph = GROUP_GLYPHS.get(title, "•")
            chunks.append(f'<div class="group"><div class="group-title"><span class="grp-glyph">{glyph}</span> {html.escape(title)}</div>')
            open_group = True
            continue
        cur = ' class="current"' if stem == current else ""
        chunks.append(f'<a href="{href}"{cur}>{html.escape(title)}</a>')
    if open_group:
        chunks.append("</div>")
    return "\n".join(chunks)


def page_sequence() -> list[tuple[str, str]]:
    return [(stem, title) for stem, href, title in parse_nav() if href]


def pager(stem: str) -> str:
    seq = page_sequence()
    idx = next((i for i, (s, _) in enumerate(seq) if s == stem), None)
    if idx is None:
        return ""
    prev_h = next_h = ""
    if idx > 0:
        s, t = seq[idx - 1]
        prev_h = f'<a class="pager-card pager-prev" href="{s}.html"><span class="dir">← Previous</span><strong class="pager-title">{html.escape(t)}</strong></a>'
    else:
        prev_h = '<div class="pager-spacer"></div>'
    if idx + 1 < len(seq):
        s, t = seq[idx + 1]
        next_h = f'<a class="pager-card pager-next" href="{s}.html"><span class="dir">Next →</span><strong class="pager-title">{html.escape(t)}</strong></a>'
    else:
        next_h = '<div class="pager-spacer"></div>'
    return f'<div class="pager-grid">{prev_h}{next_h}</div>'

def keys_table() -> str:
    text = ACTIONS_GD.read_text(encoding="utf-8")
    rows = []
    for m in re.finditer(
        r'"([^"]+)":\s*\{\s*"label":\s*"([^"]+)",\s*"keys":\s*(\[\[.*?\]\]|\[\])',
        text,
        re.S,
    ):
        aid, label, keys = m.group(1), m.group(2), m.group(3)
        if keys.strip() == "[]":
            shortcut = "—"
        else:
            parts = []
            for spec in re.finditer(r"\[(KEY_[A-Z0-9]+),\s*(\d),\s*(\d),\s*(\d)\]", keys):
                name, ctrl, shift, alt = spec.group(1), spec.group(2), spec.group(3), spec.group(4)
                chord = []
                if ctrl == "1":
                    chord.append("Ctrl")
                if shift == "1":
                    chord.append("Shift")
                if alt == "1":
                    chord.append("Alt")
                chord.append(KEY_NAMES.get(name, name.replace("KEY_", "")))
                parts.append("+".join(chord))
            shortcut = " or ".join(parts) if parts else "—"
        if shortcut == "—":
            kbd = "—"
        else:
            kbd = " ".join(
                "".join(f"<kbd>{html.escape(x)}</kbd>" for x in ch.split("+"))
                for ch in shortcut.split(" or ")
            )
        rows.append((label, kbd, aid))
    body = "".join(
        f"<tr><td>{html.escape(label)}</td><td>{kbd}</td><td><code>{html.escape(aid)}</code></td></tr>"
        for label, kbd, aid in rows
    )
    return (
        "<table><thead><tr><th>Action</th><th>Default</th><th>Id</th></tr></thead>"
        f"<tbody>{body}</tbody></table>"
    )



def copy_static(out: Path) -> None:
    shutil.copy2(ROOT / "style.css", out / "style.css")
    (out / ".nojekyll").write_text("", encoding="utf-8")
    if (ROOT / "favicon.svg").is_file():
        shutil.copy2(ROOT / "favicon.svg", out / "favicon.svg")
    font_dir = out / "fonts"
    font_dir.mkdir(exist_ok=True)
    src = FONT_SRC / "Inter-Variable.ttf"
    if src.is_file():
        shutil.copy2(src, font_dir / "Inter-Variable.ttf")
        ofl = FONT_SRC / "OFL.txt"
        if ofl.is_file():
            shutil.copy2(ofl, font_dir / "OFL.txt")
    out_assets_icons = out / "assets" / "icons"
    out_assets_icons.mkdir(parents=True, exist_ok=True)
    if ICONS_SRC.is_dir():
        for f in ICONS_SRC.glob("*.svg"):
            shutil.copy2(f, out_assets_icons / f.name)
    if ASSETS.is_dir():
        for child in sorted(ASSETS.iterdir()):
            dest = out / child.name if child.suffix.lower() in {".png", ".jpg", ".webp", ".svg"} else out / child.name
            if child.is_file():
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(child, out / child.name)
            elif child.is_dir():
                target = out / child.name
                if target.exists():
                    shutil.rmtree(target)
                shutil.copytree(child, target)


def collect_internal_hrefs(html_text: str) -> list[str]:
    return re.findall(r'(?:href|src)="([^"]+)"', html_text)


def link_check(out: Path, strict: bool) -> int:
    broken = 0
    for page in sorted(out.glob("*.html")):
        text = page.read_text(encoding="utf-8")
        for href in collect_internal_hrefs(text):
            if href.startswith(("http://", "https://", "mailto:", "#")):
                continue
            path = href.split("#", 1)[0]
            if not path:
                continue
            target = (page.parent / path).resolve()
            if not target.is_file():
                print(f"BROKEN {page.name} -> {href}")
                broken += 1
    if broken and strict:
        return 1
    print(f"link check: {broken} missing target(s)")
    return 0 if not strict else (1 if broken else 0)


def build(strict: bool = False, bundle: bool = False) -> int:
    version = plugin_version()
    tpl = TEMPLATE.read_text(encoding="utf-8")
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    copy_static(OUT)

    pages = sorted(PAGES.glob("*.md"))
    if not pages:
        raise SystemExit("no pages in docs/site/pages")
    page_sections = get_page_sections()

    for md in pages:
        meta, body = parse_front(md.read_text(encoding="utf-8"))
        stem = md.stem
        title = meta.get("title") or stem.replace("-", " ").title()
        lead = meta.get("lead", "")
        body_class = "has-hero" if meta.get("hero") == "true" else ""
        hero = ""
        if meta.get("hero") == "true":
            hero = (
                f'<header class="hero"><h1>{html.escape(title)}</h1>'
                f'<p class="lead">{html.escape(lead)}</p>'
                '<div class="hero-actions">'
                '<a class="btn btn-cyan" href="first-minutes.html">Build a cube in 60 seconds</a>'
                '<a class="btn btn-ghost" href="install.html">Install</a>'
                "</div></header>"
            )
            content = render_md(body, OUT, strict)
        else:
            content = f"<h1>{html.escape(title)}</h1>"
            if lead:
                content += f'<p class="lead">{html.escape(lead)}</p>'
            content += render_md(body, OUT, strict)
        html_out = (
            tpl.replace("{{title}}", html.escape(title))
            .replace("{{version}}", html.escape(version))
            .replace("{{section}}", html.escape(page_sections.get(stem, "Docs")))
            .replace("{{lead}}", html.escape(lead or title))
            .replace("{{body_class}}", body_class)
            .replace("{{nav}}", nav_html(stem))
            .replace("{{hero}}", hero)
            .replace("{{content}}", content)
            .replace("{{prev}}", "")  # filled below via pager combined
            .replace("{{next}}", pager(stem))
        )
        (OUT / f"{stem}.html").write_text(html_out, encoding="utf-8", newline="\n")

    rc = link_check(OUT, strict)
    print(f"built {len(list(OUT.glob('*.html')))} pages for PoiBuilder {version} -> {OUT}")
    if bundle:
        if ADDON_BUNDLE.exists():
            shutil.rmtree(ADDON_BUNDLE)
        shutil.copytree(OUT, ADDON_BUNDLE)
        print(f"bundled -> {ADDON_BUNDLE}")
    return rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--bundle", action="store_true")
    args = ap.parse_args()
    return build(strict=args.strict, bundle=args.bundle)


if __name__ == "__main__":
    sys.exit(main())
