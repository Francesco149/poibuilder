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
	INSET_SCALE,   ## Shift+scale handles on faces: per-face inset driven by the scale factor (ProBuilder Shift+Scale)
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

## Ring faces' INNER corners (separate duplicates of the pulled corners):
## they must follow the inner face's lerp or a hole opens between the ring
## and the shrinking inner face. Entries: {idx, base, k} — corner position
## index and the inset base/pre-corner it mirrors.
var _drag_ring_bases: Array = []

## Latest inset amount applied this gesture (readout only).
var _last_inset_amount: float = 0.0

## EXTRUDE_MOVE bookkeeping for the live side-winding flip: when the cap is
## dragged back through its base plane, the side quads (wound for the
## original extrude direction at drag begin) would render inside-out —
## "missing faces". The flip rewrites their index triples each update from
## the drag-start snapshot (idempotent, like the position replay).
var _drag_side_faces: Array[PBFace] = []
var _drag_side_tris: Array = []  # PackedInt32Array per side face (original)
var _drag_side_base_e1: Array[Vector3] = []  # base edge (qa->qb) per side face
var _drag_side_flipped: PackedByteArray = PackedByteArray()
var _drag_cap_faces: Array[PBFace] = []
var _drag_cap_tris: Array = []  # PackedInt32Array per cap face (original)
var _drag_cap_flipped: bool = false
var _drag_extrude_region_center: Vector3 = Vector3.ZERO  # seed cap center
var _drag_extrude_normal: Vector3 = Vector3.ZERO
var _extrude_constrained: bool = false

## Live mouse feed (editor only): the plugin forwards every viewport motion
## so the extrude gesture can drive the cap distance from the CURSOR instead
## of trusting the engine's transform composition (4.7.2 delivers a
## basis-relative composition for subgizmo drags whose origin does not track
## the mouse on permuted/flipped element bases — "backwards, doesn't follow
## the mouse"). The mouse-driven path only engages once a REAL motion event
## arrives during the drag; synthetic deliveries (tests) keep the rel path.
var mouse_camera: Camera3D = null
var mouse_screen: Vector2 = Vector2.ZERO
var mouse_has: bool = false
var drag_mouse_active: bool = false
var _extrude_mouse_start: Vector2 = Vector2.ZERO
var _extrude_pivot_world: Vector3 = Vector3.ZERO
var _extrude_normal_world: Vector3 = Vector3.ZERO
var _extrude_px_per_world: float = 0.0
var _drag_mouse_driven: bool = false

## Called by the plugin on every viewport motion event (cheap; always on).
func track_mouse(camera: Camera3D, screen_pos: Vector2) -> void:
	mouse_camera = camera
	mouse_screen = screen_pos
	mouse_has = camera != null
	if drag_active:
		# A real mouse move while a drag runs — the cursor is live.
		drag_mouse_active = true

## Center-handle drag state: screen-space radius ratio about the pivot, and
## the captured pivot/start point. Driven by PBGizmoPlugin handle callbacks.
var _center_factor: float = 1.0
var _center_start_screen: Vector2 = Vector2.ZERO
var _center_pivot: Vector3 = Vector3.ZERO  # node-local
var _center_has_start: bool = false

## Rel cache for engine-delivered drags: identical rels (repeated deliveries
## of the same motion) skip the full position recompute + rebuild.
var _last_rel: Transform3D = Transform3D()
var _last_rel_valid: bool = false

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
		PBEditor.ToolMode.SCALE:
			# ProBuilder spec (VertexManipulationTool.cs): Shift + Scale on
			# faces extrudes zero-thickness and shrinks the new faces inward
			# toward their centroids — a face INSET driven by the scale drag.
			if shift and editor.select_mode == PBEditor.SelectMode.FACE:
				return DragGesture.INSET_SCALE
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
		if logger != null:
			logger.info("drag", "first delivery: id=%d target_origin=%s target_basis_z=%s shift=%s" % [
				id, str(transform.origin), str(transform.basis.z), str(shift)])

	_drag_pending[id] = transform
	_drag_latest_id = id
	# _drag_ids is the begin-time selection (region-expanded in FACE mode) —
	# the engine only delivers the seed id, but the drag moves the whole side.
	_apply_drag(node, mesh_data, _drag_ids)

## Expands face ids to their connected COPLANAR regions (FACE mode only).
## A clicked face stands for its whole side — the door's split shell makes
## each side (front/back around the arch hole included) select, drag, and
## extrude as ONE face. Other modes and single-quad sides pass through.
func expand_face_ids(mesh_data: PBMeshData, ids: PackedInt32Array) -> PackedInt32Array:
	if editor == null or editor.select_mode != PBEditor.SelectMode.FACE:
		return ids
	if mesh_data == null or ids.is_empty():
		return ids
	var out := PackedInt32Array()
	var seen := {}
	for id in ids:
		if id < 0 or id >= mesh_data.faces.size():
			continue
		for fi in mesh_data.get_coplanar_face_region(id):
			if not seen.has(fi):
				seen[fi] = true
				out.append(fi)
	return out

## Begins a drag gesture: decide the gesture from tool+shift, snapshot
## positions and start transforms, then run any begin-time topology op
## (extrude for shift+move, inset for shift+scale). `shift` is injected by
## the caller (live modifier state in the editor; explicit in tests).
func _begin_drag(node: PBMesh, ids: PackedInt32Array, shift: bool) -> void:
	var mesh_data: PBMeshData = node.pb_mesh_data
	if mesh_data == null:
		return
	drag_active = true
	ids = expand_face_ids(mesh_data, ids)
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
	_drag_ring_bases = []
	_last_inset_amount = 0.0
	_center_factor = 1.0
	_center_has_start = false
	_drag_side_faces = []
	_drag_side_tris = []
	_drag_side_base_e1 = []
	_drag_cap_faces = []
	_drag_cap_tris = []
	_drag_cap_flipped = false
	_drag_extrude_region_center = Vector3.ZERO
	_drag_side_flipped = PackedByteArray()
	_drag_extrude_normal = Vector3.ZERO
	_extrude_constrained = false
	_drag_mouse_driven = false
	drag_mouse_active = false
	_last_rel = Transform3D()
	_last_rel_valid = false
	for id in ids:
		_drag_start_xf[id] = get_subgizmo_transform(mesh_data, node, id)

	# Topology-creating gestures undo via whole-mesh snapshots — capture the
	# pre-op state before mutating.
	if _drag_gesture == DragGesture.EXTRUDE_MOVE \
			or _drag_gesture == DragGesture.INSET_SCALE:
		_drag_before_op = PBCommand.copy_mesh_data(mesh_data)

	match _drag_gesture:
		DragGesture.EXTRUDE_MOVE:
			_begin_extrude_move(mesh_data, ids)
		DragGesture.INSET_SCALE:
			_begin_inset(mesh_data, ids)

	if logger != null:
		var start_summary := ""
		for id in ids:
			var xf: Transform3D = _drag_start_xf.get(id, Transform3D())
			start_summary += "[%d] o=%s z=%s " % [id, str(xf.origin),
				str(xf.basis.z)]
		logger.info("drag", "BEGIN %s: mode=%s tool=%s space=%s ids=%d %s" % [
			DragGesture.keys()[_drag_gesture],
			PBEditor.SelectMode.keys()[editor.select_mode] if editor != null else "?",
			PBEditor.ToolMode.keys()[editor.tool_mode] if editor != null else "?",
			PBEditor.OrientationSpace.keys()[editor.orientation_space] if editor != null else "?",
			ids.size(), start_summary])

## Shift+move: extrude the selection at distance 0, then the drag translates
## only the new caps/fins (their lifted corners), CONSTRAINED to the region
## normal (ProBuilder semantics — screen motion projects onto the normal).
## Undo covers the whole gesture via a full-mesh snapshot. Also records the
## created SIDE faces (caps excluded) plus the pre-op region normal, so the
## drag can flip their winding when the cap crosses back through the base
## plane.
func _begin_extrude_move(mesh_data: PBMeshData, ids: PackedInt32Array) -> void:
	# Region normal(s) over the PRE-op geometry (the extrude direction the
	# side quads will be wound for). Must be captured BEFORE the op rewrites
	# the faces array.
	var normal_acc := Vector3.ZERO
	var face_normals: Array[Vector3] = []
	if editor.select_mode == PBEditor.SelectMode.EDGE:
		# Faces adjacent to any selected edge (their average drives the fin
		# direction in the op).
		var common := mesh_data.get_common_edges()
		var lookup := mesh_data.get_shared_vertex_lookup()
		var wanted := {}
		for eid in ids:
			if eid >= 0 and eid < common.size():
				wanted[_edge_key(lookup, common[eid].a, common[eid].b)] = true
		for fi in range(mesh_data.faces.size()):
			var face: PBFace = mesh_data.faces[fi]
			if face == null:
				continue
			for fe in face.get_edges():
				if wanted.has(_edge_key(lookup, fe.a, fe.b)):
					face_normals.append(_face_area_normal(mesh_data, face))
					break
	else:
		for fi in ids:
			if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
				face_normals.append(_face_area_normal(mesh_data, mesh_data.faces[fi]))
	for n in face_normals:
		normal_acc += n
	_drag_extrude_normal = normal_acc.normalized()

	# Normal constraint: only when every extruded face shares (roughly) the
	# same normal — a single region. Multi-normal regions keep the free drag.
	_extrude_constrained = false
	if _drag_extrude_normal.length_squared() > 0.5 and not face_normals.is_empty():
		_extrude_constrained = true
		for n in face_normals:
			if n.normalized().dot(_drag_extrude_normal) < 0.98:
				_extrude_constrained = false
				break

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
		_drag_extrude_normal = Vector3.ZERO
		if logger != null:
			logger.warn("drag", "Extrude begin FAILED (%s) — degrading to plain move" %
				str(result.get("error", "?")))
		return

	# _drag_original_positions was captured PRE-op above; the gesture replays
	# from the POST-op geometry, so re-snapshot now.
	_drag_original_positions = mesh_data.positions.duplicate()
	_drag_union_override = result["drag_positions"]

	# Region center at seed = the average seed position of the drag union
	# (the cap is coincident with the original face at extrude distance 0).
	var region_center := Vector3.ZERO
	if not _drag_union_override.is_empty():
		for idx in _drag_union_override:
			region_center += mesh_data.positions[idx]
		_drag_extrude_region_center = region_center / float(_drag_union_override.size())

	# Side faces = the op's new faces minus the caps (fins extruded from
	# edges ARE the caps — edge gestures get no flip treatment).
	_drag_side_faces = []
	_drag_side_tris = []
	_drag_side_base_e1 = []
	_drag_cap_faces = []
	_drag_cap_tris = []
	if editor.select_mode != PBEditor.SelectMode.EDGE:
		var caps: PackedInt32Array = result["cap_face_ids"]
		var cap_set := {}
		for fi in caps:
			cap_set[fi] = true
			if fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
				_drag_cap_faces.append(mesh_data.faces[fi])
				_drag_cap_tris.append(mesh_data.faces[fi].get_indexes().duplicate())
		for fi in result["new_face_ids"]:
			if not cap_set.has(fi) and fi < mesh_data.faces.size() \
					and mesh_data.faces[fi] != null:
				_drag_side_faces.append(mesh_data.faces[fi])
				var tris := mesh_data.faces[fi].get_indexes()
				_drag_side_tris.append(tris.duplicate())
				# Base edge of the wall quad (qa -> qb): its first two
				# corners; they never move during the drag.
				_drag_side_base_e1.append(
					mesh_data.positions[tris[1]] - mesh_data.positions[tris[0]])
	_drag_side_flipped = PackedByteArray()
	_drag_side_flipped.resize(_drag_side_faces.size())
	_drag_cap_flipped = false

	# Mouse-driven extrusion baseline: the cursor position at gesture begin,
	# the cap pivot in world space, and the extrude normal in world space
	# (rotated out of node space so the space setting cannot skew it).
	_drag_mouse_driven = false
	if mouse_has and mouse_camera != null and _drag_mesh != null \
			and not _drag_union_override.is_empty():
		_extrude_mouse_start = mouse_screen
		_extrude_pivot_world = _drag_mesh.global_transform \
			* mesh_data.positions[_drag_union_override[0]]
		_extrude_normal_world = (_drag_mesh.global_transform.basis
			* _drag_extrude_normal).normalized()
		var d1: Vector2 = mouse_camera.unproject_position(_extrude_pivot_world)
		var d2: Vector2 = mouse_camera.unproject_position(
			_extrude_pivot_world + _extrude_normal_world * 1.0)
		_extrude_px_per_world = (d2 - d1).length()

	if logger != null:
		logger.info("drag", "Extrude seed ok: normal(node)=%s normal(world)=%s constrained=%s caps=%d sides=%d union=%d px_per_world=%.1f" % [
			str(_drag_extrude_normal), str(_extrude_normal_world),
			str(_extrude_constrained),
			result["cap_face_ids"].size(), _drag_side_faces.size(),
			_drag_union_override.size(), _extrude_px_per_world])

## Area-weighted normal of one face (pre-op geometry helper).
static func _face_area_normal(mesh_data: PBMeshData, face: PBFace) -> Vector3:
	var acc := Vector3.ZERO
	var idxs := face.get_indexes()
	var p := mesh_data.positions
	for t in range(0, idxs.size() - 2, 3):
		if idxs[t] >= p.size() or idxs[t + 1] >= p.size() or idxs[t + 2] >= p.size():
			continue
		acc += (p[idxs[t + 1]] - p[idxs[t]]).cross(p[idxs[t + 2]] - p[idxs[t]])
	return acc

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

	# The ring faces' inner corners are SEPARATE duplicates of the pulled
	# corners; they must follow the inner face's lerp exactly, or a hole
	# opens between the ring and the shrinking inner face ("additional
	# faces not visible"). Map each ring corner to the base/pre-corner it
	# mirrors (match by seed position — the pulled coordinate).
	var pulled: Array[Vector3] = []
	var pull_ref: Array = []
	for b_i in range(_drag_inset_bases.size()):
		var base: Dictionary = _drag_inset_bases[b_i]
		var pre_corners: PackedVector3Array = base["pre"]
		var cen: Vector3 = base["centroid"]
		for k in range(pre_corners.size()):
			pulled.append(pre_corners[k].lerp(cen, 0.01))
			pull_ref.append({"base": b_i, "k": k})
	var ring_ids: PackedInt32Array = result["new_face_ids"]
	var cap_set := {}
	for ci in cap_ids:
		cap_set[ci] = true
	for fi in ring_ids:
		if cap_set.has(fi) or fi >= mesh_data.faces.size() or mesh_data.faces[fi] == null:
			continue
		for cidx in mesh_data.faces[fi].get_distinct_indexes():
			var p: Vector3 = mesh_data.positions[cidx]
			for j in range(pulled.size()):
				if p.distance_squared_to(pulled[j]) < 1e-8:
					_drag_ring_bases.append({
						"idx": cidx,
						"base": pull_ref[j]["base"],
						"k": pull_ref[j]["k"],
					})
					break

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
	# factor and skip this entirely. Repeated identical rels (multi-id
	# selections redeliver the same motion) skip the full recompute.
	var rel: Transform3D = _last_rel
	if _drag_gesture == DragGesture.NORMAL or _drag_gesture == DragGesture.EXTRUDE_MOVE \
			or _drag_gesture == DragGesture.INSET_SCALE:
		if _drag_latest_id == -1 or not _drag_start_xf.has(_drag_latest_id) \
				or not _drag_pending.has(_drag_latest_id):
			return
		rel = _drag_pending[_drag_latest_id] * _drag_start_xf[_drag_latest_id].affine_inverse()
		if _last_rel_valid and rel.is_equal_approx(_last_rel):
			return
		_last_rel = rel
		_last_rel_valid = true

	var new_positions := _drag_original_positions.duplicate()
	var pos_count: int = new_positions.size()
	var applied_motion := Vector3.ZERO

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
			_apply_ring_lerp(new_positions, pos_count, amount)
			_emit_drag_update(true, Vector3(amount, 0, 0), Vector3.ZERO, Vector3.ONE)
		DragGesture.INSET_SCALE:
			# The engine delivers a per-axis scale about the subgizmo origin;
			# the inset amount is the dominant scale deviation from 1.
			var s := _dominant_scale_factor(rel.basis)
			var amount := clampf(1.0 - s, -1.0, 0.95)
			_last_inset_amount = amount
			for base in _drag_inset_bases:
				var idxs: PackedInt32Array = base["idxs"]
				var centroid: Vector3 = base["centroid"]
				var pre: PackedVector3Array = base["pre"]
				for i in range(idxs.size()):
					var idx: int = idxs[i]
					if idx >= 0 and idx < pos_count:
						new_positions[idx] = pre[i].lerp(centroid, amount)
			_apply_ring_lerp(new_positions, pos_count, amount)
			_emit_drag_update(true, Vector3(amount, 0, 0), Vector3.ZERO, Vector3.ONE)
		DragGesture.INSET_SCALE:
			# The engine delivers a per-axis scale about the subgizmo origin;
			# the inset amount is the dominant scale deviation from 1.
			var s := _dominant_scale_factor(rel.basis)
			var amount := clampf(1.0 - s, -1.0, 0.95)
			_last_inset_amount = amount
			for base in _drag_inset_bases:
				var idxs: PackedInt32Array = base["idxs"]
				var centroid: Vector3 = base["centroid"]
				var pre: PackedVector3Array = base["pre"]
				for i in range(idxs.size()):
					var idx: int = idxs[i]
					if idx >= 0 and idx < pos_count:
						new_positions[idx] = pre[i].lerp(centroid, amount)
			_apply_ring_lerp(new_positions, pos_count, amount)
			_emit_drag_update(true, Vector3(amount, 0, 0), Vector3.ZERO, Vector3.ONE)
		DragGesture.CENTER_SCALE:
			var pivot := _center_pivot
			if logger != null and PBLogger.verbose:
				logger.debug("drag", "CENTER_SCALE apply: factor=%.3f union=%d pivot=%s" % [
					_center_factor, union.size(), str(pivot)])
			for idx in union:
				if idx >= 0 and idx < pos_count:
					new_positions[idx] = pivot + (_drag_original_positions[idx] - pivot) * _center_factor
			_emit_drag_update(true, pivot - pivot * _center_factor, Vector3.ZERO, Vector3.ONE * _center_factor)
		_:
			# Move gestures are PURE TRANSLATIONS: apply the origin only.
			# The engine composes axis/view-plane drags as translations, so
			# the basis must be identity — if it is not, the engine's
			# delivered composition does not match our start snapshot, and
			# applying the full rel would shear/rotate the mesh ("twisted
			# geometry"). Log loudly: that mismatch is exactly what the
			# debug log is for. ROTATE/SCALE still apply the full rel.
			var origin_only: bool = _drag_gesture == DragGesture.EXTRUDE_MOVE \
				or (_drag_gesture == DragGesture.NORMAL \
					and editor != null and editor.tool_mode == PBEditor.ToolMode.MOVE)
			var motion := rel.origin
			if origin_only:
				if not rel.basis.is_equal_approx(Basis()) and logger != null:
					logger.warn("drag", "REL BASIS NOT IDENTITY on a %s gesture — engine composition mismatch? origin=%s (positions use the origin only)" % [
						DragGesture.keys()[_drag_gesture], str(rel.origin)])
				# EXTRUDE_MOVE verification against the live cursor: the
				# engine rel SHOULD track the mouse along the extrude
				# normal's screen axis. When it visibly disagrees (sign or
				# scale error along the normal — the reported "extrudes
				# backwards, doesn't follow the mouse"), take the distance
				# from the cursor instead. A lateral engine motion is a
				# legitimate move of the extruded cap and is NOT overridden.
				if _drag_gesture == DragGesture.EXTRUDE_MOVE and drag_mouse_active \
						and mouse_has and mouse_camera != null \
						and _extrude_px_per_world > 2.0:
					var axis_screen: Vector2 = (
						mouse_camera.unproject_position(
							_extrude_pivot_world + _extrude_normal_world)
						- mouse_camera.unproject_position(_extrude_pivot_world)
					).normalized()
					var mouse_world_dist: float = (mouse_screen - _extrude_mouse_start) \
						.dot(axis_screen) / _extrude_px_per_world
					var rel_normal_dist: float = rel.origin.dot(_drag_extrude_normal)
					var dist_error: float = absf(rel_normal_dist - mouse_world_dist)
					var dist_tolerance: float = maxf(0.1, 0.35 * absf(mouse_world_dist))
					if dist_error > dist_tolerance:
						motion = _drag_extrude_normal * mouse_world_dist
						if not _drag_mouse_driven and logger != null:
							logger.warn("drag", "EXTRUDE MISMATCH — engine rel along normal=%.3f but cursor says %.3f (px_per_world=%.1f); driving the cap from the cursor" % [rel_normal_dist, mouse_world_dist, _extrude_px_per_world])
						_drag_mouse_driven = true
				# Spec (VertexManipulationTool.cs): shift+move extrudes at
				# begin, then ApplyTranslation pulls the new faces along the
				# translation delta — the cap follows the cursor.
				applied_motion = motion
				for idx in union:
					if idx >= 0 and idx < pos_count:
						new_positions[idx] = _drag_original_positions[idx] + motion
				if logger != null and PBLogger.verbose:
					logger.debug("drag", "apply %s: rel_origin=%s motion=%s union=%d mouse_driven=%s" % [
						DragGesture.keys()[_drag_gesture], str(rel.origin), str(motion),
						union.size(), str(_drag_mouse_driven)])
				_emit_drag_update(true, motion, Vector3.ZERO, Vector3.ONE)
			else:
				for idx in union:
					if idx >= 0 and idx < pos_count:
						new_positions[idx] = rel * _drag_original_positions[idx]
				_emit_drag_update(true, rel.origin, _rel_rotation_deg(rel), rel.basis.get_scale())

	mesh_data.positions = new_positions

	# EXTRUDE_MOVE: the CAP flips when the sweep reverses against the extrude
	# normal (the cap leads the sweep — its outward follows the sweep
	# direction); each SIDE wall flips independently when its winding points
	# into the swept solid (checked against the translated region center).
	# Both rewrites come from the drag-start snapshot (idempotent).
	var flipped_now := false
	if _drag_gesture == DragGesture.EXTRUDE_MOVE and not _drag_cap_faces.is_empty():
		var crossed := applied_motion.dot(_drag_extrude_normal) < 0.0
		if crossed != _drag_cap_flipped:
			_drag_cap_flipped = crossed
			flipped_now = true
			for i in range(_drag_cap_faces.size()):
				_set_face_winding(_drag_cap_faces[i], _drag_cap_tris[i], crossed)
	if _drag_gesture == DragGesture.EXTRUDE_MOVE and not _drag_side_faces.is_empty() \
			and applied_motion.length_squared() > 0.000000001:
		var sweep := applied_motion
		var translated_center := _drag_extrude_region_center + sweep
		for i in range(_drag_side_faces.size()):
			var tris: PackedInt32Array = _drag_side_tris[i]
			var a: Vector3 = mesh_data.positions[tris[0]]
			var b: Vector3 = mesh_data.positions[tris[1]]
			var a2: Vector3 = mesh_data.positions[tris[4]]
			var e1 := _drag_side_base_e1[i]
			var winding_n := e1.cross(sweep)
			if winding_n.length_squared() < 0.000000001:
				continue
			var wall_center := (a + b + a2 * 2.0) * 0.25
			var outward := wall_center - translated_center
			# Combine both references: the radial handles normal-axis
			# crossings; the extrude normal handles walls folded by sideways
			# sweeps. A wall whose winding disagrees with either enough to
			# go negative is inside-out.
			var wants_flipped: bool = winding_n.normalized().dot(
				(outward.normalized() + _drag_extrude_normal).normalized()) < 0.0
			if wants_flipped != bool(_drag_side_flipped[i]):
				_drag_side_flipped[i] = 1 if wants_flipped else 0
				_set_face_winding(_drag_side_faces[i], tris, wants_flipped)
				flipped_now = true

	if flipped_now:
		# A winding flip changes the side faces' normals too (including the
		# base corners outside the drag union) — full recompute, once.
		mesh_data.calculate_normals()
	else:
		# Position edits never change the common-edge list or weld groups
		# (index pairs/groups), and only the drag union's normals change —
		# incremental updates keep the per-motion cost flat instead of
		# rebuilding every normal on each mouse move.
		mesh_data.update_normals_for(union)
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
	ids = expand_face_ids(mesh_data, ids)
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
		logger.info("drag", "CENTER drag begun: %s, %d element(s), pivot=%s start_screen=%s inset=%s" % [
			DragGesture.keys()[_drag_gesture], ids.size(), str(pivot),
			str(start_screen), str(inset)])
	return true

## Applies the drag from the current screen point: the HORIZONTAL screen
## delta from the drag start drives uniform scale or inset (ProBuilder-style
## center handle: drag right = smaller, drag left = bigger, 1% per pixel).
## A pure screen delta (no radius ratio about the pivot) can never explode:
## the old radius ratio divided by a near-zero start radius when the handle
## was grabbed dead-on, jumping the factor to its clamp.
func apply_center_drag(node: PBMesh, camera: Camera3D, screen_pos: Vector2) -> void:
	if not center_drag_active() or node == null or camera == null:
		return
	if not _center_has_start:
		return
	_center_factor = clampf(1.0 - (screen_pos.x - _center_start_screen.x) * 0.01, 0.01, 10.0)
	if logger != null and PBLogger.verbose:
		logger.debug("drag", "center apply: screen_dx=%.1f factor=%.3f" % [
			screen_pos.x - _center_start_screen.x, _center_factor])
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

	# The undo payload must cover exactly what the drag moved — expand to the
	# same regions the begin-time selection used (stable across the drag via
	# the mesh data's region cache).
	ids = expand_face_ids(mesh_data, ids)

	var action_name := TRANSFORM_ACTION_NAME
	match _drag_gesture:
		DragGesture.EXTRUDE_MOVE:
			action_name = "Extrude (Shift+Move)"
		DragGesture.CENTER_INSET, DragGesture.INSET_SCALE:
			action_name = "Inset (Shift+Scale)"
		DragGesture.CENTER_SCALE:
			action_name = "Scale Elements (Uniform)"

	if _drag_before_op != null:
		# Topology gesture: undo/redo swap whole-mesh snapshots (face ids
		# shifted, per-position payloads don't correspond).
		# The drag separated positions that the seed-time weld groups still
		# tie together (a zero-distance seed merges every coincident corner
		# into one group; the drag moves only the cap/lifted dups). Rebuild
		# from post-drag coincidence BEFORE snapshotting, or the next grab's
		# union carries the unmoved bases ("moving the extruded face moves
		# the whole extruded part" / "one vert left behind" tears) and the
		# group-pair dedup drops the cap's edges from the edge list.
		mesh_data.rebuild_welds()
		var after := PBCommand.copy_mesh_data(mesh_data)
		var before := _drag_before_op
		mesh_data.shape_edited = true
		_log_face_orientation_audit(mesh_data)
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
## Commit-time audit for topology gestures: signed volume + per-face
## outwardness (face normal vs direction from the mesh centroid). A
## negative dot means the face is wound INWARD - the concrete "which faces
## are inverted" answer when the render shows missing faces.
func _log_face_orientation_audit(mesh_data: PBMeshData) -> void:
	if logger == null or not PBLogger.verbose or mesh_data.positions.is_empty():
		return
	var p := mesh_data.positions
	var cen := Vector3.ZERO
	for pos in p:
		cen += pos
	cen /= float(p.size())
	var vol := 0.0
	var inverted: Array[int] = []
	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var idxs := face.get_indexes()
		var fvol := 0.0
		var fnorm := Vector3.ZERO
		for t in range(0, idxs.size() - 2, 3):
			if idxs[t] >= p.size() or idxs[t + 1] >= p.size() or idxs[t + 2] >= p.size():
				continue
			fvol += p[idxs[t]].dot(p[idxs[t + 1]].cross(p[idxs[t + 2]]))
			fnorm += (p[idxs[t + 1]] - p[idxs[t]]).cross(p[idxs[t + 2]] - p[idxs[t]])
		vol += fvol
		var fcen := Vector3.ZERO
		var n := 0
		for idx in face.get_distinct_indexes():
			if idx < p.size():
				fcen += p[idx]
				n += 1
		if n > 0:
			fcen /= float(n)
		if fnorm.length_squared() > 0.000000001 and fnorm.normalized().dot((fcen - cen).normalized()) < -0.05:
			inverted.append(fi)
	logger.info("audit", "face orientation: F=%d V=%d signed_volume=%.3f (tetra sum /6) inward_wound_faces=%s" % [mesh_data.faces.size(), p.size(), vol / 6.0, str(inverted)])


## Compiles what the GPU actually draws: reads the node's ArrayMesh
## surfaces, counts triangles, and flags any whose RENDERED winding points
## inward. The data-side audit can pass while the compiled mesh disagrees -
## this split locates a "missing faces" report definitively.
func _render_triangle_audit(mesh_node: PBMesh) -> void:
	if logger == null or not PBLogger.verbose \
			or mesh_node.mesh == null or mesh_node.pb_mesh_data == null:
		return
	var p := mesh_node.pb_mesh_data.positions
	var cen := Vector3.ZERO
	for pos in p:
		cen += pos
	cen /= float(p.size())
	var rendered_tris := 0
	var inverted: Array[int] = []
	for s in range(mesh_node.mesh.get_surface_count()):
		var arrays: Array = mesh_node.mesh.surface_get_arrays(s)
		if arrays.is_empty() or arrays[Mesh.ARRAY_INDEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			verts = p
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size() - 2, 3):
			var a: Vector3 = verts[idx[t]]
			var b: Vector3 = verts[idx[t + 1]]
			var c: Vector3 = verts[idx[t + 2]]
			rendered_tris += 1
			var n := (b - a).cross(c - a)
			var tc := (a + b + c) / 3.0
			# Godot renders CW front faces: after to_array_mesh's reversal a
			# CORRECT triangle's geometric normal points INTO the mesh. A
			# rendered normal pointing OUTWARD = inside-out (culled) face.
			if n.length_squared() > 0.000000001 and n.normalized().dot((tc - cen).normalized()) > 0.05:
				inverted.append(rendered_tris - 1)
	var data_tris: int = mesh_node.pb_mesh_data.index_count() / 3
	logger.info("audit", "render triangles=%d data_triangles=%d rendered_inward=%s" % [rendered_tris, data_tris, str(inverted)])
func _restore_full_mesh(node_id: int, snapshot: PBMeshData) -> void:
	var mesh_node: PBMesh = instance_from_id(node_id) as PBMesh
	if mesh_node == null or mesh_node.pb_mesh_data == null:
		if logger != null:
			logger.warn("undo", "_restore_full_mesh skipped (node %d missing or dataless)" % node_id)
		return
	PBCommand.restore_mesh_data(mesh_node.pb_mesh_data, snapshot)
	mesh_node.pb_mesh_data.invalidate_caches()
	mesh_node.rebuild()
	mesh_node.update_gizmos()
	if logger != null:
		logger.info("undo", "_restore_full_mesh applied on %s: V=%d F=%d (render rebuilt + gizmo refreshed)" % [
			mesh_node.name, mesh_node.pb_mesh_data.positions.size(),
			mesh_node.pb_mesh_data.faces.size()])
		_render_triangle_audit(mesh_node)

## Reapplies a position subset by node instance id (undo/redo payload).
## Instance id survives history replay; missing nodes are skipped silently.
func _apply_positions(node_id: int, indices: PackedInt32Array, positions_subset: PackedVector3Array) -> void:
	var node: PBMesh = instance_from_id(node_id) as PBMesh
	if node == null or node.pb_mesh_data == null:
		if logger != null:
			logger.warn("undo", "_apply_positions skipped (node %d missing or dataless)" % node_id)
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
	_drag_ring_bases = []
	_last_inset_amount = 0.0
	_center_factor = 1.0
	_center_has_start = false
	_center_pivot = Vector3.ZERO
	_drag_ids = PackedInt32Array()
	_drag_side_faces = []
	_drag_side_tris = []
	_drag_side_base_e1 = []
	_drag_cap_faces = []
	_drag_cap_tris = []
	_drag_cap_flipped = false
	_drag_extrude_region_center = Vector3.ZERO
	_drag_side_flipped = PackedByteArray()
	_drag_extrude_normal = Vector3.ZERO
	_extrude_constrained = false
	_drag_mouse_driven = false
	drag_mouse_active = false
	_last_rel = Transform3D()
	_last_rel_valid = false

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

## Writes a face's triangle winding, flipped or as originally captured.
func _set_face_winding(face: PBFace, tris: PackedInt32Array, flipped: bool) -> void:
	if flipped:
		var out := PackedInt32Array()
		out.resize(tris.size())
		for t in range(0, tris.size() - 2, 3):
			out[t] = tris[t + 2]
			out[t + 1] = tris[t + 1]
			out[t + 2] = tris[t]
		face.set_indexes(out)
	else:
		face.set_indexes(tris.duplicate())

## Lerps the ring faces' inner corners with the SAME amount as the inner
## faces (they are duplicates of the pulled corners) — keeps the ring
## welded to the shrinking inner face (no hole).
func _apply_ring_lerp(new_positions: PackedVector3Array, pos_count: int,
		amount: float) -> void:
	for rc in _drag_ring_bases:
		var idx: int = rc["idx"]
		if idx < 0 or idx >= pos_count:
			continue
		var base: Dictionary = _drag_inset_bases[rc["base"]]
		var pre: PackedVector3Array = base["pre"]
		var centroid: Vector3 = base["centroid"]
		new_positions[idx] = pre[rc["k"]].lerp(centroid, amount)

## The basis scale component furthest from 1 — the axis the user is
## dragging on a scale-handle gesture.
static func _dominant_scale_factor(b: Basis) -> float:
	var sc := b.get_scale()
	var best: float = sc.x
	if absf(sc.y - 1.0) > absf(best - 1.0):
		best = sc.y
	if absf(sc.z - 1.0) > absf(best - 1.0):
		best = sc.z
	return best

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
