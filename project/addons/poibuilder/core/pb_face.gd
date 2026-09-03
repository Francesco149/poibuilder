## PBFace — Data structure representing a polygon face composed of triangles.
##
## A face is defined by a set of triangle indices pointing into a mesh-wide vertex array.
## Faces also carry material assignments (submesh index), smoothing groups, and Auto-UV settings.
@tool
class_name PBFace
extends Resource

# ==============================================================================
# Serialized Properties
# ==============================================================================

## Triangle indices (length must be a multiple of 3). Points into mesh-wide vertex arrays.
@export var indexes: PackedInt32Array = PackedInt32Array():
	get = get_indexes,
	set = set_indexes

## Smoothing group ID (0 = none / hard edges, >0 = shared normals with faces in the same group).
@export var smoothing_group: int = 0

## Submesh / material slot index this face belongs to.
@export var submesh_index: int = 0

## Whether UVs are manually authored (true) or auto-projected (false).
@export var manual_uv: bool = false

## Texture group for auto UV continuous tiling (-1 = none).
@export var texture_group: int = -1

## UV element group for UV editor grouping.
@export var element_group: int = 0

# Auto-UV Settings
## UV translation offset.
@export var uv_offset: Vector2 = Vector2.ZERO

## UV rotation angle in degrees.
@export var uv_rotation: float = 0.0

## UV scale factor.
@export var uv_scale: Vector2 = Vector2.ONE

## If true, UVs are projected in world space coordinates.
@export var uv_use_world_space: bool = false

## If true, flips horizontal UV coordinate.
@export var uv_flip_u: bool = false

## If true, flips vertical UV coordinate.
@export var uv_flip_v: bool = false

## If true, swaps U and V coordinates.
@export var uv_swap_uv: bool = false

## UV fill mode: 0 = Fit, 1 = Tile, 2 = Stretch.
@export var uv_fill: int = 1

## UV anchor position: 0-8 = 3x3 grid positions (UpperLeft..LowerRight), 9 = None.
@export var uv_anchor: int = 9

# ==============================================================================
# Backing & Lazy-Cached Fields
# ==============================================================================

var _indexes: PackedInt32Array = PackedInt32Array()
var _distinct_indexes: PackedInt32Array = PackedInt32Array()
var _edges: Array[PBEdge] = []
var _cache_valid: bool = false

# ==============================================================================
# Constructor / Factory Methods
# ==============================================================================

func _init(p_indexes: PackedInt32Array = PackedInt32Array()) -> void:
	if p_indexes.size() % 3 == 0:
		_indexes = p_indexes
	else:
		_indexes = PackedInt32Array()
	invalidate_cache()

## Creates a new PBFace instance with the specified triangle indices.
static func make(p_indexes: PackedInt32Array) -> PBFace:
	return PBFace.new(p_indexes)

## Deep copies all properties and indices from another face into this face.
func copy_from(other: PBFace) -> void:
	if other == null:
		return
	_indexes = other._indexes.duplicate()
	smoothing_group = other.smoothing_group
	submesh_index = other.submesh_index
	manual_uv = other.manual_uv
	texture_group = other.texture_group
	element_group = other.element_group

	uv_offset = other.uv_offset
	uv_rotation = other.uv_rotation
	uv_scale = other.uv_scale
	uv_use_world_space = other.uv_use_world_space
	uv_flip_u = other.uv_flip_u
	uv_flip_v = other.uv_flip_v
	uv_swap_uv = other.uv_swap_uv
	uv_fill = other.uv_fill
	uv_anchor = other.uv_anchor

	invalidate_cache()

## Returns a deep copy of this face.
func duplicate_face() -> PBFace:
	var copy := PBFace.new()
	copy.copy_from(self)
	return copy

# ==============================================================================
# Index & Cache Management
# ==============================================================================

## Sets the triangle indices. Validates that length is a multiple of 3 and invalidates cached data.
func set_indexes(p_indexes: PackedInt32Array) -> void:
	if p_indexes.size() % 3 != 0:
		return
	_indexes = p_indexes
	invalidate_cache()

## Returns the triangle indices array.
func get_indexes() -> PackedInt32Array:
	return _indexes

## Returns deduplicated vertex indices referenced by this face (lazy-cached).
func get_distinct_indexes() -> PackedInt32Array:
	if not _cache_valid:
		_rebuild_cache()
	return _distinct_indexes

## Returns the perimeter boundary edges of this face (lazy-cached).
func get_edges() -> Array[PBEdge]:
	if not _cache_valid:
		_rebuild_cache()
	return _edges

## Clears cached distinct indices and perimeter edges.
func invalidate_cache() -> void:
	_distinct_indexes.clear()
	_edges.clear()
	_cache_valid = false

func _rebuild_cache() -> void:
	_cache_distinct_indexes()
	_cache_edges()
	_cache_valid = true

func _cache_distinct_indexes() -> void:
	_distinct_indexes.clear()
	var seen: Dictionary = {}
	for idx in _indexes:
		if not seen.has(idx):
			seen[idx] = true
			_distinct_indexes.append(idx)

func _cache_edges() -> void:
	_edges.clear()
	if _indexes.is_empty():
		return

	var edge_map: Dictionary = {}
	var dup_keys: Dictionary = {}

	for i in range(0, _indexes.size(), 3):
		var tri_edges: Array[PBEdge] = [
			PBEdge.new(_indexes[i], _indexes[i + 1]),
			PBEdge.new(_indexes[i + 1], _indexes[i + 2]),
			PBEdge.new(_indexes[i + 2], _indexes[i]),
		]

		for edge in tri_edges:
			var key := Vector2i(mini(edge.a, edge.b), maxi(edge.a, edge.b))
			if dup_keys.has(key):
				continue
			elif edge_map.has(key):
				edge_map.erase(key)
				dup_keys[key] = true
			else:
				edge_map[key] = edge

	for edge in edge_map.values():
		_edges.append(edge)

# ==============================================================================
# Geometry Queries
# ==============================================================================

## Tests whether a triangle matches one of the triangles composing this face.
func contains_triangle(a: int, b: int, c: int) -> bool:
	for i in range(0, _indexes.size(), 3):
		if _indexes[i] == a and _indexes[i + 1] == b and _indexes[i + 2] == c:
			return true
	return false

## Returns true if the perimeter has exactly 4 edges.
func is_quad() -> bool:
	var edges: Array[PBEdge] = get_edges()
	return edges.size() == 4

## Converts a two-triangle quad face to an ordered cycle of 4 vertex indices.
## Returns an empty PackedInt32Array if this face is not a quad.
func to_quad() -> PackedInt32Array:
	if not is_quad():
		return PackedInt32Array()

	var edges: Array[PBEdge] = get_edges()
	if edges.size() != 4:
		return PackedInt32Array()

	var quad := PackedInt32Array([edges[0].a, edges[0].b, -1, -1])

	var edge_2_idx: int = -1
	for i in range(1, 4):
		if edges[i].a == quad[1]:
			quad[2] = edges[i].b
			edge_2_idx = i
			break
		elif edges[i].b == quad[1]:
			quad[2] = edges[i].a
			edge_2_idx = i
			break

	for i in range(1, 4):
		if i == edge_2_idx:
			continue
		if edges[i].a == quad[2]:
			quad[3] = edges[i].b
			break
		elif edges[i].b == quad[2]:
			quad[3] = edges[i].a
			break

	if quad[2] == -1 or quad[3] == -1:
		return PackedInt32Array()

	return quad

# ==============================================================================
# Index Manipulation
# ==============================================================================

## Adds an offset to all vertex indices and invalidates cache.
func shift_indexes(offset: int) -> void:
	for i in range(_indexes.size()):
		_indexes[i] += offset
	invalidate_cache()

## Subtracts the minimum index value from all indices, shifting the lowest index to zero.
func shift_indexes_to_zero() -> void:
	if _indexes.is_empty():
		return
	var min_val: int = _indexes[0]
	for i in range(1, _indexes.size()):
		if _indexes[i] < min_val:
			min_val = _indexes[i]
	for i in range(_indexes.size()):
		_indexes[i] -= min_val
	invalidate_cache()

## Reverses the triangle indices array, flipping winding order and normals.
func reverse() -> void:
	_indexes.reverse()
	invalidate_cache()

# ==============================================================================
# Utility & Static Helpers
# ==============================================================================

## Returns string representation formatted as "[a, b, c], [d, e, f], ...".
func _to_string() -> String:
	var tri_strings: PackedStringArray = []
	for i in range(0, _indexes.size(), 3):
		tri_strings.append("[%d, %d, %d]" % [_indexes[i], _indexes[i + 1], _indexes[i + 2]])
	return ", ".join(tri_strings)

## Concatenates all triangle indices across the provided list of faces.
static func get_all_indexes(faces: Array[PBFace]) -> PackedInt32Array:
	var result := PackedInt32Array()
	for face in faces:
		if face != null:
			result.append_array(face.get_indexes())
	return result

## Concatenates distinct indices across the provided list of faces.
static func get_all_distinct_indexes(faces: Array[PBFace]) -> PackedInt32Array:
	var result := PackedInt32Array()
	for face in faces:
		if face != null:
			result.append_array(face.get_distinct_indexes())
	return result
