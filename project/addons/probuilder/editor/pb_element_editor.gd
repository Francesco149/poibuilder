## PBElementEditor — Runtime-safe element editing logic (no editor-only classes).
##
## All mesh-element math and drag state for the subgizmo integration lives here
## so it is fully testable in plain headless runs: EditorNode3DGizmoPlugin
## refuses direct instantiation outside the editor process, so PBGizmoPlugin
## is a thin adapter that delegates to this class.
##
## Drag model (mirrors how the engine drives subgizmos):
## - begin_drag(): snapshot positions + per-id start transforms for the whole
##   engine-side subgizmo selection.
## - set_subgizmo_transform(): the engine delivers an ABSOLUTE node-local
##   target transform per selected id per motion. We derive the gesture's
##   node-space delta as rel = target * start^-1 and recompute the full result
##   from the snapshot each call — repeated delivery is IDEMPOTENT, which is
##   the guarantee that killed the "teleporting cube" regression.
## - commit(): registers an EditorUndoRedoManager action with exact
##   before/after position subsets; cancel restores the snapshot.
@tool
class_name PBElementEditor
extends RefCounted

# ==============================================================================
# Wiring
# ==============================================================================

## Shared editor state (select mode, orientation space, selection).
var editor: PBEditor = null

## Undo manager (EditorUndoRedoManager in the editor; duck-typed fake in tests).
var undo: Object = null

## Logger for diagnostics.
var logger: PBLogger = null

## Emitted while a subgizmo drag updates (for the Tool Properties dock).
## active=false is emitted on commit/cancel with zeroed values.
signal element_drag_updated(active: bool, translation: Vector3, rotation_deg: Vector3, scale: Vector3)

# ==============================================================================
# Drag state (one native drag gesture at a time)
# ==============================================================================

## True between begin_drag and commit.
var drag_active: bool = false

## Full position array snapshot taken when the drag begins.
var _drag_original_positions: PackedVector3Array = PackedVector3Array()

## Per-id start transform (node-local, as delivered to the engine).
var _drag_start_xf: Dictionary = {}

## Latest target transforms received this gesture, per id.
var _drag_pending: Dictionary = {}

## Id whose pending transform was stored most recently.
var _drag_latest_id: int = -1

## Per-element "side" face recorded at pick time (the face under the cursor).
## ProBuilder UX: the ELEMENT-space gizmo for an edge/vertex is oriented by
## the normal of the face you selected it FROM, not an average of all
## adjacent faces.
var pick_side_faces: Dictionary = {}

## Clears recorded pick-side faces (mode switch / selection cleared).
func reset_side_faces() -> void:
	pick_side_faces.clear()

## The mesh node being dragged.
var _drag_mesh: PBMesh = null

## Last emitted drag values, for on-demand dock refresh.
var _last_drag_active: bool = false
var _last_drag_translation: Vector3 = Vector3.ZERO
var _last_drag_rotation_deg: Vector3 = Vector3.ZERO
var _last_drag_scale: Vector3 = Vector3.ONE

# ==============================================================================
# State queries
# ==============================================================================

## True when `node` is the active mesh in an element mode (not Object).
## All element picking/dragging is gated on this so native object-level
## behavior takes over otherwise.
func is_editing_node(node: PBMesh) -> bool:
	return editor != null and editor.active_mesh == node \
		and editor.select_mode != PBEditor.SelectMode.OBJECT

# ==============================================================================
# Element geometry helpers (per select mode)
# ==============================================================================

## Local-space vertex indices belonging to subgizmo `id` (coincident-expanded).
func element_indices(mesh_data: PBMeshData, id: int) -> PackedInt32Array:
	if mesh_data == null or id < 0:
		return PackedInt32Array()
	match editor.select_mode:
		PBEditor.SelectMode.VERTEX:
			# Subgizmo ids are shared-vertex GROUP indices here — return the
			# group's positions directly. (Passing the group id to
			# get_coincident_vertices* would look it up as a POSITION index
			# and move a different corner — the "moves a different vert" bug.)
			if id >= mesh_data.shared_vertices.size():
				return PackedInt32Array()
			var sv: PBSharedVertex = mesh_data.shared_vertices[id]
			if sv == null:
				return PackedInt32Array()
			return sv.indices.duplicate()
		PBEditor.SelectMode.EDGE:
			var edges := mesh_data.get_common_edges()
			if id >= edges.size():
				return PackedInt32Array()
			return mesh_data.get_coincident_vertices_from_edges([edges[id]])
		PBEditor.SelectMode.FACE:
			return mesh_data.get_coincident_vertices_from_faces(PackedInt32Array([id]))
		_:
			return PackedInt32Array()

## Local-space representative point of subgizmo `id` (the gizmo pivot origin).
func element_origin(mesh_data: PBMeshData, id: int) -> Vector3:
	if mesh_data == null or id < 0:
		return Vector3.ZERO
	var positions := mesh_data.positions
	match editor.select_mode:
		PBEditor.SelectMode.VERTEX:
			if id >= mesh_data.shared_vertices.size():
				return Vector3.ZERO
			var sv: PBSharedVertex = mesh_data.shared_vertices[id]
			if sv == null or sv.indices.is_empty():
				return Vector3.ZERO
			var idx: int = sv.indices[0]
			return positions[idx] if idx >= 0 and idx < positions.size() else Vector3.ZERO
		PBEditor.SelectMode.EDGE:
			var edges := mesh_data.get_common_edges()
			if id >= edges.size():
				return Vector3.ZERO
			var edge: PBEdge = edges[id]
			if edge.a < 0 or edge.a >= positions.size() or edge.b < 0 or edge.b >= positions.size():
				return Vector3.ZERO
			return (positions[edge.a] + positions[edge.b]) * 0.5
		PBEditor.SelectMode.FACE:
			if id >= mesh_data.faces.size():
				return Vector3.ZERO
			var face: PBFace = mesh_data.faces[id]
			if face == null:
				return Vector3.ZERO
			var indices := face.get_distinct_indexes()
			if indices.is_empty():
				return Vector3.ZERO
			var sum := Vector3.ZERO
			var count: int = 0
			for idx in indices:
				if idx >= 0 and idx < positions.size():
					sum += positions[idx]
					count += 1
			return sum / float(count) if count > 0 else Vector3.ZERO
	return Vector3.ZERO

## Local-space orientation basis for subgizmo `id`, per editor.orientation_space.
## The engine displays the transform gizmo at node_global_transform * this basis,
## so: ELEMENT → element axes (face normal), OBJECT → node local axes,
## WORLD → world axes.
func element_basis(mesh_data: PBMeshData, node: PBMesh, id: int) -> Basis:
	if mesh_data == null or node == null:
		return Basis.IDENTITY
	match editor.orientation_space:
		PBEditor.OrientationSpace.WORLD:
			# Display basis should be identity in world → invert node rotation
			# locally (orthonormalized().inverse() = inverse of the rotation part).
			return node.global_transform.basis.orthonormalized().inverse()
		PBEditor.OrientationSpace.OBJECT:
			return Basis.IDENTITY
		PBEditor.OrientationSpace.ELEMENT:
			var side: int = pick_side_faces.get(id, -1)
			if side is int and side >= 0 and side < mesh_data.faces.size() \
					and mesh_data.faces[side] != null:
				# ProBuilder UX: orient by the normal of the face the element
				# was selected FROM (its visible side), not an average.
				var side_normal := PBMath.normal_from_positions(
					mesh_data.positions, mesh_data.faces[side].get_indexes())
				return _basis_from_normal(side_normal)
			return _element_local_basis(mesh_data, id)
	return Basis.IDENTITY

## Right-handed orthonormal basis with Z along `normal`.
func _basis_from_normal(normal: Vector3) -> Basis:
	if normal.length_squared() < PBMath.FLT_EPSILON:
		return Basis.IDENTITY
	normal = normal.normalized()
	var reference: Vector3 = Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x_axis: Vector3 = reference.cross(normal).normalized()
	var y_axis: Vector3 = normal.cross(x_axis).normalized()
	return Basis(x_axis, y_axis, normal)

## Element-aligned basis derived from the element's geometry (local space).
## Z axis = element normal (average adjacent face normals), X/Y orthonormal.
func _element_local_basis(mesh_data: PBMeshData, id: int) -> Basis:
	var normal := Vector3.ZERO
	var positions := mesh_data.positions
	var face_indexes: Array = []

	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			if id < mesh_data.faces.size() and mesh_data.faces[id] != null:
				face_indexes.append(id)
		PBEditor.SelectMode.EDGE:
			var edges := mesh_data.get_common_edges()
			if id < edges.size():
				face_indexes = _faces_touching_edge(mesh_data, edges[id])
		PBEditor.SelectMode.VERTEX:
			var sv: PBSharedVertex = mesh_data.shared_vertices[id] if id < mesh_data.shared_vertices.size() else null
			if sv != null:
				face_indexes = _faces_touching_vertex(mesh_data, sv)

	for fi in face_indexes:
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		normal += PBMath.normal_from_positions(positions, face.get_indexes())

	if normal.length_squared() < PBMath.FLT_EPSILON:
		return Basis.IDENTITY
	normal = normal.normalized()

	var reference: Vector3 = Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x_axis: Vector3 = reference.cross(normal).normalized()
	var y_axis: Vector3 = normal.cross(x_axis).normalized()
	return Basis(x_axis, y_axis, normal)

func _faces_touching_edge(mesh_data: PBMeshData, edge: PBEdge) -> Array:
	var result: Array = []
	var common: PBEdge = mesh_data.get_common_edge(edge)
	if common == null:
		return result
	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		for fe in face.get_edges():
			var fe_common: PBEdge = mesh_data.get_common_edge(fe)
			if fe_common != null and fe_common.equals(common):
				result.append(fi)
				break
	return result

func _faces_touching_vertex(mesh_data: PBMeshData, sv: PBSharedVertex) -> Array:
	var result: Array = []
	var lookup := mesh_data.get_shared_vertex_lookup()
	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		for idx in face.get_distinct_indexes():
			if lookup.get(idx, -1) in sv.indices:
				result.append(fi)
				break
	return result

# ==============================================================================
# Picking (element ids from camera ray / frustum; gating is the caller's job)
# ==============================================================================

## Nearest element id under a camera ray through screen_pos, or -1.
## Records the face under the cursor for side-aware gizmo orientation.
func pick_ray(mesh_data: PBMeshData, mesh_transform: Transform3D,
		camera: Camera3D, screen_pos: Vector2) -> int:
	if mesh_data == null or mesh_data.positions.is_empty() or camera == null:
		return -1
	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
			var ray_dir: Vector3 = camera.project_ray_normal(screen_pos)
			var fi: int = PBPicking.pick_face(mesh_data, mesh_transform, ray_origin, ray_dir).face_index
			if fi >= 0:
				pick_side_faces[fi] = fi
			return fi
		PBEditor.SelectMode.EDGE:
			var result: PBPicking.EdgePickResult = PBPicking.pick_edge(mesh_data, mesh_transform, screen_pos, camera)
			if result.edge == null:
				return -1
			var id := _common_edge_index(mesh_data, result.edge)
			if id >= 0 and result.face_index >= 0:
				pick_side_faces[id] = result.face_index
			return id
		PBEditor.SelectMode.VERTEX:
			var vresult: PBPicking.VertexPickResult = PBPicking.pick_vertex(mesh_data, mesh_transform, screen_pos, camera)
			if vresult.common_index >= 0 and vresult.face_index >= 0:
				pick_side_faces[vresult.common_index] = vresult.face_index
			return vresult.common_index
	return -1

## All element ids whose representative point lies inside the frustum planes.
func pick_frustum(mesh_data: PBMeshData, mesh_transform: Transform3D,
		frustum_planes: Array, camera: Camera3D = null) -> PackedInt32Array:
	var result := PackedInt32Array()
	if mesh_data == null or mesh_data.positions.is_empty():
		return result

	var planes: Array[Plane] = []
	for p in frustum_planes:
		planes.append(p as Plane)

	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			for fi in range(mesh_data.faces.size()):
				var origin := mesh_transform * element_origin(mesh_data, fi)
				if not _point_in_frustum(origin, planes):
					continue
				if camera != null and _point_occluded(mesh_data, mesh_transform, camera, origin, fi):
					continue
				result.append(fi)
		PBEditor.SelectMode.EDGE:
			var edges := mesh_data.get_common_edges()
			for ei in range(edges.size()):
				var origin := mesh_transform * element_origin(mesh_data, ei)
				if not _point_in_frustum(origin, planes):
					continue
				if camera != null and _point_occluded(mesh_data, mesh_transform, camera, origin, -1, edges[ei]):
					continue
				result.append(ei)
		PBEditor.SelectMode.VERTEX:
			for sv_idx in range(mesh_data.shared_vertices.size()):
				var origin := mesh_transform * element_origin(mesh_data, sv_idx)
				if not _point_in_frustum(origin, planes):
					continue
				if camera != null:
					var sv: PBSharedVertex = mesh_data.shared_vertices[sv_idx]
					if _point_occluded(mesh_data, mesh_transform, camera, origin, -1, null, sv):
						continue
				result.append(sv_idx)
	return result

## True when the first mesh surface between the camera and `point` belongs to
## a face the element is not part of — i.e. the element is hidden behind the
## mesh from this viewpoint. Box/rubber-band selection then matches what the
## user sees (an edge-on cube's far corners are not grabbed through it).
func _point_occluded(mesh_data: PBMeshData, mesh_transform: Transform3D,
		camera: Camera3D, point: Vector3, face_id: int = -1,
		edge: PBEdge = null, sv: PBSharedVertex = null) -> bool:
	var cam_pos: Vector3 = camera.global_position
	var to_point: Vector3 = point - cam_pos
	var distance: float = to_point.length()
	if distance < 0.001:
		return false
	var dir: Vector3 = to_point / distance

	var hit := PBPicking._first_ray_hit(mesh_data, mesh_transform, cam_pos, dir)
	var hit_face: int = hit["face"]
	if hit_face == -1:
		return false

	var own: bool
	if face_id != -1:
		own = hit_face == face_id
	elif edge != null:
		own = PBPicking._face_contains_common_edge(mesh_data, mesh_data.faces[hit_face], edge)
	else:
		own = PBPicking._face_contains_common_vertex(mesh_data, mesh_data.faces[hit_face], sv)
	if own:
		return false

	return hit["t"] + PBPicking.OCCLUSION_EPSILON < distance - PBPicking.OCCLUSION_EPSILON

## Maps an edge (raw position pair, as returned by PBPicking) to its subgizmo
## id in get_common_edges(). Comparison is by SHARED-GROUP pair on both sides —
## the previous version compared a group pair against raw position pairs with
## .equals(), which only matched by numeric coincidence (4 of 12 cube edges),
## leaving every other edge unselectable.
func _common_edge_index(mesh_data: PBMeshData, edge: PBEdge) -> int:
	if edge == null:
		return -1
	var lookup := mesh_data.get_shared_vertex_lookup()
	var ca: int = lookup.get(edge.a, -1)
	var cb: int = lookup.get(edge.b, -1)
	var key := Vector2i(mini(ca, cb), maxi(ca, cb))
	var edges := mesh_data.get_common_edges()
	for i in range(edges.size()):
		var e: PBEdge = edges[i]
		if e == null:
			continue
		var ea: int = lookup.get(e.a, -1)
		var eb: int = lookup.get(e.b, -1)
		if Vector2i(mini(ea, eb), maxi(ea, eb)) == key:
			return i
	return -1

static func _point_in_frustum(point: Vector3, planes: Array[Plane]) -> bool:
	for plane in planes:
		if plane.distance_to(point) > 0.0:
			return false
	return true

# ==============================================================================
# Subgizmo transforms (engine drag protocol)
# ==============================================================================

## Start transform for subgizmo `id` — what the engine sees on selection.
func get_subgizmo_transform(mesh_data: PBMeshData, node: PBMesh, id: int) -> Transform3D:
	if mesh_data == null or node == null or id < 0:
		return Transform3D.IDENTITY
	return Transform3D(element_basis(mesh_data, node, id), element_origin(mesh_data, id))

## Handles one engine _set_subgizmo_transform delivery.
## `ids` is the engine's current subgizmo selection (all elements the gizmo
## moves); it is delivered fresh so the logic never holds a stale selection.
func set_subgizmo_transform(node: PBMesh, ids: PackedInt32Array, id: int, transform: Transform3D) -> void:
	if node == null or not is_editing_node(node):
		return
	var mesh_data: PBMeshData = node.pb_mesh_data
	if mesh_data == null:
		return

	if not drag_active:
		_begin_drag(node, ids)

	_drag_pending[id] = transform
	_drag_latest_id = id
	_apply_drag(node, mesh_data, ids)

## Begins a drag gesture: snapshot positions and start transforms.
func _begin_drag(node: PBMesh, ids: PackedInt32Array) -> void:
	var mesh_data: PBMeshData = node.pb_mesh_data
	if mesh_data == null:
		return
	drag_active = true
	_drag_mesh = node
	_drag_original_positions = mesh_data.positions.duplicate()
	_drag_start_xf.clear()
	_drag_pending.clear()
	_drag_latest_id = -1
	for id in ids:
		_drag_start_xf[id] = get_subgizmo_transform(mesh_data, node, id)
	if logger != null:
		logger.info("tools", "Drag begun: %d element(s)" % ids.size())

## Applies the latest pending transform to ALL selected elements' vertices.
## Deliberately recomputes the full result from the drag-start snapshot every
## call: the engine calls set_subgizmo_transform once per selected id per
## motion, and re-deriving from the snapshot makes repeated calls idempotent
## (no compounding / "teleporting").
func _apply_drag(node: PBMesh, mesh_data: PBMeshData, ids: PackedInt32Array) -> void:
	if not drag_active or _drag_start_xf.is_empty():
		return

	# Union of coincident-expanded indices over the whole engine selection.
	var union := PackedInt32Array()
	var seen := {}
	for id in ids:
		for idx in element_indices(mesh_data, id):
			if not seen.has(idx):
				seen[idx] = true
				union.append(idx)
	if union.is_empty():
		return

	# rel = latest target * start^-1. The engine composes the same motion into
	# every selected subgizmo's transform, so any id's rel is the gesture's
	# node-space delta (translation / rotate-about-pivot / scale-about-pivot).
	if _drag_latest_id == -1 or not _drag_start_xf.has(_drag_latest_id) \
			or not _drag_pending.has(_drag_latest_id):
		return
	var rel: Transform3D = _drag_pending[_drag_latest_id] * _drag_start_xf[_drag_latest_id].affine_inverse()

	var new_positions := _drag_original_positions.duplicate()
	var pos_count: int = new_positions.size()
	for idx in union:
		if idx >= 0 and idx < pos_count:
			new_positions[idx] = rel * _drag_original_positions[idx]

	mesh_data.positions = new_positions
	mesh_data.invalidate_caches()
	node.rebuild()

	_emit_drag_update(true, rel.origin, _rel_rotation_deg(rel), rel.basis.get_scale())

## Commit (drag released) or cancel (Escape) — called by the editor adapter.
## `restores` are the start transforms the engine snapshotted; on cancel the
## engine does NOT revert anything itself, so restoring is our job.
## Returns true if a mutation was committed to undo (not on cancel/no-op).
func commit_subgizmos(node: PBMesh, ids: PackedInt32Array, cancel: bool) -> bool:
	if node == null or node.pb_mesh_data == null:
		_reset_drag_state()
		_emit_drag_update(false, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
		return false
	var mesh_data: PBMeshData = node.pb_mesh_data

	if cancel:
		if drag_active:
			mesh_data.positions = _drag_original_positions.duplicate()
			mesh_data.invalidate_caches()
			node.rebuild()
		_reset_drag_state()
		_emit_drag_update(false, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
		return false

	if not drag_active:
		return false

	# Undo payload: only the affected (coincident-expanded) positions.
	var union := PackedInt32Array()
	var seen := {}
	for id in ids:
		for idx in element_indices(mesh_data, id):
			if not seen.has(idx):
				seen[idx] = true
				union.append(idx)

	var before := PackedVector3Array()
	var after := PackedVector3Array()
	for idx in union:
		before.append(_drag_original_positions[idx])
		after.append(mesh_data.positions[idx])

	var changed: bool = before.size() > 0 and not _arrays_equal(before, after)
	_reset_drag_state()
	_emit_drag_update(false, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)

	if not changed:
		return false

	if undo != null:
		undo.create_action(TRANSFORM_ACTION_NAME, UndoRedo.MERGE_DISABLE)
		undo.add_do_method(self, "_apply_positions", node.get_instance_id(), union.duplicate(), after)
		undo.add_undo_method(self, "_apply_positions", node.get_instance_id(), union.duplicate(), before)
		undo.commit_action()
		if logger != null:
			logger.info("undo", "%s committed: %d vertices" % [TRANSFORM_ACTION_NAME, union.size()])
	return true

## Reapplies a position subset by node instance id (undo/redo payload).
## Instance id survives history replay; missing nodes are skipped silently.
func _apply_positions(node_id: int, indices: PackedInt32Array, positions_subset: PackedVector3Array) -> void:
	var node: PBMesh = instance_from_id(node_id) as PBMesh
	if node == null or node.pb_mesh_data == null:
		return
	var positions := node.pb_mesh_data.positions
	var count: int = mini(indices.size(), positions_subset.size())
	for i in range(count):
		var idx: int = indices[i]
		if idx >= 0 and idx < positions.size():
			positions[idx] = positions_subset[i]
	node.pb_mesh_data.positions = positions
	node.pb_mesh_data.invalidate_caches()
	node.rebuild()

func _reset_drag_state() -> void:
	drag_active = false
	_drag_mesh = null
	_drag_original_positions = PackedVector3Array()
	_drag_start_xf.clear()
	_drag_pending.clear()
	_drag_latest_id = -1

const TRANSFORM_ACTION_NAME := "Transform Elements"

static func _arrays_equal(a: PackedVector3Array, b: PackedVector3Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if not a[i].is_equal_approx(b[i]):
			return false
	return true

# ==============================================================================
# Selection mirroring (engine subgizmo selection → PBSelection)
# ==============================================================================

## Mirrors the engine's subgizmo selection into PBSelection so the dock,
## toolbar, and commands agree with what the transform gizmo will move.
## The engine selection is authoritative — it is what the editor drags.
## Returns true if PBSelection was modified.
func mirror_engine_selection(selection: PBSelection, mesh_data: PBMeshData,
		engine_ids: PackedInt32Array) -> bool:
	if selection == null or mesh_data == null:
		return false

	var differs: bool = false
	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			differs = not _int_arrays_equal(selection.selected_faces, engine_ids)
		PBEditor.SelectMode.VERTEX:
			differs = not _int_arrays_equal(selection.selected_vertices, engine_ids)
		PBEditor.SelectMode.EDGE:
			differs = selection.selected_edges.size() != engine_ids.size()
			if not differs:
				var edges := mesh_data.get_common_edges()
				for i in range(engine_ids.size()):
					var eid: int = engine_ids[i]
					if eid < 0 or eid >= edges.size() or not selection.is_edge_selected(edges[eid]):
						differs = true
						break
		_:
			return false

	if not differs:
		return false

	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			selection.set_faces(engine_ids)
		PBEditor.SelectMode.VERTEX:
			selection.set_vertices(engine_ids)
		PBEditor.SelectMode.EDGE:
			var edges := mesh_data.get_common_edges()
			var selected: Array[PBEdge] = []
			for eid in engine_ids:
				if eid >= 0 and eid < edges.size():
					selected.append(edges[eid])
			selection.set_edges(selected)
	return true

static func _int_arrays_equal(a: PackedInt32Array, b: PackedInt32Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true

# ==============================================================================
# Rendering helpers (runtime-safe so they are testable)
# ==============================================================================

const FACE_FILL_DEPTH_OFFSET: float = 0.004

## Builds the selected-face highlight as an n-gon centroid fan, offset slightly
## along the face's average normal. The offset lets the fill be DEPTH-TESTED
## (no z-fighting) so it can never poke through the mesh on non-planar faces
## — the old depth-test-off fill drew its triangle boundary through the
## surface, reading as a "diagonal edge where there is no edge".
static func build_face_fill_mesh(mesh_data: PBMeshData, face_index: int,
		offset: float = FACE_FILL_DEPTH_OFFSET) -> ArrayMesh:
	if mesh_data == null or face_index < 0 or face_index >= mesh_data.faces.size():
		return null
	var face: PBFace = mesh_data.faces[face_index]
	if face == null:
		return null

	var positions := mesh_data.positions
	var loop := face.get_distinct_indexes()
	if loop.size() < 3:
		return null

	var centroid := Vector3.ZERO
	var count: int = 0
	for idx in loop:
		if idx >= 0 and idx < positions.size():
			centroid += positions[idx]
			count += 1
	if count < 3:
		return null
	centroid /= float(count)

	var normal := PBMath.normal_from_positions(positions, face.get_indexes())
	var shift := normal * offset

	var tris := PackedVector3Array()
	for i in range(count):
		var a: int = loop[i]
		var b: int = loop[(i + 1) % count]
		if a < 0 or a >= positions.size() or b < 0 or b >= positions.size():
			return null
		tris.append(centroid + shift)
		tris.append(positions[a] + shift)
		tris.append(positions[b] + shift)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	var fill_mesh := ArrayMesh.new()
	fill_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return fill_mesh

# ==============================================================================
# Drag readout (for the Tool Properties dock)
# ==============================================================================

## Stores the latest drag values and notifies listeners.
func _emit_drag_update(active: bool, translation: Vector3, rotation_deg: Vector3, scale: Vector3) -> void:
	_last_drag_active = active
	_last_drag_translation = translation
	_last_drag_rotation_deg = rotation_deg
	_last_drag_scale = scale
	element_drag_updated.emit(active, translation, rotation_deg, scale)

## Human-readable live drag readout for the Tool Properties dock.
func drag_readout() -> String:
	if not _last_drag_active:
		return "—"
	if not _last_drag_rotation_deg.is_equal_approx(Vector3.ZERO):
		return "Rotation: %s deg" % _fmt_vec(_last_drag_rotation_deg)
	if not _last_drag_scale.is_equal_approx(Vector3.ONE):
		return "Scale: %s" % _fmt_vec(_last_drag_scale)
	return "Delta: %s" % _fmt_vec(_last_drag_translation)

static func _rel_rotation_deg(rel: Transform3D) -> Vector3:
	var euler: Vector3 = rel.basis.get_euler()
	return Vector3(rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z))

static func _fmt_vec(v: Vector3) -> String:
	var x: float = 0.0 if is_zero_approx(v.x) else v.x
	var y: float = 0.0 if is_zero_approx(v.y) else v.y
	var z: float = 0.0 if is_zero_approx(v.z) else v.z
	var rounded := Vector3(
		round(x * 1000.0) / 1000.0,
		round(y * 1000.0) / 1000.0,
		round(z * 1000.0) / 1000.0
	)
	return str(rounded)
