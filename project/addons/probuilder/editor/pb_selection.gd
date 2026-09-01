## PBSelection — Manages element selection state for a PBMesh.
##
## Stores selected vertices (by shared vertex group index), edges (as PBEdge),
## and faces (by face array index). Provides add/remove/toggle/clear operations
## and signals for selection change notification.
##
## Selection uses "common" (shared vertex group) indices for vertices to ensure
## all coincident vertices are selected together, matching ProBuilder behavior.
@tool
class_name PBSelection
extends RefCounted

# ==============================================================================
# Signals
# ==============================================================================

## Emitted whenever the selection changes (any mode).
signal selection_changed()

# ==============================================================================
# Selection State
# ==============================================================================

## Selected vertex shared-group indices (common indices).
var selected_vertices: PackedInt32Array = PackedInt32Array()

## Selected edges (local vertex indices, deduplicated by common edge).
var selected_edges: Array[PBEdge] = []

## Selected face indices (indices into PBMeshData.faces array).
var selected_faces: PackedInt32Array = PackedInt32Array()

## The mesh this selection applies to.
var mesh_data: PBMeshData = null

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init(p_mesh_data: PBMeshData = null) -> void:
	mesh_data = p_mesh_data

## Binds this selection to a new PBMeshData, clearing all selections.
func set_mesh_data(p_mesh_data: PBMeshData) -> void:
	mesh_data = p_mesh_data
	clear_all()

# ==============================================================================
# Vertex Selection (Common/Shared Vertex Indices)
# ==============================================================================

## Returns true if the given common vertex index is selected.
func is_vertex_selected(common_index: int) -> bool:
	return selected_vertices.has(common_index)

## Adds a common vertex index to the selection.
func add_vertex(common_index: int) -> void:
	if not selected_vertices.has(common_index):
		selected_vertices.append(common_index)
		selection_changed.emit()

## Removes a common vertex index from the selection.
func remove_vertex(common_index: int) -> void:
	var idx: int = _index_of_int(selected_vertices, common_index)
	if idx >= 0:
		selected_vertices.remove_at(idx)
		selection_changed.emit()

## Toggles a common vertex index in/out of the selection.
func toggle_vertex(common_index: int) -> void:
	if is_vertex_selected(common_index):
		remove_vertex(common_index)
	else:
		add_vertex(common_index)

## Sets the vertex selection to exactly the given set.
func set_vertices(common_indices: PackedInt32Array) -> void:
	selected_vertices = common_indices.duplicate()
	selection_changed.emit()

## Clears only vertex selection.
func clear_vertices() -> void:
	if selected_vertices.is_empty():
		return
	selected_vertices.clear()
	selection_changed.emit()

## Returns the number of selected vertices.
func selected_vertex_count() -> int:
	return selected_vertices.size()

## Returns all selected local vertex indices (expanding shared groups).
func get_selected_vertex_indices() -> PackedInt32Array:
	if mesh_data == null:
		return PackedInt32Array()
	var result := PackedInt32Array()
	for common_idx in selected_vertices:
		if common_idx >= 0 and common_idx < mesh_data.shared_vertices.size():
			var sv: PBSharedVertex = mesh_data.shared_vertices[common_idx]
			if sv != null:
				result.append_array(sv.indices)
	return result

# ==============================================================================
# Edge Selection
# ==============================================================================

## Returns true if the given edge is selected (compared by common edge).
func is_edge_selected(edge: PBEdge) -> bool:
	if edge == null or mesh_data == null:
		return false
	var common: PBEdge = mesh_data.get_common_edge(edge)
	if common == null:
		return false
	for sel_edge in selected_edges:
		var sel_common: PBEdge = mesh_data.get_common_edge(sel_edge)
		if sel_common != null and sel_common.equals(common):
			return true
	return false

## Adds an edge to the selection (deduplicated by common edge).
func add_edge(edge: PBEdge) -> void:
	if edge == null:
		return
	if not is_edge_selected(edge):
		selected_edges.append(edge)
		selection_changed.emit()

## Removes an edge from the selection (matched by common edge).
func remove_edge(edge: PBEdge) -> void:
	if edge == null or mesh_data == null:
		return
	var common: PBEdge = mesh_data.get_common_edge(edge)
	if common == null:
		return
	for i in range(selected_edges.size() - 1, -1, -1):
		var sel_common: PBEdge = mesh_data.get_common_edge(selected_edges[i])
		if sel_common != null and sel_common.equals(common):
			selected_edges.remove_at(i)
			selection_changed.emit()
			return

## Toggles an edge in/out of the selection.
func toggle_edge(edge: PBEdge) -> void:
	if is_edge_selected(edge):
		remove_edge(edge)
	else:
		add_edge(edge)

## Sets the edge selection to exactly the given set.
func set_edges(edges: Array[PBEdge]) -> void:
	selected_edges = edges.duplicate()
	selection_changed.emit()

## Clears only edge selection.
func clear_edges() -> void:
	if selected_edges.is_empty():
		return
	selected_edges.clear()
	selection_changed.emit()

## Returns the number of selected edges.
func selected_edge_count() -> int:
	return selected_edges.size()

# ==============================================================================
# Face Selection
# ==============================================================================

## Returns true if the given face index is selected.
func is_face_selected(face_index: int) -> bool:
	return selected_faces.has(face_index)

## Adds a face index to the selection.
func add_face(face_index: int) -> void:
	if not selected_faces.has(face_index):
		selected_faces.append(face_index)
		selection_changed.emit()

## Removes a face index from the selection.
func remove_face(face_index: int) -> void:
	var idx: int = _index_of_int(selected_faces, face_index)
	if idx >= 0:
		selected_faces.remove_at(idx)
		selection_changed.emit()

## Toggles a face index in/out of the selection.
func toggle_face(face_index: int) -> void:
	if is_face_selected(face_index):
		remove_face(face_index)
	else:
		add_face(face_index)

## Sets the face selection to exactly the given set.
func set_faces(face_indices: PackedInt32Array) -> void:
	selected_faces = face_indices.duplicate()
	selection_changed.emit()

## Clears only face selection.
func clear_faces() -> void:
	if selected_faces.is_empty():
		return
	selected_faces.clear()
	selection_changed.emit()

## Returns the number of selected faces.
func selected_face_count() -> int:
	return selected_faces.size()

# ==============================================================================
# Bulk Operations
# ==============================================================================

## Clears all selections (vertices, edges, faces).
func clear_all() -> void:
	var had_selection: bool = not selected_vertices.is_empty() or not selected_edges.is_empty() or not selected_faces.is_empty()
	selected_vertices.clear()
	selected_edges.clear()
	selected_faces.clear()
	if had_selection:
		selection_changed.emit()

## Returns total count of selected elements across all modes.
func total_selected() -> int:
	return selected_vertices.size() + selected_edges.size() + selected_faces.size()

## Returns true if nothing is selected in any mode.
func is_empty() -> bool:
	return selected_vertices.is_empty() and selected_edges.is_empty() and selected_faces.is_empty()

# ==============================================================================
# Select All / Invert / Grow / Shrink
# ==============================================================================

## Selects all elements of the given mode.
func select_all(mode: PBEditor.SelectMode) -> void:
	if mesh_data == null:
		return
	match mode:
		PBEditor.SelectMode.VERTEX:
			var all := PackedInt32Array()
			for i in range(mesh_data.shared_vertices.size()):
				all.append(i)
			set_vertices(all)
		PBEditor.SelectMode.EDGE:
			var all_edges: Array[PBEdge] = []
			var seen: Dictionary = {}
			var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
			for face in mesh_data.faces:
				if face == null:
					continue
				for edge in face.get_edges():
					var ca: int = lookup.get(edge.a, -1)
					var cb: int = lookup.get(edge.b, -1)
					var key := Vector2i(mini(ca, cb), maxi(ca, cb))
					if not seen.has(key):
						seen[key] = true
						all_edges.append(edge)
			set_edges(all_edges)
		PBEditor.SelectMode.FACE:
			var all := PackedInt32Array()
			for i in range(mesh_data.faces.size()):
				all.append(i)
			set_faces(all)

## Inverts the selection for the given mode.
func invert_selection(mode: PBEditor.SelectMode) -> void:
	if mesh_data == null:
		return
	match mode:
		PBEditor.SelectMode.VERTEX:
			var inverted := PackedInt32Array()
			for i in range(mesh_data.shared_vertices.size()):
				if not selected_vertices.has(i):
					inverted.append(i)
			set_vertices(inverted)
		PBEditor.SelectMode.EDGE:
			var all_edges: Array[PBEdge] = []
			var seen: Dictionary = {}
			var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
			for face in mesh_data.faces:
				if face == null:
					continue
				for edge in face.get_edges():
					var ca: int = lookup.get(edge.a, -1)
					var cb: int = lookup.get(edge.b, -1)
					var key := Vector2i(mini(ca, cb), maxi(ca, cb))
					if not seen.has(key):
						seen[key] = true
						if not is_edge_selected(edge):
							all_edges.append(edge)
			set_edges(all_edges)
		PBEditor.SelectMode.FACE:
			var inverted := PackedInt32Array()
			for i in range(mesh_data.faces.size()):
				if not selected_faces.has(i):
					inverted.append(i)
			set_faces(inverted)

## Grows the selection by one ring of adjacent elements.
func grow_selection(mode: PBEditor.SelectMode) -> void:
	if mesh_data == null:
		return
	match mode:
		PBEditor.SelectMode.VERTEX:
			_grow_vertex_selection()
		PBEditor.SelectMode.EDGE:
			_grow_edge_selection()
		PBEditor.SelectMode.FACE:
			_grow_face_selection()

## Shrinks the selection by removing boundary elements.
func shrink_selection(mode: PBEditor.SelectMode) -> void:
	if mesh_data == null:
		return
	match mode:
		PBEditor.SelectMode.VERTEX:
			_shrink_vertex_selection()
		PBEditor.SelectMode.EDGE:
			_shrink_edge_selection()
		PBEditor.SelectMode.FACE:
			_shrink_face_selection()

# ==============================================================================
# Grow/Shrink Implementation
# ==============================================================================

func _grow_vertex_selection() -> void:
	# Find all faces containing any selected vertex, then add all their vertices
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var selected_set: Dictionary = {}
	for sv in selected_vertices:
		selected_set[sv] = true

	var new_verts: PackedInt32Array = selected_vertices.duplicate()
	for face in mesh_data.faces:
		if face == null:
			continue
		var face_has_selected: bool = false
		for idx in face.get_distinct_indexes():
			var common: int = lookup.get(idx, -1)
			if selected_set.has(common):
				face_has_selected = true
				break
		if face_has_selected:
			for idx in face.get_distinct_indexes():
				var common: int = lookup.get(idx, -1)
				if common >= 0 and not selected_set.has(common):
					new_verts.append(common)
					selected_set[common] = true
	set_vertices(new_verts)

func _shrink_vertex_selection() -> void:
	# Remove vertices that are adjacent to any unselected vertex
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var selected_set: Dictionary = {}
	for sv in selected_vertices:
		selected_set[sv] = true

	var boundary: Dictionary = {}
	for face in mesh_data.faces:
		if face == null:
			continue
		var distinct := face.get_distinct_indexes()
		var face_commons: PackedInt32Array = PackedInt32Array()
		for idx in distinct:
			face_commons.append(lookup.get(idx, -1))
		var has_selected: bool = false
		var has_unselected: bool = false
		for c in face_commons:
			if selected_set.has(c):
				has_selected = true
			else:
				has_unselected = true
		if has_selected and has_unselected:
			for c in face_commons:
				if selected_set.has(c):
					boundary[c] = true

	var shrunk := PackedInt32Array()
	for sv in selected_vertices:
		if not boundary.has(sv):
			shrunk.append(sv)
	set_vertices(shrunk)

func _grow_edge_selection() -> void:
	# Add edges adjacent to any selected edge endpoint
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var selected_commons: Dictionary = {}
	for edge in selected_edges:
		var ca: int = lookup.get(edge.a, -1)
		var cb: int = lookup.get(edge.b, -1)
		selected_commons[ca] = true
		selected_commons[cb] = true

	var seen_edge_keys: Dictionary = {}
	for edge in selected_edges:
		var ca: int = lookup.get(edge.a, -1)
		var cb: int = lookup.get(edge.b, -1)
		seen_edge_keys[Vector2i(mini(ca, cb), maxi(ca, cb))] = true

	var new_edges: Array[PBEdge] = selected_edges.duplicate()
	for face in mesh_data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if seen_edge_keys.has(key):
				continue
			if selected_commons.has(ca) or selected_commons.has(cb):
				seen_edge_keys[key] = true
				new_edges.append(edge)
	set_edges(new_edges)

func _shrink_edge_selection() -> void:
	# Remove edges where at least one endpoint connects to an unselected edge
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var selected_edge_keys: Dictionary = {}
	for edge in selected_edges:
		var ca: int = lookup.get(edge.a, -1)
		var cb: int = lookup.get(edge.b, -1)
		selected_edge_keys[Vector2i(mini(ca, cb), maxi(ca, cb))] = true

	# Find all edges, check which selected edge endpoints touch unselected edges
	var boundary_verts: Dictionary = {}
	for face in mesh_data.faces:
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if not selected_edge_keys.has(key):
				# Unselected edge — its endpoints are boundaries
				boundary_verts[ca] = true
				boundary_verts[cb] = true

	var shrunk: Array[PBEdge] = []
	for edge in selected_edges:
		var ca: int = lookup.get(edge.a, -1)
		var cb: int = lookup.get(edge.b, -1)
		if not boundary_verts.has(ca) and not boundary_verts.has(cb):
			shrunk.append(edge)
	set_edges(shrunk)

func _grow_face_selection() -> void:
	# Add faces that share an edge with any selected face
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var selected_set: Dictionary = {}
	for fi in selected_faces:
		selected_set[fi] = true

	# Collect all common edges of selected faces
	var selected_edge_keys: Dictionary = {}
	for fi in selected_faces:
		if fi < 0 or fi >= mesh_data.faces.size():
			continue
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			selected_edge_keys[Vector2i(mini(ca, cb), maxi(ca, cb))] = true

	var new_faces := selected_faces.duplicate()
	for fi in range(mesh_data.faces.size()):
		if selected_set.has(fi):
			continue
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var adjacent: bool = false
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			if selected_edge_keys.has(Vector2i(mini(ca, cb), maxi(ca, cb))):
				adjacent = true
				break
		if adjacent:
			new_faces.append(fi)
			selected_set[fi] = true
	set_faces(new_faces)

func _shrink_face_selection() -> void:
	# Remove faces that border an unselected face
	var lookup: Dictionary = mesh_data.get_shared_vertex_lookup()
	var selected_set: Dictionary = {}
	for fi in selected_faces:
		selected_set[fi] = true

	# Build edge-to-face map
	var edge_faces: Dictionary = {} # Vector2i -> Array[int]
	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if not edge_faces.has(key):
				edge_faces[key] = []
			edge_faces[key].append(fi)

	# A selected face is on the boundary if any of its edges is shared with an unselected face
	var boundary_faces: Dictionary = {}
	for fi in selected_faces:
		if fi < 0 or fi >= mesh_data.faces.size():
			continue
		var face: PBFace = mesh_data.faces[fi]
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if edge_faces.has(key):
				for neighbor_fi in edge_faces[key]:
					if neighbor_fi != fi and not selected_set.has(neighbor_fi):
						boundary_faces[fi] = true
						break
			# Also boundary if the edge has only one face (mesh boundary)
			if edge_faces.has(key) and edge_faces[key].size() < 2:
				boundary_faces[fi] = true

	var shrunk := PackedInt32Array()
	for fi in selected_faces:
		if not boundary_faces.has(fi):
			shrunk.append(fi)
	set_faces(shrunk)

# ==============================================================================
# Helpers
# ==============================================================================

static func _index_of_int(arr: PackedInt32Array, value: int) -> int:
	for i in range(arr.size()):
		if arr[i] == value:
			return i
	return -1
