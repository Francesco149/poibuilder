## Winding & normal convention regression tests.
##
## Conventions (locked in by these tests):
## - Internal PBMeshData is CCW-from-outside (Unity/ProBuilder convention).
## - Godot front faces are CW-from-outside (see ArrayMesh docs), so
##   to_array_mesh() must reverse each triangle's index order.
## - Attribute normals must point OUTWARD (same as Godot's own BoxMesh):
##   reversing indices flips which side is culled, never the outward direction.
##
## Ground truth: BoxMesh. For every Godot-authored triangle,
## attribute_normal · cross(v1-v0, v2-v0) < 0. Any change that flips our
## output relative to that breaks culling (inside-out cube) or lighting
## (inward normals) — this file exists because BOTH shipped to a human.
extends GutTest

func _surface_stats(mesh: Mesh, surf: int) -> Dictionary:
	var arrays := mesh.surface_get_arrays(surf)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var aabb := AABB(verts[0], Vector3.ZERO)
	for v in verts:
		aabb = aabb.expand(v)

	var normal_dot_cross: int = 0  # >0: normal agrees with CCW-cross order
	var outward_normals: int = 0   # normal points away from AABB center
	var cross_outward: int = 0     # output-tri cross points AWAY from AABB center
	var tri_count: int = idx.size() / 3
	for t in range(tri_count):
		var a: int = idx[t * 3]
		var b: int = idx[t * 3 + 1]
		var c: int = idx[t * 3 + 2]
		var cross: Vector3 = (verts[b] - verts[a]).cross(verts[c] - verts[a])
		if cross.length_squared() < 0.000000001:
			continue
		if norms[a].dot(cross.normalized()) > 0.0:
			normal_dot_cross += 1
		var face_center: Vector3 = (verts[a] + verts[b] + verts[c]) / 3.0
		if norms[a].dot(face_center - aabb.get_center()) > 0.0:
			outward_normals += 1
		if cross.dot(face_center - aabb.get_center()) > 0.0:
			cross_outward += 1

	return {
		"tris": tri_count,
		"normal_dot_cross": normal_dot_cross,
		"outward_normals": outward_normals,
		"cross_outward": cross_outward,
	}

func test_boxmesh_ground_truth_cw_front_outward_normals():
	# Sanity: Godot's own BoxMesh defines the convention we must match.
	var box := BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	var stats := _surface_stats(box, 0)
	assert_eq(stats["normal_dot_cross"], 0,
		"BoxMesh front faces are CW-from-outside: NO triangle normal should agree with cross()")
	assert_eq(stats["outward_normals"], stats["tris"],
		"BoxMesh normals all point outward")

func test_cube_array_mesh_matches_boxmesh_convention():
	var data := PBMeshData.create_cube(1.0)
	var mesh: ArrayMesh = data.to_array_mesh()
	assert_eq(mesh.get_surface_count(), 1, "Cube should compile to one surface")
	var stats := _surface_stats(mesh, 0)

	assert_eq(stats["normal_dot_cross"], 0,
		"Every cube triangle must be CW-from-outside (Godot front face). " +
		"Nonzero means the index conversion in to_array_mesh regressed.")
	assert_eq(stats["outward_normals"], stats["tris"],
		"Every cube normal must point outward. " +
		"Zero means normals were negated in to_array_mesh (the P6 normals bug).")

func test_cylinder_array_mesh_matches_convention():
	var data := PBShapeCylinder.create_cylinder(0.5, 1.0, 12, 1, 1)
	var mesh: ArrayMesh = data.to_array_mesh()
	for surf in range(mesh.get_surface_count()):
		var stats := _surface_stats(mesh, surf)
		assert_eq(stats["normal_dot_cross"], 0,
			"Cylinder surface %d: all triangles CW-from-outside" % surf)
		# Convex shape: every output cross must point toward the AABB center
		# (Godot CW front faces). Geometry-based — immune to per-vertex normal
		# welding at cap/side seams. This is the test that catches flipped caps.
		assert_eq(stats["cross_outward"], 0,
			"Cylinder surface %d: every triangle must face outward" % surf)

func test_all_factory_shapes_match_normal_convention():
	# Convention-level check (normal opposes cross) applies to every shape,
	# convex or not. This catches any generator producing CW internal data
	# or a conversion flipping attribute normals.
	for shape_id in PBShapeFactory.get_shape_ids():
		var data: PBMeshData = PBShapeFactory.create_shape(shape_id, Vector3.ONE)
		if data == null:
			continue
		var mesh: ArrayMesh = data.to_array_mesh()
		assert_gt(mesh.get_surface_count(), 0, "Shape '%s' should compile" % shape_id)
		for surf in range(mesh.get_surface_count()):
			var stats := _surface_stats(mesh, surf)
			assert_eq(stats["normal_dot_cross"], 0,
				"Shape '%s' surface %d: normals must oppose cross() (Godot CW front faces)" % [shape_id, surf])

func test_array_mesh_indices_are_reversed_from_internal():
	# The conversion is: output tri = (i2, i1, i0) of the internal CCW tri.
	var data := PBMeshData.create_cube(1.0)
	var face: PBFace = data.faces[0]
	var internal: PackedInt32Array = face.get_indexes()
	var mesh: ArrayMesh = data.to_array_mesh()
	var arrays := mesh.surface_get_arrays(0)
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	# First triangle of face 0 appears first in the surface
	assert_eq(idx[0], internal[2], "Reversed tri index 0")
	assert_eq(idx[1], internal[1], "Reversed tri index 1")
	assert_eq(idx[2], internal[0], "Reversed tri index 2")

func test_face_normals_point_away_from_mesh_interior():
	# Picking/backface logic and ProBuilder math rely on outward internal
	# normals (CCW convention): calculate_normals must agree with geometry.
	var data := PBMeshData.create_cube(1.0)
	var normals := data.calculate_normals()
	var aabb := AABB(data.positions[0], Vector3.ZERO)
	for p in data.positions:
		aabb = aabb.expand(p)
	var center := aabb.get_center()

	var outward := 0
	var total := 0
	for face in data.faces:
		var indexes := face.get_indexes()
		var face_center := Vector3.ZERO
		for i in indexes:
			face_center += data.positions[i]
		face_center /= float(indexes.size())
		if normals[indexes[0]].dot(face_center - center) > 0.0:
			outward += 1
		total += 1
	assert_eq(outward, total, "All internal cube normals must point outward (CCW convention)")

func test_get_common_edges_dedupes_cube():
	var data := PBMeshData.create_cube(1.0)
	var edges := data.get_common_edges()
	assert_eq(edges.size(), 12, "Cube must dedupe to 12 common edges")

	# Stable order: second call returns the same cache
	assert_eq(edges, data.get_common_edges(), "Cache should be stable")

	# Editing positions invalidates geometry caches
	data.set_positions(data.positions.duplicate())
	# (positions-only change keeps topology, but the cache must still rebuild)
	var edges2 := data.get_common_edges()
	assert_eq(edges2.size(), 12)
