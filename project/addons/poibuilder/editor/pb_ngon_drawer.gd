## PBNgonDrawer — Interactive polygon drawing controller for Knife tool and N-Gon Shape Extrusion.
##
## Runtime-safe, pure logic (no editor classes, headless-testable).
## Driven from the plugin's _forward_3d_gui_input:
##
## Shared UX:
## - Click on any surface (or grid) to place vertices.
## - Live visible overlay shows placed vertices connected by lines,
##   plus a live rubber-band line to the cursor with a vertex indicator under mouse.
## - Click and drag existing placed vertices to reposition them along the surface plane.
## - Snapping: snaps to placed vertices, target mesh edges and vertices, and the grid.
## - Enter completes the polygon:
##   - Knife: cuts the face (edge-to-edge cut splits face in two; closed loop cuts inner/outer).
##   - N-Gon: transitions to HEIGHT phase to adjust 3rd dimension by moving mouse,
##     LMB click confirms extrusion into a 3D prism.
## - ESC cancels/aborts cleanly.
@tool
class_name PBNgonDrawer
extends RefCounted

enum Mode { NONE, KNIFE, NGON_EXTRUDE }
enum State { INACTIVE, ARMED, DRAWING, DRAGGING_VERT, HEIGHT }

const RAY_MISS := Vector3(INF, INF, INF)
const SNAP_VERT_DISTANCE := 0.15
const SNAP_EDGE_DISTANCE := 0.12

var mode: Mode = Mode.NONE
var state: State = State.INACTIVE

## Drawing plane captured on first click
var plane_point: Vector3 = Vector3.ZERO
var plane_normal: Vector3 = Vector3.UP

## In-plane orthonormal axes
var u_axis: Vector3 = Vector3.RIGHT
var v_axis: Vector3 = Vector3.FORWARD

## Target mesh and face index (used by Knife tool)
var target_mesh: PBMesh = null
var target_face_index: int = -1

## Placed 3D vertices on the drawing plane (world space)
var points: Array[Vector3] = []

## Live cursor point on the plane (world space)
var live_cursor_point: Vector3 = Vector3.ZERO

## Hover and drag tracking for placed vertices
var hovered_vert_idx: int = -1
var dragged_vert_idx: int = -1

## Extrusion height for NGON_EXTRUDE
var height: float = 0.0

## Preview node for live 3D extrusion preview
var preview_node: PBMesh = null

## Plugin grid for snapping
var grid: PBGrid = null

# ==============================================================================
# Lifecycle & State Management
# ==============================================================================

func is_active() -> bool:
	return state != State.INACTIVE

func arm(p_mode: Mode, p_mesh: PBMesh = null, p_face: int = -1) -> void:
	reset()
	mode = p_mode
	state = State.ARMED
	target_mesh = p_mesh
	target_face_index = p_face

func begin(point: Vector3, normal: Vector3, p_mesh: PBMesh = null, p_face: int = -1) -> void:
	plane_point = point
	plane_normal = normal.normalized()
	if plane_normal.length_squared() < 0.0001:
		plane_normal = Vector3.UP

	var up := Vector3.UP if absf(plane_normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	u_axis = plane_normal.cross(up).normalized()
	v_axis = plane_normal.cross(u_axis).normalized()

	if p_mesh != null:
		target_mesh = p_mesh
	if p_face >= 0:
		target_face_index = p_face

	points.clear()
	var snapped_pt := _snap_point(point)
	points.append(snapped_pt)
	live_cursor_point = snapped_pt
	hovered_vert_idx = -1
	dragged_vert_idx = -1
	state = State.DRAWING

func add_point(point: Vector3) -> bool:
	if state != State.DRAWING:
		return false
	var snapped_pt := _snap_point(point)
	# Disallow placing right on top of the last vertex
	if not points.is_empty() and points[points.size() - 1].distance_to(snapped_pt) < 0.001:
		return false
	points.append(snapped_pt)
	return true

func start_drag_vert(idx: int) -> void:
	if idx >= 0 and idx < points.size():
		dragged_vert_idx = idx
		state = State.DRAGGING_VERT

func end_drag_vert() -> void:
	if state == State.DRAGGING_VERT:
		dragged_vert_idx = -1
		state = State.DRAWING

func update_cursor_plane(raw_point: Vector3) -> void:
	if state == State.INACTIVE or state == State.ARMED or state == State.HEIGHT:
		return

	# Project point strictly onto plane
	var proj := raw_point - plane_normal * plane_normal.dot(raw_point - plane_point)
	var snapped_pt := _snap_point(proj)
	live_cursor_point = snapped_pt

	if state == State.DRAGGING_VERT and dragged_vert_idx >= 0 and dragged_vert_idx < points.size():
		points[dragged_vert_idx] = snapped_pt
		hovered_vert_idx = dragged_vert_idx
		return

	# Update hovered vertex index
	hovered_vert_idx = -1
	var best_d := SNAP_VERT_DISTANCE
	for i in range(points.size()):
		var d := proj.distance_to(points[i])
		if d < best_d:
			best_d = d
			hovered_vert_idx = i

func update_height_point(ref_point: Vector3) -> void:
	if state != State.HEIGHT:
		return
	var raw := plane_normal.dot(ref_point - plane_point)
	if grid != null and grid.enabled:
		raw = grid.snap_val(raw)
	height = raw

func complete() -> Dictionary:
	if state != State.DRAWING and state != State.DRAGGING_VERT:
		return {"ok": false, "error": "Not in drawing state"}

	if points.size() < 2:
		return {"ok": false, "error": "Need at least 2 points"}

	if mode == Mode.KNIFE:
		return _complete_knife()
	elif mode == Mode.NGON_EXTRUDE:
		return _complete_ngon_extrude()
	return {"ok": false, "error": "Unknown mode"}

func _complete_knife() -> Dictionary:
	if target_mesh == null or target_mesh.pb_mesh_data == null:
		return {"ok": false, "error": "Knife: no target mesh"}
	if target_face_index < 0 or target_face_index >= target_mesh.pb_mesh_data.faces.size():
		return {"ok": false, "error": "Knife: no target face"}

	var local_points := PackedVector3Array()
	var inv_xf := target_mesh.global_transform.affine_inverse()
	for p in points:
		local_points.append(inv_xf * p)

	# If first and last vertex match within 1mm, it's a closed loop
	var is_closed := false
	if local_points.size() >= 3 and local_points[0].distance_to(local_points[local_points.size() - 1]) < 0.001:
		is_closed = true

	var res := PBMeshOps.cut_face(target_mesh.pb_mesh_data, target_face_index, local_points, is_closed)
	if res.get("ok", false):
		state = State.INACTIVE
	return res

func _complete_ngon_extrude() -> Dictionary:
	if points.size() < 3:
		return {"ok": false, "error": "N-Gon extrude requires at least 3 points"}

	# Ensure closed loop
	if points[0].distance_to(points[points.size() - 1]) < 0.001:
		points.remove_at(points.size() - 1)
	if points.size() < 3:
		return {"ok": false, "error": "N-Gon extrude requires at least 3 points"}

	state = State.HEIGHT
	height = 0.0
	return {"ok": true, "action": "enter_height"}

func confirm_height() -> Dictionary:
	if state != State.HEIGHT:
		return {"ok": false, "error": "Not in height state"}

	var poly := PackedVector3Array()
	for p in points:
		poly.append(p)

	var eff_height := height if absf(height) > 0.0001 else 0.05
	var data := PBShapeComplex.create_ngon_prism(poly, eff_height, plane_normal)
	if data == null:
		reset()
		return {"ok": false, "error": "Failed to create n-gon prism"}

	var centroid := Vector3.ZERO
	for p in poly:
		centroid += p
	centroid /= float(poly.size())

	# Center mesh data positions around origin so transform is clean
	var local_data := PBShapeComplex.create_ngon_prism(
		poly, eff_height, plane_normal
	)
	for i in range(local_data.positions.size()):
		local_data.positions[i] -= centroid

	var placement := Transform3D(Basis(), centroid)

	var result := {
		"ok": true,
		"data": local_data,
		"transform": placement,
		"height": eff_height,
		"normal": plane_normal
	}
	reset()
	return result

func build_preview_data() -> PBMeshData:
	if state != State.HEIGHT:
		return null
	var poly := PackedVector3Array()
	for p in points:
		poly.append(p)
	var eff_height := height if absf(height) > 0.0001 else 0.001
	return PBShapeComplex.create_ngon_prism(poly, eff_height, plane_normal)

func reset() -> void:
	mode = Mode.NONE
	state = State.INACTIVE
	plane_point = Vector3.ZERO
	plane_normal = Vector3.UP
	target_mesh = null
	target_face_index = -1
	points.clear()
	live_cursor_point = Vector3.ZERO
	hovered_vert_idx = -1
	dragged_vert_idx = -1
	height = 0.0
	preview_node = null

# ==============================================================================
# Snapping & Geometry Helpers
# ==============================================================================

func _snap_point(p: Vector3) -> Vector3:
	# 1. Snap to placed vertices
	for i in range(points.size()):
		if state == State.DRAGGING_VERT and i == dragged_vert_idx:
			continue
		if p.distance_to(points[i]) <= SNAP_VERT_DISTANCE:
			return points[i]

	# 2. Snap to target mesh face vertices & edges
	if target_mesh != null and target_mesh.pb_mesh_data != null and target_face_index >= 0:
		var md: PBMeshData = target_mesh.pb_mesh_data
		var xf := target_mesh.global_transform
		if target_face_index < md.faces.size():
			var face := md.faces[target_face_index]
			var dist_idxs := face.get_distinct_indexes()

			# Snap to corners
			for idx in dist_idxs:
				var world_corner: Vector3 = xf * md.positions[idx]
				if p.distance_to(world_corner) <= SNAP_VERT_DISTANCE:
					return world_corner

			# Snap to edges
			for edge in face.get_edges():
				var wa: Vector3 = xf * md.positions[edge.a]
				var wb: Vector3 = xf * md.positions[edge.b]
				var ab := wb - wa
				var len2 := ab.length_squared()
				if len2 > 0.000001:
					var t := clampf((p - wa).dot(ab) / len2, 0.0, 1.0)
					var edge_pt := wa + ab * t
					if p.distance_to(edge_pt) <= SNAP_EDGE_DISTANCE:
						return edge_pt

	# 3. Snap to grid if enabled
	if grid != null and grid.enabled:
		return _snap_to_grid(p)

	return p

func _snap_to_grid(p: Vector3) -> Vector3:
	var s: float = grid.step()
	if s <= 0.0001:
		return p
	# Snap along in-plane u/v axes relative to plane_point
	var d := p - plane_point
	var u: float = grid.snap_val(d.dot(u_axis))
	var v: float = grid.snap_val(d.dot(v_axis))
	return plane_point + u_axis * u + v_axis * v

static func ray_plane_intersect(ray_o: Vector3, ray_d: Vector3, plane_pt: Vector3, plane_norm: Vector3) -> Vector3:
	var denom := plane_norm.dot(ray_d)
	if absf(denom) < 0.00001:
		return RAY_MISS
	var t := plane_norm.dot(plane_pt - ray_o) / denom
	if t < 0.0:
		return RAY_MISS
	return ray_o + ray_d * t
