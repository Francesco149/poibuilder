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

## Emitted when a committed drag rewrote TOPOLOGY (shift+move extrude,
## shift+scale inset): face ids are stale, so the plugin must clear the
## engine subgizmo selection + mirrors and redraw.
signal drag_topology_committed(node: PBMesh)

# ==============================================================================
# Drag gestures (tool + modifier keys decide how a drag applies)
# ==============================================================================

enum DragGesture {
	NORMAL,        ## Raw rel transform from the engine (move/free scale/rotate)
	EXTRUDE_MOVE,  ## Shift+move: extrude the selection at drag begin, drag the caps
	CENTER_SCALE,  ## Dragging the center scale handle: uniform scale about the pivot
	CENTER_INSET,  ## Shift+center handle on faces: uniform per-face inset
}

## What the current drag does (decided once at drag begin — mid-drag
## modifier flaps do not re-decide it). Axis/plane scale drags are FREE
## (engine rel applies raw); uniform scaling and inset live on the center
## scale handle the gizmo plugin draws.
var _drag_gesture: DragGesture = DragGesture.NORMAL

## Positions a topology-creating gesture drags (caps/fins' lifted corners or
## inset inner faces). Empty for NORMAL/CENTER_SCALE — the union then comes
## from the element ids.
var _drag_union_override: PackedInt32Array = PackedInt32Array()

## Full-mesh snapshot taken BEFORE a gesture's begin-op (extrude/inset).
## Non-null makes commit/cancel swap whole-mesh snapshots instead of
## per-position payloads (topology changed, indexes don't correspond).
var _drag_before_op: PBMeshData = null

## Per-face inset bases: [{idxs: PackedInt32Array, centroid: Vector3,
## pre: PackedVector3Array}] — pre-op corner positions and their centroid
## (the centroid is invariant under uniform lerp, so idempotent replay works).
var _drag_inset_bases: Array = []

## Latest inset amount applied this gesture (readout only).
var _last_inset_amount: float = 0.0

## Center-handle drag state: screen-space radius ratio about the pivot, and
## the captured pivot/start point. Driven by PBGizmoPlugin handle callbacks.
var _center_factor: float = 1.0
var _center_start_screen: Vector2 = Vector2.ZERO
var _center_pivot: Vector3 = Vector3.ZERO  # node-local
var _center_has_start: bool = false

## Reads live modifier state. Editor-process only (headless tests inject
## shift directly into _decide_gesture).
static func shift_held() -> bool:
	return Input.is_key_pressed(KEY_SHIFT)

## Pure decision (testable): tool + shift → gesture for ENGINE-delivered
## drags (the center handle decides its own gesture explicitly).
func _decide_gesture(shift: bool) -> DragGesture:
	if editor == null:
		return DragGesture.NORMAL
	match editor.tool_mode:
		PBEditor.ToolMode.MOVE:
			if shift and editor.select_mode == PBEditor.SelectMode.FACE:
				return DragGesture.EXTRUDE_MOVE
			if shift and editor.select_mode == PBEditor.SelectMode.EDGE:
				return DragGesture.EXTRUDE_MOVE
		_:
			pass
	return DragGesture.NORMAL

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

## The engine selection captured at drag begin (center drags carry no
## per-motion deliveries, so _apply_drag falls back to these).
var _drag_ids: PackedInt32Array = PackedInt32Array()

## Per-element "side" face recorded at pick time (the face under the cursor).
## ProBuilder UX: the ELEMENT-space gizmo for an edge/vertex is oriented by
## the normal of the face you selected it FROM, not an average of all
## adjacent faces.
var pick_side_faces: Dictionary = {}

## Edge-loop selection (alt+click / double-click on an edge): engine edge id
## → the ids of ALL common edges in its ring. Selected ids expand to their
## loop for dragging, highlight, and the PBSelection mirror; a plain click
## (no alt) drops back to the single edge.
var selected_loops: Dictionary = {}

## Double-click tracking for the click path only (hover never reaches it).
var _last_click_msec: int = -10000
var _last_click_id: int = -1
var _last_click_alt: bool = false

## Clears recorded pick-side faces and loop selections (mode switch /
## selection cleared / post-op).
func reset_side_faces() -> void:
	pick_side_faces.clear()
	selected_loops.clear()
	_last_click_msec = -10000
	_last_click_id = -1
	_last_click_alt = false

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
			var edge_objs: Array[PBEdge] = []
			for eid in expand_edge_ids(mesh_data, PackedInt32Array([id])):
				edge_objs.append(edges[eid])
			return mesh_data.get_coincident_vertices_from_edges(edge_objs)
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
## `record_side`: only the CLICK path may write the pick-side face — the
## gizmo must stay locked to the side the element was selected from; hover
## passes false so merely moving the cursor over the other side never
## re-orients the gizmo mid-usage.
func pick_ray(mesh_data: PBMeshData, mesh_transform: Transform3D,
		camera: Camera3D, screen_pos: Vector2, record_side: bool = true) -> int:
	if mesh_data == null or mesh_data.positions.is_empty() or camera == null:
		return -1
	match editor.select_mode:
		PBEditor.SelectMode.FACE:
			var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
			var ray_dir: Vector3 = camera.project_ray_normal(screen_pos)
			var fi: int = PBPicking.pick_face(mesh_data, mesh_transform, ray_origin, ray_dir).face_index
			if fi >= 0 and record_side:
				pick_side_faces[fi] = fi
			return fi
		PBEditor.SelectMode.EDGE:
			var result: PBPicking.EdgePickResult = PBPicking.pick_edge(mesh_data, mesh_transform, screen_pos, camera)
			if result.edge == null:
				return -1
			var id := _common_edge_index(mesh_data, result.edge)
			if id >= 0 and result.face_index >= 0 and record_side:
				pick_side_faces[id] = result.face_index
			return id
		PBEditor.SelectMode.VERTEX:
			var vresult: PBPicking.VertexPickResult = PBPicking.pick_vertex(mesh_data, mesh_transform, screen_pos, camera)
			if vresult.common_index >= 0 and vresult.face_index >= 0 and record_side:
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
# Edge-loop selection (alt+click / double-click)
# ==============================================================================

## Call from the CLICK path only (engine _subgizmos_intersect_ray) after an
## EDGE-mode pick. When the click asks for a loop (alt held, or a
## double-click on the same edge — two rapid PLAIN clicks), records and
## returns the ring ids; a plain click returns empty and drops any loop
## recorded for `id`.
func record_edge_click(mesh_data: PBMeshData, id: int, alt_held: bool) -> PackedInt32Array:
	if mesh_data == null or id < 0:
		return PackedInt32Array()
	var now := Time.get_ticks_msec()
	var double_click := id == _last_click_id and not alt_held and not _last_click_alt \
		and now - _last_click_msec <= DOUBLE_CLICK_MS
	_last_click_msec = now
	_last_click_id = id
	_last_click_alt = alt_held
	if not alt_held and not double_click:
		selected_loops.erase(id)
		return PackedInt32Array()
	var loop := edge_loop_ids(mesh_data, id)
	if loop.size() > 1:
		selected_loops[id] = loop
		return loop
	return PackedInt32Array()

## All common-edge ids in the ring through common edge `id` (seed included).
## Rings can close early at non-quad faces (PBTopology.get_edge_ring walks
## quads only) — whatever the walk returns is the selection.
func edge_loop_ids(mesh_data: PBMeshData, id: int) -> PackedInt32Array:
	var edges := mesh_data.get_common_edges()
	if id < 0 or id >= edges.size():
		return PackedInt32Array()
	var ring := PBTopology.get_edge_ring(mesh_data, [edges[id]])
	var lookup := mesh_data.get_shared_vertex_lookup()
	var id_of_key := {}
	for i in range(edges.size()):
		id_of_key[_edge_key(lookup, edges[i].a, edges[i].b)] = i
	var ids := PackedInt32Array()
	for e in ring:
		var eid: int = id_of_key.get(_edge_key(lookup, e.a, e.b), -1)
		if eid >= 0:
			ids.append(eid)
	return ids

## Expands engine-selected edge ids through recorded loops (stable order,
## deduplicated). Non-loop ids pass through unchanged.
func expand_edge_ids(mesh_data: PBMeshData, ids: PackedInt32Array) -> PackedInt32Array:
	if selected_loops.is_empty() or ids.is_empty():
		return ids
	var out := PackedInt32Array()
	var seen := {}
	for eid in ids:
		var loop: PackedInt32Array = selected_loops.get(eid, PackedInt32Array())
		if loop.is_empty():
			if not seen.has(eid):
				seen[eid] = true
				out.append(eid)
		else:
			for lid in loop:
				if not seen.has(lid):
					seen[lid] = true
					out.append(lid)
	return out

static func _edge_key(lookup: Dictionary, a: int, b: int) -> Vector2i:
	var ca: int = lookup.get(a, a)
	var cb: int = lookup.get(b, b)
	return Vector2i(mini(ca, cb), maxi(ca, cb))

const DOUBLE_CLICK_MS := 400

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
	set_subgizmo_transform_with_shift(node, ids, id, transform, shift_held())

## Shift-aware entry point: the editor path passes live modifier state, the
## gesture decision and every gesture path are testable headlessly by
## injecting `shift` directly.
func set_subgizmo_transform_with_shift(node: PBMesh, ids: PackedInt32Array, id: int,
		transform: Transform3D, shift: bool) -> void:
	if node == null or not is_editing_node(node):
		return
	var mesh_data: PBMeshData = node.pb_mesh_data
	if mesh_data == null:
		return

	if not drag_active:
		_begin_drag(node, ids, shift)

	_drag_pending[id] = transform
	_drag_latest_id = id
	_apply_drag(node, mesh_data, ids)

## Begins a drag gesture: decide the gesture from tool+shift, snapshot
## positions and start transforms, then run any begin-time topology op
## (extrude for shift+move, inset for shift+scale). `shift` is injected by
## the caller (live modifier state in the editor; explicit in tests).
func _begin_drag(node: PBMesh, ids: PackedInt32Array, shift: bool) -> void:
	var mesh_data: PBMeshData = node.pb_mesh_data
	if mesh_data == null:
		return
	drag_active = true
	_drag_mesh = node
	_drag_gesture = _decide_gesture(shift)
	_drag_ids = ids.duplicate()
	_drag_original_positions = mesh_data.positions.duplicate()
	_drag_start_xf.clear()
	_drag_pending.clear()
	_drag_latest_id = -1
	_drag_union_override = PackedInt32Array()
	_drag_before_op = null
	_drag_inset_bases = []
	_last_inset_amount = 0.0
	_center_factor = 1.0
	_center_has_start = false
	for id in ids:
		_drag_start_xf[id] = get_subgizmo_transform(mesh_data, node, id)

	# Topology-creating gestures undo via whole-mesh snapshots — capture the
	# pre-op state before mutating.
	if _drag_gesture == DragGesture.EXTRUDE_MOVE:
		_drag_before_op = PBCommand.copy_mesh_data(mesh_data)

	match _drag_gesture:
		DragGesture.EXTRUDE_MOVE:
			_begin_extrude_move(mesh_data, ids)

	if logger != null:
		logger.info("tools", "Drag begun: %s, %d element(s)" % [
			DragGesture.keys()[_drag_gesture], ids.size()])

## Shift+move: extrude the selection at distance 0, then the drag translates
## only the new caps/fins (their lifted corners). Undo covers the whole
## gesture via a full-mesh snapshot.
func _begin_extrude_move(mesh_data: PBMeshData, ids: PackedInt32Array) -> void:
	var result: Dictionary
	if editor.select_mode == PBEditor.SelectMode.EDGE:
		result = PBMeshOps.extrude_edges(mesh_data, ids, 0.0, true)
	else:
		result = PBMeshOps.extrude_faces(mesh_data, ids, 0.0, true)
	if not result.get("ok", false):
		# Nothing extrudable under the gesture (degenerate normals) — the
		# drag degrades to a plain move of the selection.
		_drag_gesture = DragGesture.NORMAL
		_drag_before_op = null
		return
	# _drag_original_positions was captured PRE-op above; the gesture replays
	# from the POST-op geometry, so re-snapshot now.
	_drag_original_positions = mesh_data.positions.duplicate()
	_drag_union_override = result["drag_positions"]

## Center-handle inset (shift + center square on faces): seed a minimal
## inset (topology: inner face + ring per face), then the drag lerps each
## inner face's corners between the pre-op outline and its centroid. Uniform
## amount — aspect ratio fixed. The inset op REMAPS position indexes
## (replace + compact), so the per-face bases must bind the POST-op
## inner-face indexes to the PRE-op corner positions — matched by per-face
## order (duplicate_face preserves the index sequence).
func _begin_inset(mesh_data: PBMeshData, ids: PackedInt32Array) -> void:
	var pre := mesh_data.positions.duplicate()
	var face_bases: Array = []
	for id in ids:
		if id < 0 or id >= mesh_data.faces.size() or mesh_data.faces[id] == null:
			_drag_gesture = DragGesture.NORMAL
			_drag_before_op = null
			_drag_inset_bases = []
			return
		var loop := mesh_data.faces[id].get_distinct_indexes()
		if loop.size() < 3:
			_drag_gesture = DragGesture.NORMAL
			_drag_before_op = null
			_drag_inset_bases = []
			return
		var centroid := Vector3.ZERO
		var corners := PackedVector3Array()
		for idx in loop:
			centroid += pre[idx]
			corners.append(pre[idx])
		centroid /= float(loop.size())
		face_bases.append({"centroid": centroid, "pre": corners})

	var result := PBMeshOps.inset_faces(mesh_data, ids, 0.01)
	if not result.get("ok", false):
		_drag_gesture = DragGesture.NORMAL
		_drag_before_op = null
		_drag_inset_bases = []
		return
	_drag_original_positions = mesh_data.positions.duplicate()

	# Union = the inner faces' corners only (the rings stay put); the bases
	# bind those (post-op) indexes to the (pre-op) outline + centroid.
	var union := PackedInt32Array()
	var cap_ids: PackedInt32Array = result["cap_face_ids"]
	for i in range(cap_ids.size()):
		var idxs := mesh_data.faces[cap_ids[i]].get_distinct_indexes()
		for idx in idxs:
			union.append(idx)
		_drag_inset_bases.append({
			"idxs": idxs,
			"centroid": face_bases[i]["centroid"],
			"pre": face_bases[i]["pre"],
		})
	_drag_union_override = union

## Applies the latest pending transform to ALL selected elements' vertices.
## Deliberately recomputes the full result from the drag-start snapshot every
## call: the engine calls set_subgizmo_transform once per selected id per
## motion, and re-deriving from the snapshot makes repeated calls idempotent
## (no compounding / "teleporting").
func _apply_drag(node: PBMesh, mesh_data: PBMeshData, ids: PackedInt32Array) -> void:
	if not drag_active or _drag_start_xf.is_empty():
		return

	# Topology-creating gestures move exactly their reported drag positions;
	# plain gestures move the coincident-expanded union of the selection.
	var union := PackedInt32Array()
	if not _drag_union_override.is_empty():
		union = _drag_union_override
	else:
		if ids.is_empty():
			ids = _drag_ids
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
	# Center-handle drags have no engine deliveries — they carry their own
	# factor and skip this entirely.
	var rel: Transform3D = Transform3D()
	if _drag_gesture == DragGesture.NORMAL or _drag_gesture == DragGesture.EXTRUDE_MOVE:
		if _drag_latest_id == -1 or not _drag_start_xf.has(_drag_latest_id) \
				or not _drag_pending.has(_drag_latest_id):
			return
		rel = _drag_pending[_drag_latest_id] * _drag_start_xf[_drag_latest_id].affine_inverse()

	var new_positions := _drag_original_positions.duplicate()
	var pos_count: int = new_positions.size()

	match _drag_gesture:
		DragGesture.CENTER_INSET:
			var amount := clampf(1.0 - _center_factor, -1.0, 0.95)
			_last_inset_amount = amount
			for base in _drag_inset_bases:
				var idxs: PackedInt32Array = base["idxs"]
				var centroid: Vector3 = base["centroid"]
				var pre: PackedVector3Array = base["pre"]
				for i in range(idxs.size()):
					var idx: int = idxs[i]
					if idx >= 0 and idx < pos_count:
						new_positions[idx] = pre[i].lerp(centroid, amount)
			_emit_drag_update(true, Vector3(amount, 0, 0), Vector3.ZERO, Vector3.ONE)
		DragGesture.CENTER_SCALE:
			var pivot := _center_pivot
			for idx in union:
				if idx >= 0 and idx < pos_count:
					new_positions[idx] = pivot + (_drag_original_positions[idx] - pivot) * _center_factor
			_emit_drag_update(true, pivot - pivot * _center_factor, Vector3.ZERO, Vector3.ONE * _center_factor)
		_:
			for idx in union:
				if idx >= 0 and idx < pos_count:
					new_positions[idx] = rel * _drag_original_positions[idx]
			_emit_drag_update(true, rel.origin, _rel_rotation_deg(rel), rel.basis.get_scale())

	mesh_data.positions = new_positions
	mesh_data.invalidate_caches()
	node.rebuild()

# ==============================================================================
# Center scale handle (uniform scale + inset, ProBuilder-style)
# ==============================================================================

## True while the gizmo plugin is driving a center-handle drag.
func center_drag_active() -> bool:
	return drag_active and (_drag_gesture == DragGesture.CENTER_SCALE \
		or _drag_gesture == DragGesture.CENTER_INSET)

## The average origin of `ids`' elements (node-local) — the pivot for the
## center scale handle.
func center_pivot(mesh_data: PBMeshData, ids: PackedInt32Array) -> Vector3:
	if mesh_data == null or ids.is_empty():
		return Vector3.ZERO
	var acc := Vector3.ZERO
	var count := 0
	for id in ids:
		acc += element_origin(mesh_data, id)
		count += 1
	return acc / float(count) if count > 0 else Vector3.ZERO

## Begins a center-handle drag. `inset`: shift+handle on a face selection —
## seeds a real inset(0.01) and the drag lerps each inner face toward its
## pre-op centroid (aspect fixed). Otherwise the drag scales the selection's
## positions uniformly about `pivot` (node-local).
func begin_center_drag(node: PBMesh, ids: PackedInt32Array, inset: bool,
		pivot: Vector3, start_screen: Vector2) -> bool:
	if node == null or node.pb_mesh_data == null or ids.is_empty() or drag_active:
		return false
	var mesh_data: PBMeshData = node.pb_mesh_data
	drag_active = true
	_drag_mesh = node
	_drag_ids = ids.duplicate()
	_drag_original_positions = mesh_data.positions.duplicate()
	_drag_start_xf.clear()
	_drag_pending.clear()
	_drag_latest_id = -1
	_drag_union_override = PackedInt32Array()
	_drag_before_op = null
	_drag_inset_bases = []
	_last_inset_amount = 0.0
	for id in ids:
		_drag_start_xf[id] = get_subgizmo_transform(mesh_data, node, id)
	_center_pivot = pivot
	_center_start_screen = start_screen
	_center_has_start = true

	if inset:
		_drag_gesture = DragGesture.CENTER_INSET
		_drag_before_op = PBCommand.copy_mesh_data(mesh_data)
		_begin_inset(mesh_data, ids)
		if _drag_gesture != DragGesture.CENTER_INSET:
			# Faces were not inset-able — degrade to uniform scale.
			_drag_before_op = null
			_drag_gesture = DragGesture.CENTER_SCALE
	else:
		_drag_gesture = DragGesture.CENTER_SCALE

	if logger != null:
		logger.info("tools", "Center drag begun: %s, %d element(s)" % [
			DragGesture.keys()[_drag_gesture], ids.size()])
	return true

## Applies the drag from the current screen point: a radius ratio about the
## pivot's screen position drives either uniform scale or the inset amount.
func apply_center_drag(node: PBMesh, camera: Camera3D, screen_pos: Vector2) -> void:
	if not center_drag_active() or node == null or camera == null:
		return
	if not _center_has_start:
		return
	var pivot_screen := camera.unproject_position(node.global_transform * _center_pivot)
	var start_radius := _center_start_screen.distance_to(pivot_screen)
	var radius := screen_pos.distance_to(pivot_screen)
	if start_radius < 1.0:
		return
	_center_factor = clampf(radius / start_radius, 0.01, 10.0)
	_apply_drag(node, node.pb_mesh_data, PackedInt32Array())

## Commits (or cancels) a center-handle drag through the shared commit
## machinery (undo payloads, topology snapshots, signals).
func commit_center_drag(node: PBMesh, ids: PackedInt32Array, cancel: bool) -> bool:
	if not center_drag_active():
		return false
	return commit_subgizmos(node, ids, cancel)

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
			if _drag_before_op != null:
				# The gesture rewrote topology — restore the whole snapshot.
				PBCommand.restore_mesh_data(mesh_data, _drag_before_op)
				mesh_data.invalidate_caches()
				node.rebuild()
			else:
				mesh_data.positions = _drag_original_positions.duplicate()
				mesh_data.invalidate_caches()
				node.rebuild()
		_reset_drag_state()
		_emit_drag_update(false, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
		return false

	if not drag_active:
		return false

	var action_name := TRANSFORM_ACTION_NAME
	match _drag_gesture:
		DragGesture.EXTRUDE_MOVE:
			action_name = "Extrude (Shift+Move)"
		DragGesture.CENTER_INSET:
			action_name = "Inset (Shift+Scale)"
		DragGesture.CENTER_SCALE:
			action_name = "Scale Elements (Uniform)"

	if _drag_before_op != null:
		# Topology gesture: undo/redo swap whole-mesh snapshots (face ids
		# shifted, per-position payloads don't correspond).
		var after := PBCommand.copy_mesh_data(mesh_data)
		var before := _drag_before_op
		mesh_data.shape_edited = true
		_reset_drag_state()
		_emit_drag_update(false, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
		if undo != null:
			undo.create_action(action_name, UndoRedo.MERGE_DISABLE, node)
			undo.add_do_method(self, "_restore_full_mesh", node.get_instance_id(), after)
			undo.add_undo_method(self, "_restore_full_mesh", node.get_instance_id(), before)
			undo.commit_action()
			if logger != null:
				logger.info("undo", "%s committed (topology)" % action_name)
		drag_topology_committed.emit(node)
		return true

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

	# Any committed geometry edit invalidates "Edit Params" regeneration.
	mesh_data.shape_edited = true

	if undo != null:
		undo.create_action(action_name, UndoRedo.MERGE_DISABLE, node)
		undo.add_do_method(self, "_apply_positions", node.get_instance_id(), union.duplicate(), after)
		undo.add_undo_method(self, "_apply_positions", node.get_instance_id(), union.duplicate(), before)
		undo.commit_action()
		if logger != null:
			logger.info("undo", "%s committed: %d vertices" % [action_name, union.size()])
	return true

## Undo/redo payload for topology gestures: swap a node's whole data from a
## snapshot (node looked up by instance id, skipped silently when freed).
func _restore_full_mesh(node_id: int, snapshot: PBMeshData) -> void:
	var mesh_node: PBMesh = instance_from_id(node_id) as PBMesh
	if mesh_node == null or mesh_node.pb_mesh_data == null:
		return
	PBCommand.restore_mesh_data(mesh_node.pb_mesh_data, snapshot)
	mesh_node.pb_mesh_data.invalidate_caches()
	mesh_node.rebuild()

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
	_drag_gesture = DragGesture.NORMAL
	_drag_union_override = PackedInt32Array()
	_drag_before_op = null
	_drag_inset_bases = []
	_last_inset_amount = 0.0
	_center_factor = 1.0
	_center_has_start = false
	_center_pivot = Vector3.ZERO
	_drag_ids = PackedInt32Array()

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
			# Loops whose seed left the engine selection die with it.
			for seed in selected_loops.keys():
				if not engine_ids.has(seed):
					selected_loops.erase(seed)
			var expanded := expand_edge_ids(mesh_data, engine_ids)
			differs = selection.selected_edges.size() != expanded.size()
			if not differs:
				var edges := mesh_data.get_common_edges()
				for i in range(expanded.size()):
					var eid: int = expanded[i]
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
			for eid in expand_edge_ids(mesh_data, engine_ids):
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

## Human-readable live drag readout for the overlay panel.
func drag_readout() -> String:
	if not _last_drag_active:
		return "—"
	if _drag_gesture == DragGesture.CENTER_INSET and drag_active:
		return "Inset: %.2f" % _last_inset_amount
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
