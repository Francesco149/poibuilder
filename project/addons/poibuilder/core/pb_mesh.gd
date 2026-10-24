## PBMesh — MeshInstance3D wrapper node that holds a PBMeshData resource and compiles it to ArrayMesh.
##
## This is the primary scene-tree node in PoiBuilder. It holds the editable geometry
## data in a PBMeshData resource and synchronizes it with its own MeshInstance3D.mesh (an ArrayMesh).
@tool
class_name PBMesh
extends MeshInstance3D

## Emitted when the mesh geometry has been compiled to an ArrayMesh.
signal mesh_rebuilt

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

func _enter_tree() -> void:
	if Engine.is_editor_hint():
		claim_mesh_data()

func _ready() -> void:
	if pb_mesh_data != null:
		rebuild()
		_migrate_legacy_stamps()
	else:
		_update_collider()

## One PBMeshData per node in the edited scene. The editor's Duplicate (Ctrl+D)
## and copy-paste go through Node.duplicate(), which SHARES Resource-valued
## properties, and every PoiBuilder edit mutates the data in place: the copy's
## re-texture or extrude rewrote the original's faces and materials without
## rebuilding it (it stopped scrolling, kept a stale look, and both exported
## from the one data). A node entering the tree while another in-tree node
## holds its data takes a deep copy. Nodes inside an instanced sub-scene share
## their scene's data by design and keep it (instance roots too). Editor-only
## (from _enter_tree); a game spawning copies at runtime never edits them.
##
## A paste into ANOTHER scene arrives differently: the dock's resource remap
## gives it a NEW data object, but a shallow one (Resource.duplicate) whose
## faces, shared vertices and materials arrays are still the source scene's,
## so editing the paste edited the other scene. faces[0] carries the id of the
## data that claimed it; a data whose first face another live data still holds
## is a shallow copy and takes a deep one too. The deep copy also duplicates
## every material built into a DIFFERENT scene file, so not even an inspector
## edit reaches the source scene.
## Returns true when it privatised.
func claim_mesh_data() -> bool:
	if pb_mesh_data == null:
		return false
	var privatised := false
	if not _is_instanced_content() and (_data_held_by_another_node() or _faces_held_by_another_data()):
		pb_mesh_data = _private_copy(pb_mesh_data)
		privatised = true
	pb_mesh_data.claimed_by = get_instance_id()
	if not pb_mesh_data.faces.is_empty() and pb_mesh_data.faces[0] != null:
		pb_mesh_data.faces[0].claimed_by_data = pb_mesh_data.get_instance_id()
	return privatised

func _data_held_by_another_node() -> bool:
	if pb_mesh_data.claimed_by == 0:
		return false
	var holder := instance_from_id(pb_mesh_data.claimed_by) as PBMesh
	return holder != null and holder != self and holder.pb_mesh_data == pb_mesh_data and holder.is_inside_tree()

func _faces_held_by_another_data() -> bool:
	if pb_mesh_data.faces.is_empty() or pb_mesh_data.faces[0] == null:
		return false
	var face: PBFace = pb_mesh_data.faces[0]
	if face.claimed_by_data == 0 or face.claimed_by_data == pb_mesh_data.get_instance_id():
		return false
	var other := instance_from_id(face.claimed_by_data) as PBMeshData
	return other != null and other.faces.has(face)

## Deep copy for this node: geometry, faces and paint (copy_mesh_data_live),
## plus a local copy of each material built into another scene file (one per
## distinct material, so faces that shared one keep sharing it). Materials of
## this scene, saved .tres files and never-saved ones stay shared.
func _private_copy(data: PBMeshData) -> PBMeshData:
	var copy := PBCommand.copy_mesh_data_live(data)
	var tree := get_tree()
	var own_scene := tree.edited_scene_root.scene_file_path if tree != null and tree.edited_scene_root != null else ""
	var localised: Dictionary = {}
	for i in range(copy.materials.size()):
		var m := copy.materials[i]
		if m == null or not _is_built_into_other_scene(m, own_scene):
			continue
		if not localised.has(m):
			localised[m] = m.duplicate(true)
		copy.materials[i] = localised[m]
	return copy

static func _is_built_into_other_scene(res: Resource, own_scene: String) -> bool:
	var sep := res.resource_path.find("::")
	return sep >= 0 and res.resource_path.substr(0, sep) != own_scene

## True for a node that belongs to an instanced sub-scene of the edited scene
## (owned by an instance root, or an instance root itself).
func _is_instanced_content() -> bool:
	if not scene_file_path.is_empty():
		return true
	var tree := get_tree()
	return owner != null and tree != null and owner != tree.edited_scene_root

## (No _process: the camera-scaled gizmo refresh that used to run here — a
## script call per PBMesh per frame, in the editor AND in shipped games — is
## the plugin's job now, for the few nodes that draw scaled overlays; see
## poibuilder_plugin.gd::_refresh_camera_scaled_gizmos.)

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
		_sync_overflow_chunks([])
		_needs_rebuild = false
		_update_collider()
		return
	var chunks := pb_mesh_data.to_array_meshes()
	mesh = chunks[0]
	_sync_overflow_chunks(chunks)
	_needs_rebuild = false
	_update_collider()
	mesh_rebuilt.emit()
## Fast-path rebuild for position-only edits (active element dragging).
## Reuses precompiled submesh index buffers since topology and material
## assignments do not change during vertex movement.
func rebuild_positions() -> void:
	if pb_mesh_data == null:
		mesh = null
		_needs_rebuild = false
		return
	var chunks := pb_mesh_data.to_array_meshes(true)
	mesh = chunks[0]
	_sync_overflow_chunks(chunks)
	_needs_rebuild = false
	mesh_rebuilt.emit()

# ==============================================================================
# Overflow chunks (meshes past the engine's 256-surface limit)
# ==============================================================================

## Name prefix of the internal chunk children (never saved: no owner).
const OVERFLOW_CHUNK_PREFIX := "_PBSurfaceChunk"

## The surfaces past PBMeshData.MAX_SURFACES_PER_MESH, drawn by internal
## MeshInstance3D children: an ArrayMesh refuses its 257th surface (only a
## logged error), and every face on it used to vanish. The children are
## internal and unowned — not in get_children(), never saved, no editor
## gizmo — and inherit transform and visibility; the rendering properties
## below are mirrored on every rebuild.
var _overflow_chunks: Array[MeshInstance3D] = []

## Every mesh this node renders: `mesh` plus the overflow chunks. Consumers
## that read the RENDERED geometry (colliders from render meshes, audits)
## must walk all of them.
func get_render_meshes() -> Array[Mesh]:
	var out: Array[Mesh] = []
	if mesh != null:
		out.append(mesh)
	for chunk in _overflow_chunks:
		if is_instance_valid(chunk) and chunk.mesh != null:
			out.append(chunk.mesh)
	return out

## The local AABB of EVERYTHING this node renders. `get_aabb()` is only the
## first chunk's box, so a ray prefilter against it could skip faces that
## live in an overflow chunk.
func get_full_aabb() -> AABB:
	var box := get_aabb()
	for chunk in _overflow_chunks:
		if is_instance_valid(chunk) and chunk.mesh != null:
			box = box.merge(chunk.mesh.get_aabb())
	return box

func _sync_overflow_chunks(chunks: Array) -> void:
	var needed: int = maxi(chunks.size() - 1, 0)
	if needed == 0 and _overflow_chunks.is_empty():
		return
	while _overflow_chunks.size() > needed:
		var gone: MeshInstance3D = _overflow_chunks.pop_back()
		if is_instance_valid(gone):
			remove_child(gone)
			gone.queue_free()
	while _overflow_chunks.size() < needed:
		var chunk := MeshInstance3D.new()
		chunk.name = "%s%d" % [OVERFLOW_CHUNK_PREFIX, _overflow_chunks.size() + 1]
		add_child(chunk, false, Node.INTERNAL_MODE_BACK)
		_overflow_chunks.append(chunk)
	for i in range(needed):
		var chunk := _overflow_chunks[i]
		chunk.mesh = chunks[i + 1]
		chunk.layers = layers
		chunk.cast_shadow = cast_shadow
		chunk.gi_mode = gi_mode
		chunk.gi_lightmap_scale = gi_lightmap_scale
		chunk.material_override = material_override
		chunk.material_overlay = material_overlay
		chunk.transparency = transparency
		chunk.extra_cull_margin = extra_cull_margin
		chunk.lod_bias = lod_bias
		chunk.ignore_occlusion_culling = ignore_occlusion_culling
		chunk.visibility_range_begin = visibility_range_begin
		chunk.visibility_range_end = visibility_range_end
		chunk.visibility_range_begin_margin = visibility_range_begin_margin
		chunk.visibility_range_end_margin = visibility_range_end_margin
		chunk.visibility_range_fade_mode = visibility_range_fade_mode

const STAMP_CONTAINER_NAME := "PBStamps"

## One-time migration for scenes saved with the OLD stamp design: decal stamps
## used to be MeshInstance3D quads under a `PBStamps` child, positioned by node
## metadata. Those nodes were ordinary scene nodes — visible, selectable, and
## desynced from the mesh the moment anyone moved one. Decals are painted into
## the surface now, so every recorded record is re-pasted into the decal layer
## and the container is dropped. Editor-only; a plain runtime leaves the scene
## exactly as saved.
func _migrate_legacy_stamps() -> void:
	if not Engine.is_editor_hint() or pb_mesh_data == null:
		return
	if has_meta("pb_legacy_stamps_migrated") or get_node_or_null(STAMP_CONTAINER_NAME) == null:
		return
	set_meta("pb_legacy_stamps_migrated", true)
	var migrated := PBSplat.migrate_legacy_stamps(self)
	if migrated > 0:
		var logger := PBLogger.new()
		logger.info("render", "Migrated %d legacy decal node(s) on %s into the decal layer" % [migrated, name])
		rebuild()
		update_gizmos()

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
		ColliderType.RAMP:
			if is_stairs():
				shape = _build_stairs_ramp_shape()
			else:
				shape = _build_trimesh_shape()
		_:
			shape = _build_trimesh_shape()

	col_shape.shape = shape

## The geometry-accurate collider, from the DATA's triangles: `mesh` is only
## the first render chunk of a mesh past 256 surfaces, and its
## create_trimesh_shape() left every overflow face without collision. Same
## triangles and winding as the render; no surface read-back.
func _build_trimesh_shape() -> Shape3D:
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(pb_mesh_data.get_triangle_soup())
	return shape

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
		float(params.get("sides", 1.0)) > 0.5,
		float(params.get("axis_swap", 0.0)) > 0.5)
	if faces.is_empty():
		return mesh.create_trimesh_shape()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape
