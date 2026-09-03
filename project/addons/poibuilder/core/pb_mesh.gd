## PBMesh — MeshInstance3D wrapper node that holds a PBMeshData resource and compiles it to ArrayMesh.
##
## This is the primary scene-tree node in PoiBuilder. It holds the editable geometry
## data in a PBMeshData resource and synchronizes it with its own MeshInstance3D.mesh (an ArrayMesh).
@tool
class_name PBMesh
extends MeshInstance3D

# ==============================================================================
# Collider Enums & Exported Properties
# ==============================================================================

## Types of collision generation supported by PoiBuilder meshes.
enum ColliderType {
	OFF = 0,        ## Collision disabled (no physics body)
	ACCURATE = 1,   ## Geometry-accurate trimesh (ConcavePolygonShape3D)
	RAMP = 2,       ## Smooth ramp collider without steps (Stairs only)
}

const COLLIDER_BODY_NAME := "StaticBody3D"
const COLLIDER_SHAPE_NAME := "CollisionShape3D"

## The editable mesh data resource.
@export var pb_mesh_data: PBMeshData = null:
	set = set_pb_mesh_data

## The physics collider generation mode.
@export var collider_type: ColliderType = ColliderType.ACCURATE:
	set = set_collider_type

var _collider_type_explicit: bool = false

# ==============================================================================
# Internal State
# ==============================================================================

## Whether the compiled mesh needs rebuilding.
var _needs_rebuild: bool = false
# ==============================================================================
# Lifecycle
# ==============================================================================

func _ready() -> void:
	if pb_mesh_data != null:
		rebuild()
	else:
		_update_collider()

func _validate_property(property: Dictionary) -> void:
	if property.name == "collider_type":
		if is_stairs():
			property.hint = PROPERTY_HINT_ENUM
			property.hint_string = "Off:0,Geometry Accurate:1,Ramp:2"
		else:
			property.hint = PROPERTY_HINT_ENUM
			property.hint_string = "Off:0,Geometry Accurate:1"

# ==============================================================================
# Property Setters & Rebuild
# ==============================================================================

## Returns true if the underlying mesh is a straight or curved stair primitive.
func is_stairs() -> bool:
	if pb_mesh_data == null:
		return false
	return pb_mesh_data.shape_id == &"stair" or pb_mesh_data.shape_id == &"curved_stair"

## Sets the collider generation mode.
func set_collider_type(value: int) -> void:
	var new_type: ColliderType = value as ColliderType
	if not is_stairs() and new_type == ColliderType.RAMP:
		new_type = ColliderType.ACCURATE
	if collider_type == new_type and _has_valid_collider():
		return
	collider_type = new_type
	_collider_type_explicit = true
	if is_inside_tree():
		_update_collider()

## Sets the PBMeshData resource. Marks for rebuild and triggers rebuild if inside scene tree.
func set_pb_mesh_data(value: PBMeshData) -> void:
	pb_mesh_data = value
	_needs_rebuild = true
	if not _collider_type_explicit:
		if is_stairs():
			collider_type = ColliderType.RAMP
		else:
			collider_type = ColliderType.ACCURATE
	elif collider_type == ColliderType.RAMP and not is_stairs():
		collider_type = ColliderType.ACCURATE
	notify_property_list_changed()
	if is_inside_tree():
		rebuild()
## Compiles pb_mesh_data into an ArrayMesh and assigns it to self.mesh.
## A FRESH ArrayMesh is built every time: mutating the previous mesh in place
## (clear_surfaces + add_surface) does not refresh the MeshInstance3D — the
## render kept showing pre-undo geometry until something else touched the
## node. Reassigning a new mesh resource forces the re-upload.
func rebuild() -> void:
	if pb_mesh_data == null:
		mesh = null
		_needs_rebuild = false
		_update_collider()
		return
	mesh = pb_mesh_data.to_array_mesh()
	_needs_rebuild = false
	_update_collider()
## Fast-path rebuild for position-only edits (active element dragging).
## Reuses precompiled submesh index buffers since topology and material
## assignments do not change during vertex movement.
func rebuild_positions() -> void:
	if pb_mesh_data == null:
		mesh = null
		_needs_rebuild = false
		return
	mesh = pb_mesh_data.to_array_mesh(null, true)
	_needs_rebuild = false

# ==============================================================================
# Convenience Factory Methods
# ==============================================================================

## Creates a PBMesh node with a unit cube PBMeshData.
static func create_cube(size: float = 1.0) -> PBMesh:
	var node := PBMesh.new()
	node.pb_mesh_data = PBMeshData.create_cube(size)
	return node

# ==============================================================================
# Data Access Convenience
# ==============================================================================

## Returns vertex count of the underlying PBMeshData, or 0 if null.
func vertex_count() -> int:
	return pb_mesh_data.vertex_count() if pb_mesh_data != null else 0

## Returns face count of the underlying PBMeshData, or 0 if null.
func face_count() -> int:
	return pb_mesh_data.face_count() if pb_mesh_data != null else 0

## Returns triangle count of the underlying PBMeshData, or 0 if null.
func triangle_count() -> int:
	return pb_mesh_data.triangle_count() if pb_mesh_data != null else 0

## Returns index count of the underlying PBMeshData, or 0 if null.
func index_count() -> int:
	return pb_mesh_data.index_count() if pb_mesh_data != null else 0

## Returns edge count of the underlying PBMeshData, or 0 if null.
func edge_count() -> int:
	return pb_mesh_data.edge_count() if pb_mesh_data != null else 0

# ==============================================================================
# Physics Collider Generation
# ==============================================================================

## Returns the active StaticBody3D child, or null if collision is off.
func get_collider_body() -> StaticBody3D:
	return get_node_or_null(NodePath(COLLIDER_BODY_NAME)) as StaticBody3D

## Updates the child StaticBody3D and CollisionShape3D according to collider_type.
func _update_collider() -> void:
	if not is_inside_tree():
		return

	# If collision is OFF, or no mesh exists, clean up any existing body
	if collider_type == ColliderType.OFF or pb_mesh_data == null or mesh == null or mesh.get_surface_count() == 0:
		_cleanup_collider()
		return

	var body := _get_or_create_body()
	var col_shape := _get_or_create_collision_shape(body)

	var shape: Shape3D = null
	match collider_type:
		ColliderType.ACCURATE:
			shape = mesh.create_trimesh_shape()
		ColliderType.RAMP:
			if is_stairs():
				shape = _build_stairs_ramp_shape()
			else:
				shape = mesh.create_trimesh_shape()
		_:
			shape = mesh.create_trimesh_shape()

	col_shape.shape = shape

func _get_or_create_body() -> StaticBody3D:
	var body := get_node_or_null(NodePath(COLLIDER_BODY_NAME)) as StaticBody3D
	if body == null:
		body = StaticBody3D.new()
		body.name = COLLIDER_BODY_NAME
		add_child(body)
		body.owner = null
	return body

func _get_or_create_collision_shape(body: StaticBody3D) -> CollisionShape3D:
	var col_shape := body.get_node_or_null(NodePath(COLLIDER_SHAPE_NAME)) as CollisionShape3D
	if col_shape == null:
		col_shape = CollisionShape3D.new()
		col_shape.name = COLLIDER_SHAPE_NAME
		body.add_child(col_shape)
		col_shape.owner = null
	return col_shape
func _cleanup_collider() -> void:
	var body := get_node_or_null(NodePath(COLLIDER_BODY_NAME))
	if body != null:
		remove_child(body)
		body.queue_free()

func _has_valid_collider() -> bool:
	var body := get_node_or_null(NodePath(COLLIDER_BODY_NAME)) as StaticBody3D
	if body == null:
		return false
	var col_shape := body.get_node_or_null(NodePath(COLLIDER_SHAPE_NAME)) as CollisionShape3D
	return col_shape != null and col_shape.shape != null

func _build_stairs_ramp_shape() -> Shape3D:
	if pb_mesh_data == null or mesh == null or mesh.get_surface_count() == 0:
		return null

	if pb_mesh_data.shape_id == &"curved_stair":
		return _build_curved_stairs_ramp_shape()
	else:
		return _build_straight_stairs_ramp_shape()

func _build_straight_stairs_ramp_shape() -> Shape3D:
	var aabb: AABB = mesh.get_aabb()
	var x0: float = aabb.position.x
	var x1: float = aabb.end.x
	var y0: float = aabb.position.y
	var y1: float = aabb.end.y
	var z0: float = aabb.position.z
	var z1: float = aabb.end.z

	var num_steps: int = 6
	if pb_mesh_data != null and pb_mesh_data.shape_params.has("steps"):
		num_steps = maxi(1, int(pb_mesh_data.shape_params["steps"]))

	var step_h: float = (y1 - y0) / float(num_steps)

	# Straight triangular prism flush with the ground (no initial step):
	# Base rectangle at ground y0 from z0 to z1.
	# Top slopes from (x, y0, z0) at the ground straight up to (x, y1, z1).
	# Back is vertical from y0 to y1 at z1.
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		Vector3(x0, y0, z0),
		Vector3(x1, y0, z0),
		Vector3(x1, y0, z1),
		Vector3(x0, y0, z1),
		Vector3(x0, y1, z1),
		Vector3(x1, y1, z1),
	])
	return shape

func _build_curved_stairs_ramp_shape() -> Shape3D:
	var params: Dictionary = pb_mesh_data.shape_params if pb_mesh_data != null else {}
	var stair_w: float = float(params.get("stair_width", 1.5))
	var h: float = float(params.get("height", 2.0))
	var r_in: float = maxf(0.0, float(params.get("inner_radius", 0.5)))
	var r_out: float = r_in + maxf(0.05, stair_w)
	var cur_deg: float = float(params.get("curvature", 180.0))
	var steps: int = maxi(1, int(params.get("steps", 8)))
	var hh: float = h * 0.5
	var is_pie: bool = r_in <= 0.0001
	var is_flipped: bool = cur_deg < 0.0
	var cir: float = deg_to_rad(absf(cur_deg))
	if cir <= 0.0001:
		cir = deg_to_rad(180.0)

	var step_h: float = h / float(steps)

	var faces := PackedVector3Array()

	var add_quad := func(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
		faces.append(p0)
		faces.append(p1)
		faces.append(p2)
		faces.append(p2)
		faces.append(p3)
		faces.append(p0)

	var add_tri := func(p0: Vector3, p1: Vector3, p2: Vector3) -> void:
		faces.append(p0)
		faces.append(p1)
		faces.append(p2)

	for s in range(steps):
		var inc0: float = (float(s) / float(steps)) * cir
		var inc1: float = (float(s + 1) / float(steps)) * cir

		var v0 := Vector3(-cos(inc0), 0.0, sin(inc0))
		var v1 := Vector3(-cos(inc1), 0.0, sin(inc1))

		# Smooth ramp height from ground (-hh) at start to top (+hh)
		var y0: float = -hh + (float(s) / float(steps)) * h
		var y1: float = -hh + (float(s + 1) / float(steps)) * h
		# Top ramp surface
		if is_pie:
			var t_center := Vector3(0.0, y1, 0.0)
			var t_out0 := Vector3(v0.x * r_out, y0, v0.z * r_out)
			var t_out1 := Vector3(v1.x * r_out, y1, v1.z * r_out)
			add_tri.call(t_center, t_out1, t_out0)
		else:
			var t0 := Vector3(v0.x * r_in,  y0, v0.z * r_in)
			var t1 := Vector3(v1.x * r_in,  y1, v1.z * r_in)
			var t2 := Vector3(v1.x * r_out, y1, v1.z * r_out)
			var t3 := Vector3(v0.x * r_out, y0, v0.z * r_out)
			add_quad.call(t0, t1, t2, t3)

		# Outer wall
		var ow_b0 := Vector3(v0.x * r_out, -hh, v0.z * r_out)
		var ow_b1 := Vector3(v1.x * r_out, -hh, v1.z * r_out)
		var ow_t1 := Vector3(v1.x * r_out,  y1, v1.z * r_out)
		var ow_t0 := Vector3(v0.x * r_out,  y0, v0.z * r_out)
		add_quad.call(ow_b0, ow_b1, ow_t1, ow_t0)

		# Inner wall
		if not is_pie:
			var iw_b0 := Vector3(v0.x * r_in, -hh, v0.z * r_in)
			var iw_b1 := Vector3(v1.x * r_in, -hh, v1.z * r_in)
			var iw_t1 := Vector3(v1.x * r_in,  y1, v1.z * r_in)
			var iw_t0 := Vector3(v0.x * r_in,  y0, v0.z * r_in)
			add_quad.call(iw_b1, iw_b0, iw_t0, iw_t1)

		# Floor
		var f_out0 := Vector3(v0.x * r_out, -hh, v0.z * r_out)
		var f_out1 := Vector3(v1.x * r_out, -hh, v1.z * r_out)
		if is_pie:
			add_tri.call(Vector3(0.0, -hh, 0.0), f_out0, f_out1)
		else:
			var f_in0 := Vector3(v0.x * r_in, -hh, v0.z * r_in)
			var f_in1 := Vector3(v1.x * r_in, -hh, v1.z * r_in)
			add_quad.call(f_in0, f_out0, f_out1, f_in1)

	# Front edge at s=0 is flush with the ground at y=-hh (no initial step)
	# Back vertical wall at s=steps
	var v_end := Vector3(-cos(cir), 0.0, sin(cir))
	if is_pie:
		add_tri.call(Vector3(0.0, -hh, 0.0), Vector3(v_end.x * r_out, hh, v_end.z * r_out), Vector3(v_end.x * r_out, -hh, v_end.z * r_out))
	else:
		add_quad.call(
			Vector3(v_end.x * r_out, -hh, v_end.z * r_out),
			Vector3(v_end.x * r_in,  -hh, v_end.z * r_in),
			Vector3(v_end.x * r_in,   hh, v_end.z * r_in),
			Vector3(v_end.x * r_out,  hh, v_end.z * r_out)
		)

	# Negative curvature
	if is_flipped:
		for i in range(faces.size()):
			faces[i].x = -faces[i].x
		for i in range(0, faces.size(), 3):
			var tmp := faces[i + 1]
			faces[i + 1] = faces[i + 2]
			faces[i + 2] = tmp

	# Center around origin in X and Z
	if faces.size() > 0:
		var min_x: float = faces[0].x
		var max_x: float = faces[0].x
		var min_z: float = faces[0].z
		var max_z: float = faces[0].z
		for p in faces:
			min_x = minf(min_x, p.x)
			max_x = maxf(max_x, p.x)
			min_z = minf(min_z, p.z)
			max_z = maxf(max_z, p.z)
		var offset := Vector3((min_x + max_x) * 0.5, 0.0, (min_z + max_z) * 0.5)
		for i in range(faces.size()):
			faces[i] -= offset

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape
