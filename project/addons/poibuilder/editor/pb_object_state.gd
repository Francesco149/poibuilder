## PBObjectState — Lit / cast-shadow state of scene objects (headless-safe).
##
## The per-node decisions behind the toolbar's Lit and Cast Shadows toggles:
## what "lit" means on each node kind, the combined (all/none/mixed) state
## across a selection, and the in-place change + undo RECORD describing what
## moved. The plugin wraps the records into EditorUndoRedoManager actions;
## every decision lives here so it stays testable headless.
##
## "Lit" follows the retro pipeline's own convention (PBLightBaker): a
## StandardMaterial3D with shading_mode != SHADING_MODE_UNSHADED is lit. A
## node counts as lit only when EVERY of its StandardMaterial3D materials is
## lit (so checking the button really makes the whole object lit). Shader
## materials (splatting) have no shading mode and never participate.
##
## Undo records are plain Dictionaries:
##   {"kind": "pbmesh",    "node": …, "old_materials": [...], "new_materials": [...]}
##   {"kind": "surfaces",  "node": …, "old_overrides": {idx: mat}, "new_overrides": {...}}
##   {"kind": "override",  "node": …, "old_override": mat, "new_override": mat}
##   {"kind": "csg",       "node": …, "old_material": mat, "new_material": mat}
##   {"kind": "shadow",    "node": …, "old": int, "new": int}
## The plugin replays either side with _apply_lit_record/_apply_shadow_record.
@tool
class_name PBObjectState
extends RefCounted

## Tri-state for a whole selection: -1 mixed, 0 all off, 1 all on.
const MIXED := -1

# ==============================================================================
# Per-node queries
# ==============================================================================

## The node's StandardMaterial3D materials (the only ones the lit toggle
## drives). PBMesh reads its mesh data; MeshInstance3D reads the override,
## then the surface overrides, then the mesh's own surface materials; CSG
## primitives read their material.
static func node_standard_materials(node: GeometryInstance3D) -> Array[StandardMaterial3D]:
	var out: Array[StandardMaterial3D] = []
	if node == null or not is_instance_valid(node):
		return out
	var pb := node as PBMesh
	if pb != null:
		if pb.pb_mesh_data != null:
			for m in pb.pb_mesh_data.materials:
				if m is StandardMaterial3D:
					out.append(m)
		return out
	var csg := node as CSGPrimitive3D
	if csg != null:
		var cm: Material = csg.material
		if cm is StandardMaterial3D:
			out.append(cm)
		return out
	var mi := node as MeshInstance3D
	if mi == null:
		return out
	if mi.material_override is StandardMaterial3D:
		out.append(mi.material_override)
	var mesh := mi.mesh
	if mesh != null:
		for s in range(mesh.get_surface_count()):
			var om := mi.get_surface_override_material(s)
			if om is StandardMaterial3D:
				out.append(om)
				continue
			var sm := mesh.surface_get_material(s)
			if sm is StandardMaterial3D:
				out.append(sm)
	return out

## A node is lit when it has at least one StandardMaterial3D and none of
## them is unshaded (nodes with only shader materials don't participate).
static func is_node_lit(node: GeometryInstance3D) -> bool:
	var mats := node_standard_materials(node)
	if mats.is_empty():
		return true  # neutral: not driven by the toggle
	for m in mats:
		if m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
			return false
	return true

static func is_node_shadow_casting(node: GeometryInstance3D) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	return node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# ==============================================================================
# Combined selection state
# ==============================================================================

## Applicable nodes: GeometryInstance3D in tree (the toggle's targets).
static func applicable_nodes(nodes: Array) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	for n in nodes:
		if n is GeometryInstance3D and n.is_inside_tree():
			out.append(n)
	return out

static func lit_state(nodes: Array) -> int:
	var saw_lit := false
	var saw_unlit := false
	for node in applicable_nodes(nodes):
		if node is PBMesh or node is MeshInstance3D or node is CSGPrimitive3D:
			if node_standard_materials(node).is_empty():
				continue  # neutral: no standard material to drive
			if is_node_lit(node):
				saw_lit = true
			else:
				saw_unlit = true
	if saw_lit and saw_unlit:
		return MIXED
	if saw_lit:
		return 1
	return 0

static func shadow_state(nodes: Array) -> int:
	var saw_on := false
	var saw_off := false
	for node in applicable_nodes(nodes):
		if is_node_shadow_casting(node):
			saw_on = true
		else:
			saw_off = true
	if saw_on and saw_off:
		return MIXED
	if saw_on:
		return 1
	return 0

# ==============================================================================
# Mutations (+ undo records)
# ==============================================================================

## Applies `lit` to one node in place. Returns the undo record (empty when
## nothing changed — no standard material, or already in the target state).
## Shared/persisted materials (.tres on disk, editor-cached singles) are
## duplicated first so the toggle never mutates a resource other objects
## reference; the duplicate's resource_path is cleared.
static func set_node_lit(node: GeometryInstance3D, lit: bool) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {}
	var target := BaseMaterial3D.SHADING_MODE_PER_PIXEL if lit else BaseMaterial3D.SHADING_MODE_UNSHADED
	var pb := node as PBMesh
	if pb != null:
		var md: PBMeshData = pb.pb_mesh_data
		if md == null or md.materials.is_empty():
			return {}
		var old_materials: Array[Material] = []
		var new_materials: Array[Material] = []
		var changed := false
		for m in md.materials:
			old_materials.append(m)
			if m is StandardMaterial3D and (m as StandardMaterial3D).shading_mode != target:
				var dup := _detached_duplicate(m)
				dup.shading_mode = target
				new_materials.append(dup)
				changed = true
			else:
				new_materials.append(m)
		if not changed:
			return {}
		md.materials = new_materials
		return {"kind": "pbmesh", "node": pb,
			"old_materials": old_materials, "new_materials": new_materials}
	var csg := node as CSGPrimitive3D
	if csg != null:
		var cm: Material = csg.material
		if cm is StandardMaterial3D and cm.shading_mode != target:
			var dup := _detached_duplicate(cm)
			dup.shading_mode = target
			csg.material = dup
			return {"kind": "csg", "node": csg, "old_material": cm, "new_material": dup}
		return {}
	var mi := node as MeshInstance3D
	if mi == null:
		return {}
	# 1. Material override (billboards, decals — the common single-material case)
	if mi.material_override is StandardMaterial3D:
		var om := mi.material_override as StandardMaterial3D
		if om.shading_mode != target:
			var dup := _detached_duplicate(om)
			dup.shading_mode = target
			mi.material_override = dup
			return {"kind": "override", "node": mi, "old_override": om, "new_override": dup}
		return {}
	# 2. Per-surface: copy each surface's material into a surface override and
	# flip it there — the mesh resource itself is never mutated.
	var mesh := mi.mesh
	if mesh == null:
		return {}
	var old_overrides := {}
	var new_overrides := {}
	var changed := false
	for s in range(mesh.get_surface_count()):
		var cur := mi.get_surface_override_material(s)
		if cur == null:
			cur = mesh.surface_get_material(s)
		old_overrides[s] = mi.get_surface_override_material(s)
		if cur is StandardMaterial3D and (cur as StandardMaterial3D).shading_mode != target:
			var dup := _detached_duplicate(cur)
			dup.shading_mode = target
			mi.set_surface_override_material(s, dup)
			new_overrides[s] = dup
			changed = true
		else:
			new_overrides[s] = mi.get_surface_override_material(s)
	if not changed:
		return {}
	return {"kind": "surfaces", "node": mi, "old_overrides": old_overrides, "new_overrides": new_overrides}

## Applies `cast` to one node. Enabling keeps DOUBLE_SIDED nodes on their
## double-sided setting (a sprite's shadow mode is "casts"); anything else
## becomes ON. Returns the undo record (empty when already in state).
static func set_node_shadow(node: GeometryInstance3D, cast: bool) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {}
	var old := node.cast_shadow
	var target := old
	if cast:
		if old == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			target = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		target = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if target == old:
		return {}
	node.cast_shadow = target
	return {"kind": "shadow", "node": node, "old": old, "new": target}

## Duplicates a material and severs its on-disk path so the editor never
## writes the toggle back into the shared .tres.
static func _detached_duplicate(mat: Material) -> Material:
	var dup: Material = mat.duplicate()
	dup.resource_path = ""
	return dup
