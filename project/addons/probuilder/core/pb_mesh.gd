## PBMesh — MeshInstance3D wrapper node that holds a PBMeshData resource and compiles it to ArrayMesh.
##
## This is the primary scene-tree node in ProBuilder. It holds the editable geometry
## data in a PBMeshData resource and synchronizes it with its own MeshInstance3D.mesh (an ArrayMesh).
@tool
class_name PBMesh
extends MeshInstance3D

# ==============================================================================
# Serialized / Exported Properties
# ==============================================================================

## The editable mesh data resource.
@export var pb_mesh_data: PBMeshData = null:
	set = set_pb_mesh_data

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

# ==============================================================================
# Property Setters & Rebuild
# ==============================================================================

## Sets the PBMeshData resource. Marks for rebuild and triggers rebuild if inside scene tree.
func set_pb_mesh_data(value: PBMeshData) -> void:
	pb_mesh_data = value
	_needs_rebuild = true
	if is_inside_tree():
		rebuild()

## Compiles pb_mesh_data into an ArrayMesh and assigns it to self.mesh.
func rebuild() -> void:
	if pb_mesh_data == null:
		mesh = null
		_needs_rebuild = false
		return
	var array_mesh: ArrayMesh = pb_mesh_data.to_array_mesh(mesh as ArrayMesh if mesh is ArrayMesh else null)
	mesh = array_mesh
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
