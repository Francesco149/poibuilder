## PBObjectOps — Whole-object manipulation algorithms for PoiBuilder.
##
## Implements:
## - Merge Objects: Combines multiple PBMesh nodes into one, baking relative transforms.
## - Mirror Object: Reflects geometry across local X, Y, or Z Cartesian planes with winding correction.
## - Center Pivot: Moves object pivot to bounding box center, translating vertices in local space.
## - Set Pivot To Selection: Moves object pivot to selection centroid.
## - Freeze Transform: Bakes node transform into vertices and resets transform to identity.
## - Probuilderize: Converts standard MeshInstance3D / ArrayMesh into editable PBMesh.
@tool
class_name PBObjectOps
extends RefCounted

# ==============================================================================
# Merge Objects
# ==============================================================================

## Merges multiple donor PBMesh nodes into target_mesh's PBMeshData.
## Bakes relative transforms and rebuilds weld groups.
static func merge_meshes(target_mesh: PBMesh, donor_meshes: Array[PBMesh]) -> bool:
	if target_mesh == null or target_mesh.pb_mesh_data == null:
		return false
	if donor_meshes.is_empty():
		return false

	var target_data: PBMeshData = target_mesh.pb_mesh_data
	var target_xf: Transform3D = target_mesh.global_transform if target_mesh.is_inside_tree() else target_mesh.transform
	var target_inv_xf: Transform3D = target_xf.affine_inverse()

	var new_positions: PackedVector3Array = target_data.positions.duplicate()
	var new_uvs: PackedVector2Array = target_data.textures0.duplicate()
	var new_colors: PackedColorArray = target_data.colors.duplicate()
	var new_faces: Array[PBFace] = []
	for f in target_data.faces:
		if f != null:
			new_faces.append(f.duplicate_face())

	var has_colors := not target_data.colors.is_empty()

	for donor in donor_meshes:
		if donor == null or donor == target_mesh or donor.pb_mesh_data == null:
			continue
		var donor_data: PBMeshData = donor.pb_mesh_data
		var donor_xf: Transform3D = donor.global_transform if donor.is_inside_tree() else donor.transform
		var rel_xf: Transform3D = target_inv_xf * donor_xf

		var v_offset: int = new_positions.size()
		for pos in donor_data.positions:
			new_positions.append(rel_xf * pos)

		if not donor_data.textures0.is_empty() and donor_data.textures0.size() == donor_data.positions.size():
			for uv in donor_data.textures0:
				new_uvs.append(uv)
		else:
			for i in range(donor_data.positions.size()):
				new_uvs.append(Vector2.ZERO)

		if has_colors or not donor_data.colors.is_empty():
			has_colors = true
			if not donor_data.colors.is_empty():
				for col in donor_data.colors:
					new_colors.append(col)
			else:
				for i in range(donor_data.positions.size()):
					new_colors.append(Color.WHITE)

		for face in donor_data.faces:
			if face == null:
				continue
			var cloned: PBFace = face.duplicate_face()
			var shifted_indices := PackedInt32Array()
			for idx in cloned.get_indexes():
				shifted_indices.append(idx + v_offset)
			cloned.set_indexes(shifted_indices)
			cloned.invalidate_cache()
			new_faces.append(cloned)

	target_data.positions = new_positions
	target_data.textures0 = new_uvs
	if has_colors:
		target_data.colors = new_colors
	target_data.faces = new_faces
	target_data.invalidate_caches()
	target_data.rebuild_welds()
	target_data.calculate_normals()
	target_data.shape_edited = true
	target_mesh.rebuild()
	return true

# ==============================================================================
# Mirror Object
# ==============================================================================

## Mirrors mesh_data geometry across the specified local Cartesian axis.
## Inverts triangle winding to preserve outward-facing surface normals.
static func mirror_mesh_data(mesh_data: PBMeshData, axis: Vector3.Axis, origin: Vector3 = Vector3.ZERO) -> bool:
	if mesh_data == null or mesh_data.positions.is_empty():
		return false

	var positions := mesh_data.positions.duplicate()
	for i in range(positions.size()):
		var p: Vector3 = positions[i]
		p[axis] = origin[axis] - (p[axis] - origin[axis])
		positions[i] = p
	mesh_data.positions = positions

	# Chirality reversal: flipping an odd number of axes (1 axis) reverses
	# geometric handedness. Invert triangle winding on every face.
	for face in mesh_data.faces:
		if face == null:
			continue
		var tris: PackedInt32Array = face.get_indexes()
		var reversed_tris := PackedInt32Array()
		reversed_tris.resize(tris.size())
		for i in range(0, tris.size(), 3):
			reversed_tris[i] = tris[i]
			reversed_tris[i + 1] = tris[i + 2]
			reversed_tris[i + 2] = tris[i + 1]
		face.set_indexes(reversed_tris)
		face.invalidate_cache()

	mesh_data.invalidate_caches()
	mesh_data.rebuild_welds()
	mesh_data.calculate_normals()
	mesh_data.shape_edited = true
	return true

# ==============================================================================
# Pivot Tools
# ==============================================================================

## Moves the pivot to the geometric center of the mesh bounding box,
## translating vertices in local space so scene position remains static.
static func center_pivot(mesh: PBMesh) -> bool:
	if mesh == null or mesh.pb_mesh_data == null or mesh.pb_mesh_data.positions.is_empty():
		return false

	var md: PBMeshData = mesh.pb_mesh_data
	var aabb := AABB(md.positions[0], Vector3.ZERO)
	for p in md.positions:
		aabb = aabb.expand(p)

	var center: Vector3 = aabb.get_center()
	if center.length_squared() < 0.000001:
		return false # Already centered

	# Offset vertices
	var new_pos := md.positions.duplicate()
	for i in range(new_pos.size()):
		new_pos[i] -= center
	md.positions = new_pos
	md.invalidate_caches()
	md.rebuild_welds()

	# Compensate node transform
	var xf := mesh.global_transform if mesh.is_inside_tree() else mesh.transform
	var center_world: Vector3 = xf.basis * center
	if mesh.is_inside_tree():
		mesh.global_position += center_world
	else:
		mesh.position += center

	# Compensate child nodes
	for child in mesh.get_children():
		if child is Node3D:
			(child as Node3D).position -= center

	mesh.rebuild()
	return true

## Sets pivot to the centroid of currently selected elements.
static func set_pivot_to_selection(mesh: PBMesh, selection: PBSelection, mode: PBEditor.SelectMode) -> bool:
	if mesh == null or mesh.pb_mesh_data == null or selection == null:
		return false
	var md: PBMeshData = mesh.pb_mesh_data
	var centroid: Vector3 = Vector3.ZERO

	match mode:
		PBEditor.SelectMode.VERTEX:
			if selection.selected_vertices.is_empty():
				return false
			var lookup := md.get_shared_vertex_lookup()
			var pts: PackedVector3Array = PackedVector3Array()
			for sv in selection.selected_vertices:
				for i in range(md.positions.size()):
					if lookup.get(i, -1) == sv:
						pts.append(md.positions[i])
			centroid = PBMath.average(pts)

		PBEditor.SelectMode.EDGE:
			if selection.selected_edges.is_empty():
				return false
			var pts: PackedVector3Array = PackedVector3Array()
			for e in selection.selected_edges:
				pts.append(md.positions[e.a])
				pts.append(md.positions[e.b])
			centroid = PBMath.average(pts)

		PBEditor.SelectMode.FACE, PBEditor.SelectMode.TEXTURE:
			if selection.selected_faces.is_empty():
				return false
			var pts: PackedVector3Array = PackedVector3Array()
			for fi in selection.selected_faces:
				if fi >= 0 and fi < md.faces.size() and md.faces[fi] != null:
					pts.append_array(md.get_face_positions(fi))
			centroid = PBMath.average(pts)
		_:
			return false

	# Offset vertices
	var new_pos := md.positions.duplicate()
	for i in range(new_pos.size()):
		new_pos[i] -= centroid
	md.positions = new_pos
	md.invalidate_caches()
	md.rebuild_welds()

	# Compensate node transform
	var xf := mesh.global_transform if mesh.is_inside_tree() else mesh.transform
	var centroid_world: Vector3 = xf.basis * centroid
	if mesh.is_inside_tree():
		mesh.global_position += centroid_world
	else:
		mesh.position += centroid

	# Compensate children
	for child in mesh.get_children():
		if child is Node3D:
			(child as Node3D).position -= centroid

	mesh.rebuild()
	return true

## Bakes the node's local transform into vertex positions and resets transform to identity.
static func freeze_transform(mesh: PBMesh) -> bool:
	if mesh == null or mesh.pb_mesh_data == null:
		return false
	var md: PBMeshData = mesh.pb_mesh_data
	var xf: Transform3D = mesh.transform
	if xf.is_equal_approx(Transform3D.IDENTITY):
		return false # Nothing to freeze

	var new_pos := md.positions.duplicate()
	for i in range(new_pos.size()):
		new_pos[i] = xf * new_pos[i]
	md.positions = new_pos

	# If transform has negative scale parity, flip winding
	if xf.basis.determinant() < 0:
		for face in md.faces:
			if face == null:
				continue
			var tris: PackedInt32Array = face.get_indexes()
			var reversed_tris := PackedInt32Array()
			reversed_tris.resize(tris.size())
			for i in range(0, tris.size(), 3):
				reversed_tris[i] = tris[i]
				reversed_tris[i + 1] = tris[i + 2]
				reversed_tris[i + 2] = tris[i + 1]
			face.set_indexes(reversed_tris)
			face.invalidate_cache()

	md.invalidate_caches()
	md.rebuild_welds()
	md.calculate_normals()
	md.shape_edited = true

	mesh.transform = Transform3D.IDENTITY
	mesh.rebuild()
	return true

# ==============================================================================
# Probuilderize (Convert to PoiBuilder PBMesh)
# ==============================================================================

## Converts a standard MeshInstance3D into an editable PBMesh.
## Duplicates corner positions for Position-Privacy, rebuilds welds, and
## sets outward normal winding.
static func probuilderize(mesh_instance: MeshInstance3D) -> PBMesh:
	if mesh_instance == null or mesh_instance.mesh == null:
		return null

	var source_mesh: Mesh = mesh_instance.mesh
	var pb_mesh_data := PBMeshData.new()

	var split_positions := PackedVector3Array()
	var split_uvs := PackedVector2Array()
	var split_normals := PackedVector3Array()
	var faces: Array[PBFace] = []

	var vertex_counter := 0

	for surface_idx in range(source_mesh.get_surface_count()):
		var arrays: Array = source_mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue

		var surf_verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
		var surf_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var surf_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var surf_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()

		# If unindexed, generate linear indices
		if surf_indices.is_empty():
			surf_indices = PackedInt32Array()
			surf_indices.resize(surf_verts.size())
			for i in range(surf_verts.size()):
				surf_indices[i] = i

		# Each triangle becomes a PBFace with dedicated positions (Position-Privacy)
		for i in range(0, surf_indices.size() - 2, 3):
			# Note: Godot ArrayMesh is CW-front, internal PBMeshData is CCW-from-outside.
			# Reverse triangle index order [i, i+2, i+1] so internal winding is CCW.
			var i0: int = surf_indices[i]
			var i1: int = surf_indices[i + 2]
			var i2: int = surf_indices[i + 1]

			var p0: Vector3 = surf_verts[i0]
			var p1: Vector3 = surf_verts[i1]
			var p2: Vector3 = surf_verts[i2]

			# Degenerate triangle check
			if (p1 - p0).cross(p2 - p0).length_squared() < 0.0000001:
				continue

			split_positions.append(p0)
			split_positions.append(p1)
			split_positions.append(p2)

			if not surf_uvs.is_empty():
				split_uvs.append(surf_uvs[i0])
				split_uvs.append(surf_uvs[i1])
				split_uvs.append(surf_uvs[i2])
			else:
				split_uvs.append(Vector2.ZERO)
				split_uvs.append(Vector2(1, 0))
				split_uvs.append(Vector2(0, 1))

			if not surf_normals.is_empty():
				split_normals.append(surf_normals[i0])
				split_normals.append(surf_normals[i1])
				split_normals.append(surf_normals[i2])

			var face := PBFace.new()
			face.set_indexes(PackedInt32Array([vertex_counter, vertex_counter + 1, vertex_counter + 2]))
			face.submesh_index = surface_idx
			face.manual_uv = true
			faces.append(face)

			vertex_counter += 3

	if split_positions.is_empty():
		return null

	pb_mesh_data.positions = split_positions
	pb_mesh_data.textures0 = split_uvs
	pb_mesh_data.faces = faces
	pb_mesh_data.rebuild_welds()
	pb_mesh_data.calculate_normals()
	pb_mesh_data.shape_edited = true

	var pb_mesh := PBMesh.new()
	pb_mesh.name = mesh_instance.name + "_PBMesh"
	pb_mesh.transform = mesh_instance.transform
	pb_mesh.pb_mesh_data = pb_mesh_data
	pb_mesh.rebuild()
	return pb_mesh
