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
## When true, draws the collision shape debug wireframe directly in the 3D viewport.
@export var show_collider: bool = false:
	set = set_show_collider

func set_show_collider(value: bool) -> void:
	if show_collider == value:
		return
	show_collider = value
	update_gizmos()

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
	if pb_mesh_data == null:
		return null
	# The ramp is a DESIGN-TIME simplification of the pristine primitive. Once
	# the stairs have been edited (or params never existed), the params no
	# longer describe the geometry — regenerate nothing and fall back to a
	# geometry-accurate trimesh of the CURRENT mesh instead of emitting a
	# collider that silently disagrees with what the user sees.
	if pb_mesh_data.shape_edited or pb_mesh_data.shape_params.is_empty():
		return mesh.create_trimesh_shape()

	var params: Dictionary = pb_mesh_data.shape_params
	var faces := PBShapeComplex.create_curved_stairs_ramp(
		float(params.get("stair_width", 1.5)),
		float(params.get("height", 2.0)),
		maxf(0.0, float(params.get("inner_radius", 0.5))),
		float(params.get("curvature", 180.0)),
		maxi(1, int(params.get("steps", 8))),
		float(params.get("sides", 1.0)) > 0.5)
	if faces.is_empty():
		return mesh.create_trimesh_shape()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape
