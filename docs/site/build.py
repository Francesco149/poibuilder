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
    # ── Row 1 ────────────────────────────────────────────────────────────────
    "split_rows": {
        "label": "Extended Tools", "icon": "icon_split_rows.svg", "row": 1, "group": "header",
        "row_name": "Row 1 · Header", "key": "—", "req": "Nothing (always enabled)",
        "desc": "Shows or folds Rows 3 & 4 (extended tools). The state is remembered across sessions."
    },
    "move": {
        "label": "Move", "icon": "icon_move.svg", "row": 1, "group": "tools",
        "row_name": "Row 1 · Tools", "key": "W", "req": "A selection",
        "desc": "The plugin's own move tool: drag elements or the whole object on the gizmo axes."
    },
    "rotate": {
        "label": "Rotate", "icon": "icon_rotate.svg", "row": 1, "group": "tools",
        "row_name": "Row 1 · Tools", "key": "E", "req": "A selection",
        "desc": "Rotate the selection around the gizmo rings; orientation space follows the Space button."
    },
    "scale": {
        "label": "Scale", "icon": "icon_scale.svg", "row": 1, "group": "tools",
        "row_name": "Row 1 · Tools", "key": "R", "req": "A selection",
        "desc": "Axis handles scale freely; the CENTER square scales all axes together (Shift + center on faces insets)."
    },
    "env": {
        "label": "Time of Day", "icon": "icon_env.svg", "row": 1, "group": "env",
        "row_name": "Row 1 · Environment", "key": "—", "req": "Nothing (always enabled)",
        "desc": "Quick environment presets: Dawn, Day, Dusk, Night. Export stores the preset name."
    },
    "extrude": {
        "label": "Extrude", "icon": "icon_extrude.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Alt + E / Shift + Move", "req": "Face or edge selection",
        "desc": "Extrudes selected faces along their normal; in edge mode it pulls edge fins. Shift+Move does it live."
    },
    "inset": {
        "label": "Inset", "icon": "icon_inset.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Alt + I / Shift + Scale", "req": "Face selection",
        "desc": "Insets the selected faces (an outer border around a shrunken copy). Shift+Scale does it live."
    },
    "bevel": {
        "label": "Bevel", "icon": "icon_bevel.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Ctrl + B", "req": "Edge or face selection",
        "desc": "Chamfers or fillets selected edges (or face perimeters) with a live distance/segments modal."
    },
    "bridge": {
        "label": "Bridge", "icon": "icon_bridge.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Alt + B", "req": "2 open boundary edges",
        "desc": "Connects two open boundary edges with a face."
    },
    "connect": {
        "label": "Connect", "icon": "icon_connect.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "Edges or vertices",
        "desc": "Inserts an edge connecting edge midpoints (or selected vertices)."
    },
    "collapse": {
        "label": "Collapse", "icon": "icon_collapse.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "Vertices, edges, or faces",
        "desc": "Collapses the selected elements to a single point."
    },
    "fill_hole": {
        "label": "Fill Hole", "icon": "icon_fill_hole.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "An open boundary",
        "desc": "Caps open boundary loops with a new face."
    },
    "knife": {
        "label": "Knife", "icon": "icon_knife.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "A face to cut",
        "desc": "Cuts faces by placing vertices; Enter completes the cut."
    },
    "loopcut": {
        "label": "Loop Cut", "icon": "icon_loop_cut.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "An edge crossing a quad ring",
        "desc": "Inserts an edge loop through the ring of quads crossed by the selected edge."
    },
    "merge": {
        "label": "Merge", "icon": "icon_merge.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "Edge-adjacent faces",
        "desc": "Merges edge-adjacent selected faces into one n-gon."
    },
    "subdivide": {
        "label": "Subdiv", "icon": "icon_subdivide.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "Quad faces",
        "desc": "Subdivides the selected quads into four."
    },
    "weld": {
        "label": "Weld", "icon": "icon_weld.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "2+ vertices",
        "desc": "Welds the selected vertices together at their centroid."
    },
    "detach": {
        "label": "Detach", "icon": "icon_detach.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "Face selection",
        "desc": "Detaches the selected faces into a new PBMesh node."
    },
    "delete": {
        "label": "Del", "icon": "icon_delete.svg", "row": 1, "group": "ops",
        "row_name": "Row 1 · Mesh Operations", "key": "Unbound (rebindable)", "req": "Face selection",
        "desc": "Deletes the selected faces."
    },
    # ── Row 2 ────────────────────────────────────────────────────────────────
    "object": {
        "label": "Object", "icon": "icon_object.svg", "row": 2, "group": "modes",
        "row_name": "Row 2 · Selection Modes", "key": "Unbound (rebindable)", "req": "Nothing",
        "desc": "Object mode: whole-object transforms; clicking selects other nodes natively."
    },
    "vertex": {
        "label": "Vertex", "icon": "icon_vertex.svg", "row": 2, "group": "modes",
        "row_name": "Row 2 · Selection Modes", "key": "H", "req": "A PBMesh",
        "desc": "Vertex mode: pick and move shared vertices; hold V to snap to nearby mesh vertices."
    },
    "edge": {
        "label": "Edge", "icon": "icon_edge.svg", "row": 2, "group": "modes",
        "row_name": "Row 2 · Selection Modes", "key": "J", "req": "A PBMesh",
        "desc": "Edge mode: pick and move edges; Alt-click walks a loop, Shift-Alt-click a ring."
    },
    "face": {
        "label": "Face", "icon": "icon_face.svg", "row": 2, "group": "modes",
        "row_name": "Row 2 · Selection Modes", "key": "K", "req": "A PBMesh",
        "desc": "Face mode: pick and move faces; Shift+Move extrudes and Shift+Scale insets live."
    },
    "texture": {
        "label": "Texture", "icon": "icon_texture_mode.svg", "row": 2, "group": "modes",
        "row_name": "Row 2 · Selection Modes", "key": "6", "req": "Face selection",
        "desc": "Texture/material mode: transform UVs directly on the 3D geometry."
    },
    "space": {
        "label": "Space", "icon": "icon_space.svg", "row": 2, "group": "space",
        "row_name": "Row 2 · Orientation", "key": "X", "req": "Nothing",
        "desc": "Cycles the gizmo orientation space: Element, Object, World."
    },
    "new_shape": {
        "label": "New Shape", "icon": "icon_new_shape.svg", "row": 2, "group": "shapes",
        "row_name": "Row 2 · Shapes", "key": "—", "req": "Nothing (always enabled)",
        "desc": "Arms primitive creation: drag the base on any surface, set the height, click to confirm."
    },
    "ngon": {
        "label": "N-Gon", "icon": "icon_ngon.svg", "row": 2, "group": "shapes",
        "row_name": "Row 2 · Shapes", "key": "—", "req": "Nothing (always enabled)",
        "desc": "Draws a custom polygon, then extrudes it into 3D (Enter sizes the height)."
    },
    "edit_params": {
        "label": "Edit Params", "icon": "icon_edit_params.svg", "row": 2, "group": "shapes",
        "row_name": "Row 2 · Shapes", "key": "—", "req": "A pristine factory shape",
        "desc": "Re-opens the creation parameters of the selected shape (until it is hand-edited)."
    },
    "materials": {
        "label": "Material & UV", "icon": "icon_materials.svg", "row": 2, "group": "docks",
        "row_name": "Row 2 · Docks", "key": "—", "req": "Nothing",
        "desc": "Focuses the Material & UV dock: palette, splat painting, stamps, sprites, particles."
    },
    "uv": {
        "label": "UV", "icon": "icon_uv_unwrap.svg", "row": 2, "group": "docks",
        "row_name": "Row 2 · Docks", "key": "—", "req": "A PBMesh",
        "desc": "Opens the dedicated 2D UV editor panel in the bottom dock."
    },
    "panel": {
        "label": "Panel", "icon": "icon_panel.svg", "row": 2, "group": "docks",
        "row_name": "Row 2 · Docks", "key": "—", "req": "Nothing",
        "desc": "Pins the floating overlay panel on (it otherwise auto-hides when nothing is selected)."
    },
    "recover": {
        "label": "Reset Panel", "icon": "icon_panel_reset.svg", "row": 2, "group": "docks",
        "row_name": "Row 2 · Docks", "key": "—", "req": "Nothing",
        "desc": "Recovers the overlay panel and dock to the bottom-left corner if they were dragged away."
    },
    "settings": {
        "label": "Settings", "icon": "icon_settings.svg", "row": 2, "group": "docks",
        "row_name": "Row 2 · Docks", "key": "—", "req": "Nothing",
        "desc": "Display settings: grid, wireframe, selection and hover opacity."
    },
    "export": {
        "label": "Export...", "icon": "icon_export.svg", "row": 2, "group": "exportgrp",
        "row_name": "Row 2 · Export", "key": "—", "req": "Nothing (always enabled)",
        "desc": "Opens the export dialog: PBM (the retro .pbm map, default) or GLB — modern bake (lightmap-ready) or retro baked (vertex-lit) — with the bake options."
    },
    "docs": {
        "label": "Docs", "icon": "icon_docs.svg", "row": 2, "group": "exportgrp",
        "row_name": "Row 2 · Export", "key": "—", "req": "Nothing (always enabled)",
        "desc": "Opens the bundled offline documentation (the site you are reading)."
    },
    # ── Row 3 ────────────────────────────────────────────────────────────────
    "grid": {
        "label": "Grid", "icon": "icon_grid.svg", "row": 3, "group": "grid",
        "row_name": "Row 3 · Grid", "key": "= / - subdiv · [ / ] elevation · Y snap · G draw-on-grid", "req": "Nothing (always enabled)",
        "desc": "Opens the grid & snapping settings; the readout beside it shows the current snap step."
    },
    "select_all": {
        "label": "All", "icon": "icon_select_all.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Unbound (rebindable)", "req": "An element mode",
        "desc": "Selects all elements of the current mode."
    },
    "invert_selection": {
        "label": "Invert", "icon": "icon_invert_selection.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Ctrl + I", "req": "A selection",
        "desc": "Inverts the element selection."
    },
    "grow_selection": {
        "label": "Grow", "icon": "icon_grow_selection.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Alt + G", "req": "A selection",
        "desc": "Grows the selection by one ring of adjacent elements."
    },
    "shrink_selection": {
        "label": "Shrink", "icon": "icon_shrink_selection.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Shift + Alt + G", "req": "A selection",
        "desc": "Shrinks the selection to its boundary."
    },
    "select_coplanar": {
        "label": "Coplanar", "icon": "icon_select_coplanar.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Alt + C", "req": "Face selection",
        "desc": "Selects all adjacent coplanar faces."
    },
    "select_similar": {
        "label": "Similar", "icon": "icon_select_similar.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Unbound (rebindable)", "req": "Face selection",
        "desc": "Selects faces with matching material."
    },
    "select_boundary": {
        "label": "Boundary", "icon": "icon_select_boundary.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Unbound (rebindable)", "req": "A PBMesh",
        "desc": "Selects the open boundary edges."
    },
    "face_loop": {
        "label": "Loop", "icon": "icon_face_loop.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Alt + L", "req": "Face selection",
        "desc": "Selects the quad strip face loop through the selection."
    },
    "face_ring": {
        "label": "Ring", "icon": "icon_face_ring.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Alt + R", "req": "Face selection",
        "desc": "Selects the perpendicular quad face ring."
    },
    "smooth_auto": {
        "label": "Auto Smooth", "icon": "icon_auto_smooth.svg", "row": 3, "group": "selection",
        "row_name": "Row 3 · Selection Suite", "key": "Unbound (rebindable)", "req": "A PBMesh",
        "desc": "Auto-smooths faces by dihedral angle (45°)."
    },
    "obj_lit": {
        "label": "Lit", "icon": "icon_lit.svg", "row": 3, "group": "state",
        "row_name": "Row 3 · Object State", "key": "Unbound (rebindable)", "req": "Selected objects",
        "desc": "Shading on/off for every selected object. Mixed selections render unchecked; checking synchronizes all of them."
    },
    "obj_shadow": {
        "label": "Cast Shadows", "icon": "icon_shadow.svg", "row": 3, "group": "state",
        "row_name": "Row 3 · Object State", "key": "Unbound (rebindable)", "req": "Selected objects",
        "desc": "Shadow casting on/off for every selected object. Same mixed-checkbox semantics as Lit."
    },
    # ── Row 4 ────────────────────────────────────────────────────────────────
    "vertex_snap": {
        "label": "V-Snap", "icon": None, "row": 4, "group": "snap",
        "row_name": "Row 4 · Snapping", "key": "Hold V (toggle available)", "req": "A drag",
        "desc": "Snaps dragged elements to the nearest mesh vertex (or hold V during a drag)."
    },
    "proportional": {
        "label": "Soft", "icon": None, "row": 4, "group": "snap",
        "row_name": "Row 4 · Snapping", "key": "Unbound (rebindable)", "req": "A selection",
        "desc": "Proportional editing: a move also drags nearby unselected vertices with a smooth falloff (radius beside the toggle)."
    },
    "merge_objects": {
        "label": "Merge Objs", "icon": "icon_merge_objects.svg", "row": 4, "group": "objtools",
        "row_name": "Row 4 · Object Tools", "key": "Unbound (rebindable)", "req": "2+ selected PBMeshes",
        "desc": "Merges the selected PBMesh nodes into one."
    },
    "mirror": {
        "label": "Mirror", "icon": "icon_mirror.svg", "row": 4, "group": "objtools",
        "row_name": "Row 4 · Object Tools", "key": "Unbound (rebindable)", "req": "A PBMesh",
        "desc": "Mirrors the object's geometry across local X (winding corrected)."
    },
    "center_pivot": {
        "label": "Center Pivot", "icon": "icon_center_pivot.svg", "row": 4, "group": "objtools",
        "row_name": "Row 4 · Object Tools", "key": "Unbound (rebindable)", "req": "A PBMesh",
        "desc": "Moves the pivot to the bounding-box center: the geometry stays put, the node origin moves (works in Object mode)."
    },
    "freeze_transform": {
        "label": "Freeze Xform", "icon": "icon_freeze_transform.svg", "row": 4, "group": "objtools",
        "row_name": "Row 4 · Object Tools", "key": "Unbound (rebindable)", "req": "A transformed PBMesh",
        "desc": "Bakes the node transform into vertex positions and resets the transform to identity."
    },
    "poibuilderize": {
        "label": "Poibuilderize", "icon": "icon_poibuilderize.svg", "row": 4, "group": "objtools",
        "row_name": "Row 4 · Object Tools", "key": "Unbound (rebindable)", "req": "A MeshInstance3D or CSG node",
        "desc": "Converts any MeshInstance3D or CSG shape (including CSGCombiner3D) into an editable PBMesh."
    },
    "csg_union": {
        "label": "CSG Union", "icon": "icon_csg_union.svg", "row": 4, "group": "csg",
        "row_name": "Row 4 · CSG Booleans", "key": "Unbound (rebindable)", "req": "2+ selected meshes",
        "desc": "Solid union of the selected meshes (select target first, cutter last)."
    },
    "csg_subtract": {
        "label": "CSG Subtract", "icon": "icon_csg_subtract.svg", "row": 4, "group": "csg",
        "row_name": "Row 4 · CSG Booleans", "key": "Unbound (rebindable)", "req": "Target + cutter selected",
        "desc": "Subtracts the LAST-selected mesh from the FIRST-selected mesh."
    },
    "csg_intersect": {
        "label": "CSG Intersect", "icon": "icon_csg_intersect.svg", "row": 4, "group": "csg",
        "row_name": "Row 4 · CSG Booleans", "key": "Unbound (rebindable)", "req": "2+ selected meshes",
        "desc": "Solid intersection of the selected meshes."
    },
    "trim_walls": {
        "label": "Trim Walls", "icon": "icon_trim_walls.svg", "row": 4, "group": "trimwalls",
        "row_name": "Row 4 · Trim Walls", "key": "Enter applies · Esc cancels", "req": "Wall faces to click",
        "desc": "Click wall faces to sweep mitred trim along them (teal hover, amber chosen)."
    },
}

# Toolbar button groups, mirroring `_update_row_layout` in editor/pb_toolbar.gd.
# (op_id, icon-or-None, short label) — text-only toolbar buttons carry None
# and render as their label in the locator strips.
GROUP_BUTTON_LISTS: dict[str, list] = {
    "header": [("split_rows", "icon_split_rows.svg", "Extended Tools")],
    "tools": [
        ("move", "icon_move.svg", "Move"), ("rotate", "icon_rotate.svg", "Rotate"),
        ("scale", "icon_scale.svg", "Scale"),
    ],
    "ops": [
        ("extrude", "icon_extrude.svg", "Extrude"), ("inset", "icon_inset.svg", "Inset"),
        ("bevel", "icon_bevel.svg", "Bevel"), ("bridge", "icon_bridge.svg", "Bridge"),
        ("connect", "icon_connect.svg", "Connect"), ("collapse", "icon_collapse.svg", "Collapse"),
        ("fill_hole", "icon_fill_hole.svg", "Fill Hole"), ("knife", "icon_knife.svg", "Knife"),
        ("loopcut", "icon_loop_cut.svg", "Loop Cut"), ("merge", "icon_merge.svg", "Merge"),
        ("subdivide", "icon_subdivide.svg", "Subdiv"), ("weld", "icon_weld.svg", "Weld"),
        ("detach", "icon_detach.svg", "Detach"), ("delete", "icon_delete.svg", "Del"),
    ],
    "env": [("env", "icon_env.svg", "Time of Day")],
    "modes": [
        ("object", "icon_object.svg", "Object"), ("vertex", "icon_vertex.svg", "Vertex"),
        ("edge", "icon_edge.svg", "Edge"), ("face", "icon_face.svg", "Face"),
        ("texture", "icon_texture_mode.svg", "Texture"),
    ],
    "space": [("space", "icon_space.svg", "Element")],
    "shapes": [
        ("new_shape", "icon_new_shape.svg", "New Shape"), ("ngon", "icon_ngon.svg", "N-Gon"),
        ("edit_params", "icon_edit_params.svg", "Edit Params"),
    ],
    "docks": [
        ("materials", "icon_materials.svg", "Material & UV"), ("uv", "icon_uv_unwrap.svg", "UV"),
        ("panel", "icon_panel.svg", "Panel"), ("recover", "icon_panel_reset.svg", "Reset Panel"),
        ("settings", "icon_settings.svg", "Settings"),
    ],
    "exportgrp": [
        ("export", "icon_export.svg", "Export..."), ("docs", "icon_docs.svg", "Docs"),
    ],
    "grid": [("grid", "icon_grid.svg", "Grid")],
    "selection": [
        ("select_all", "icon_select_all.svg", "All"), ("invert_selection", "icon_invert_selection.svg", "Invert"),
        ("grow_selection", "icon_grow_selection.svg", "Grow"), ("shrink_selection", "icon_shrink_selection.svg", "Shrink"),
        ("select_coplanar", "icon_select_coplanar.svg", "Coplanar"), ("select_similar", "icon_select_similar.svg", "Similar"),
        ("select_boundary", "icon_select_boundary.svg", "Boundary"), ("face_loop", "icon_face_loop.svg", "Loop"),
        ("face_ring", "icon_face_ring.svg", "Ring"), ("smooth_auto", "icon_auto_smooth.svg", "Auto Smooth"),
    ],
    "state": [("obj_lit", "icon_lit.svg", "Lit"), ("obj_shadow", "icon_shadow.svg", "Cast Shadows")],
    "snap": [("vertex_snap", None, "V-Snap"), ("proportional", None, "Soft")],
    "objtools": [
        ("merge_objects", "icon_merge_objects.svg", "Merge Objs"), ("mirror", "icon_mirror.svg", "Mirror"),
        ("center_pivot", "icon_center_pivot.svg", "Center Pivot"), ("freeze_transform", "icon_freeze_transform.svg", "Freeze Xform"),
        ("poibuilderize", "icon_poibuilderize.svg", "Poibuilderize"),
    ],
    "csg": [
        ("csg_union", "icon_csg_union.svg", "CSG Union"), ("csg_subtract", "icon_csg_subtract.svg", "CSG Subtract"),
        ("csg_intersect", "icon_csg_intersect.svg", "CSG Intersect"),
    ],
    "trimwalls": [("trim_walls", "icon_trim_walls.svg", "Trim Walls")],
}

# Legacy row strips (kept for any catalog entry without a group).
ROW_BUTTON_LISTS = {}
for _entries in GROUP_BUTTON_LISTS.values():
    for _bid, _icon, _label in _entries:
        _row = OPS_CATALOG.get(_bid, {}).get("row")
        ROW_BUTTON_LISTS.setdefault(_row, [])
        if all(b[0] != _bid for b in ROW_BUTTON_LISTS[_row]):
            ROW_BUTTON_LISTS[_row].append((_bid, _icon, _label))


def _locator_strip(buttons: list, op_id: str) -> tuple[str, int]:
    """Renders one toolbar group's buttons as mini tiles; returns (html, target_index)."""
    btn_html = []
    target_idx = 0
    for idx, (bid, icon_name, name) in enumerate(buttons):
        is_target = (bid == op_id)
        if is_target:
            target_idx = idx
        cls = "tl-btn tl-target" if is_target else "tl-btn"
        ring = '<span class="tl-target-ring"></span>' if is_target else ""
        if icon_name:
            inner = (f'<img src="assets/icons/{html.escape(icon_name)}" width="16" height="16" '
                     f'alt="{html.escape(name)}" title="{html.escape(name)}">')
        else:
            inner = f'<span class="tl-btn-text">{html.escape(name)}</span>'
        # SPAN, not div: these tiles ride inside inline button-reference
        # tooltips (inside <p>), where a div would get the paragraph — and
        # this markup — auto-closed by the HTML parser.
        btn_html.append(f'<span class="{cls}" title="{html.escape(name)}">{inner}{ring}</span>')
    return "".join(btn_html), target_idx


def render_toolbar_locator(op_id: str, custom_desc: str = "") -> str:
    info = OPS_CATALOG.get(op_id)
    if not info:
        return f"<!-- unknown operation: {html.escape(op_id)} -->"

    group_id = info.get("group")
    if group_id and group_id in GROUP_BUTTON_LISTS:
        buttons = GROUP_BUTTON_LISTS[group_id]
    else:
        buttons = ROW_BUTTON_LISTS.get(info["row"], [])
    
    strip_markup, target_idx = _locator_strip(buttons, op_id)
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
def render_btn_ref(op_id: str, label: str = "") -> str:
    """Inline button reference: the button word carries a hover/click tooltip
    holding a mini locator — its toolbar group strip with the button ringed,
    its row, key, requirement and one-line description. CSS-only (no JS):
    opens on :hover and :focus (the word is keyboard-focusable)."""
    info = OPS_CATALOG.get(op_id)
    if not info:
        return f'<!-- unknown button: {html.escape(op_id)} -->'
    word = label if label else info["label"]
    group_id = info.get("group")
    buttons = GROUP_BUTTON_LISTS.get(group_id, []) if group_id else []
    strip_markup, _ = _locator_strip(buttons, op_id)
    icon_img = ""
    if info.get("icon"):
        icon_img = (f'<img class="br-ico" src="assets/icons/{html.escape(info["icon"])}" '
                    f'width="13" height="13" alt="">')
    pop_icon = (f'<img src="assets/icons/{html.escape(info["icon"])}" width="26" height="26" alt="">'
                if info.get("icon") else "")
    key_badge = f'<kbd class="br-key">{html.escape(info["key"])}</kbd>' if info.get("key") and info["key"] != "—" else ""
    row_name = info.get("row_name", "")
    return (
        f'<span class="btnref" tabindex="0">{icon_img}{html.escape(word)}'
        f'<span class="br-pop">'
        f'<span class="br-strip">{strip_markup}</span>'
        f'<span class="br-row">{html.escape(row_name)}</span>'
        f'<span class="br-head">{pop_icon}<span class="br-title">{html.escape(info["label"])}</span>{key_badge}</span>'
        f'<span class="br-desc">{inline(info["desc"])}</span>'
        f'<span class="br-req">Needs: {html.escape(info["req"])}</span>'
        f'</span></span>'
    )


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

def _format_kbd(raw: str) -> str:
    raw = raw.strip()
    if raw == "\\\\":
        raw = "\\"
    if raw == "+":
        parts = ["+"]
    elif "+" in raw:
        parts = [p.strip() for p in raw.split("+") if p.strip()]
    else:
        parts = [raw]
    return "".join(f"<kbd>{html.escape(p)}</kbd>" for p in parts)
ICON_ALIASES: dict[str, str] = {
    "move": "icon_move.svg",
    "rotate": "icon_rotate.svg",
    "scale": "icon_scale.svg",
    "extrude": "icon_extrude.svg",
    "inset": "icon_inset.svg",
    "bevel": "icon_bevel.svg",
    "bridge": "icon_bridge.svg",
    "connect": "icon_connect.svg",
    "collapse": "icon_collapse.svg",
    "fill_hole": "icon_fill_hole.svg",
    "knife": "icon_knife.svg",
    "loopcut": "icon_loop_cut.svg",
    "loop_cut": "icon_loop_cut.svg",
    "merge": "icon_merge.svg",
    "subdiv": "icon_subdivide.svg",
    "subdivide": "icon_subdivide.svg",
    "weld": "icon_weld.svg",
    "detach": "icon_detach.svg",
    "delete": "icon_delete.svg",
    "del": "icon_delete.svg",
    "env": "icon_env.svg",
    "object": "icon_object.svg",
    "vertex": "icon_vertex.svg",
    "edge": "icon_edge.svg",
    "face": "icon_face.svg",
    "texture": "icon_texture_mode.svg",
    "texture_mode": "icon_texture_mode.svg",
    "space": "icon_space.svg",
    "new_shape": "icon_new_shape.svg",
    "ngon": "icon_ngon.svg",
    "edit_params": "icon_edit_params.svg",
    "materials": "icon_materials.svg",
    "material": "icon_materials.svg",
    "uv": "icon_uv_unwrap.svg",
    "panel": "icon_panel.svg",
    "reset": "icon_panel_reset.svg",
    "panel_reset": "icon_panel_reset.svg",
    "settings": "icon_settings.svg",
    "export": "icon_export.svg",
    "docs": "icon_docs.svg",
    "lit": "icon_lit.svg",
    "shadow": "icon_shadow.svg",
    "grid": "icon_grid.svg",
    "split_rows": "icon_split_rows.svg",
    "extended": "icon_split_rows.svg",
    "all": "icon_select_all.svg",
    "select_all": "icon_select_all.svg",
    "invert": "icon_invert_selection.svg",
    "invert_selection": "icon_invert_selection.svg",
    "grow": "icon_grow_selection.svg",
    "grow_selection": "icon_grow_selection.svg",
    "shrink": "icon_shrink_selection.svg",
    "shrink_selection": "icon_shrink_selection.svg",
    "coplanar": "icon_select_coplanar.svg",
    "select_coplanar": "icon_select_coplanar.svg",
    "similar": "icon_select_similar.svg",
    "select_similar": "icon_select_similar.svg",
    "boundary": "icon_select_boundary.svg",
    "select_boundary": "icon_select_boundary.svg",
    "loop": "icon_face_loop.svg",
    "face_loop": "icon_face_loop.svg",
    "ring": "icon_face_ring.svg",
    "face_ring": "icon_face_ring.svg",
    "merge_objects": "icon_merge_objects.svg",
    "merge_objs": "icon_merge_objects.svg",
    "mirror": "icon_mirror.svg",
    "center_pivot": "icon_center_pivot.svg",
    "freeze_transform": "icon_freeze_transform.svg",
    "freeze": "icon_freeze_transform.svg",
    "poibuilderize": "icon_poibuilderize.svg",
    "csg_union": "icon_csg_union.svg",
    "csg_subtract": "icon_csg_subtract.svg",
    "csg_intersect": "icon_csg_intersect.svg",
    "auto_smooth": "icon_auto_smooth.svg",
    "smooth": "icon_auto_smooth.svg",
    "trim_walls": "icon_trim_walls.svg",
}


def _format_icon(raw: str) -> str:
    key = raw.strip().lower()
    icon_file = ICON_ALIASES.get(key)
    if not icon_file:
        if raw.strip().endswith(".svg"):
            icon_file = raw.strip()
        elif (ICONS_SRC / f"icon_{key}.svg").is_file():
            icon_file = f"icon_{key}.svg"
        elif (ICONS_SRC / f"{key}.svg").is_file():
            icon_file = f"{key}.svg"
        else:
            icon_file = f"icon_{key}.svg"
    alt = key.replace(".svg", "").replace("icon_", "").replace("_", " ").title()
    return f'<img class="action-icon" src="assets/icons/{html.escape(icon_file)}" width="16" height="16" alt="{html.escape(alt)}" title="{html.escape(alt)}">'


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
    s = re.sub(r"\[\[kbd:(.+?)\]\]", lambda m: _format_kbd(m.group(1)), s)
    s = re.sub(r"\[\[icon:(.+?)\]\]", lambda m: _format_icon(m.group(1)), s)
    s = re.sub(r"\[\[btn:([a-z_0-9]+)\]\]",
               lambda m: render_btn_ref(m.group(1)), s)
    # Label separator is :: (NOT |): table rows split cells on |, so a
    # |-label inside a table would shatter into raw-text cells.
    s = re.sub(r"\[\[btn:([a-z_0-9]+)::([^\]]+)\]\]",
               lambda m: render_btn_ref(m.group(1), m.group(2).strip()), s)
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
            continue
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
            while i < len(lines):
                nxt = lines[i]
                if re.match(r"^[-*]\s+", nxt) or re.match(r"^\d+\.\s+", nxt):
                    items.append(re.sub(r"^([-*]|\d+\.)\s+", "", nxt))
                    i += 1
                elif nxt[:1] in (" ", "\t") and nxt.strip() and items:
                    # A hard-wrapped continuation of the previous item: join
                    # it, or it leaks out of the list as a stray paragraph.
                    items[-1] += " " + nxt.strip()
                    i += 1
                else:
                    break
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
        # Godot must never import the bundled docs: without this the editor
        # generates .import metadata (and .godot copies) for every doc image
        # inside addons/poibuilder/. The plugin opens the docs via OS paths,
        # which .gdignore does not affect.
        (ADDON_BUNDLE / ".gdignore").write_text("", encoding="utf-8")
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
