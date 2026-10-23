## test_pb_mesh_build_scaling.gd — how a PBMeshData compiles when it carries
## many materials (v0.9.182 scaling audit).
##
## Every painted face is its own material, so its own surface, and two things
## broke as that count grew:
##   - Godot caps an ArrayMesh at 256 surfaces and only LOGS the refusal: the
##     faces on surface 257+ vanished (editor and shipped scene alike).
##   - Every surface carried the WHOLE vertex arrays: 400 painted faces on a
##     1,600-vertex floor uploaded 409,600 vertices, 152 ms per rebuild.
## The contracts: to_array_meshes() chunks at 256 and PBMesh draws every
## chunk; past COMPACT_SURFACES_FROM surfaces each one carries only its own
## vertices; nothing is lost either way.
extends GutTest

## A `segs` x `segs` plane whose faces each wear their OWN material.
func _many_material_plane(segs: int) -> PBMeshData:
	var data := PBShapeGenerators.create_plane(float(segs), float(segs), segs, segs)
	for i in range(data.faces.size()):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(float(i % 17) / 16.0, 0.5, 0.5)
		data.set_face_material(data.faces[i], m)
	return data

## Every rendered triangle (positions, 3 per triangle) across all chunks.
func _rendered_triangles(meshes: Array) -> Dictionary:
	var keys: Dictionary = {}
	for m in meshes:
		for s in range((m as ArrayMesh).get_surface_count()):
			var arrays := (m as ArrayMesh).surface_get_arrays(s)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for t in range(0, idx.size(), 3):
				var key := "%s|%s|%s" % [v[idx[t]].snapped(Vector3.ONE * 0.001), v[idx[t + 1]].snapped(Vector3.ONE * 0.001), v[idx[t + 2]].snapped(Vector3.ONE * 0.001)]
				keys[key] = int(keys.get(key, 0)) + 1
	return keys

func _soup_triangles(data: PBMeshData) -> Dictionary:
	var keys: Dictionary = {}
	var soup := data.get_triangle_soup()
	for t in range(0, soup.size(), 3):
		var key := "%s|%s|%s" % [soup[t].snapped(Vector3.ONE * 0.001), soup[t + 1].snapped(Vector3.ONE * 0.001), soup[t + 2].snapped(Vector3.ONE * 0.001)]
		keys[key] = int(keys.get(key, 0)) + 1
	return keys

func _surface_vertex_total(meshes: Array) -> int:
	var n := 0
	for m in meshes:
		for s in range((m as ArrayMesh).get_surface_count()):
			n += (m as ArrayMesh).surface_get_array_len(s)
	return n

# ── Chunking ────────────────────────────────────────────────────────────────

func test_more_than_256_surfaces_split_into_chunks_and_lose_nothing() -> void:
	var data := _many_material_plane(18)  # 324 faces, 324 materials
	assert_eq(data.surface_count(), 324, "fixture: one surface per face")
	var chunks := data.to_array_meshes()
	assert_eq(chunks.size(), 2, "256 + 68 surfaces")
	assert_eq(chunks[0].get_surface_count(), PBMeshData.MAX_SURFACES_PER_MESH)
	assert_eq(chunks[1].get_surface_count(), 324 - PBMeshData.MAX_SURFACES_PER_MESH)
	assert_eq(_rendered_triangles(chunks), _soup_triangles(data), "every triangle is rendered exactly once")
	var mats := {}
	for c in chunks:
		for s in range(c.get_surface_count()):
			mats[c.surface_get_material(s)] = true
	assert_eq(mats.size(), 324, "every surface keeps its own material")

func test_single_chunk_api_still_returns_the_whole_mesh_below_the_cap() -> void:
	var data := PBMeshData.create_cube(1.0)
	var am := data.to_array_mesh()
	assert_eq(am.get_surface_count(), 1)
	assert_eq(_rendered_triangles([am]), _soup_triangles(data))

# ── Compaction ──────────────────────────────────────────────────────────────

func test_many_surfaces_carry_only_their_own_vertices() -> void:
	var data := _many_material_plane(10)  # 100 faces x 4 corners
	var chunks := data.to_array_meshes()
	assert_eq(_surface_vertex_total(chunks), data.positions.size(),
			"each vertex is uploaded once, not once per surface")
	assert_eq(_rendered_triangles(chunks), _soup_triangles(data), "same triangles")

func test_few_surfaces_keep_the_shared_arrays() -> void:
	var data := PBMeshData.create_cube(1.0)
	var m := StandardMaterial3D.new()
	data.set_face_material(data.faces[0], m)
	var chunks := data.to_array_meshes()
	assert_eq(chunks[0].get_surface_count(), 2)
	assert_eq(_surface_vertex_total(chunks), data.positions.size() * 2,
			"below the threshold surfaces share the full arrays (a C++ copy, cheapest)")

func test_compaction_keeps_every_vertex_attribute() -> void:
	var data := _many_material_plane(6)
	data.textures1 = PackedVector2Array()
	for i in range(data.positions.size()):
		data.textures1.append(Vector2(float(i), 0.25))
	data.faces[0].splat_bounds = PackedFloat32Array([-3.0, 3.0, -3.0, 3.0])  # carries CUSTOM0
	var chunks := data.to_array_meshes()
	var uv2_seen := {}
	var with_custom := 0
	for c in chunks:
		for s in range(c.get_surface_count()):
			var arrays := c.surface_get_arrays(s)
			for uv in (arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array):
				uv2_seen[uv] = true
			if arrays[Mesh.ARRAY_CUSTOM0] != null:
				with_custom += 1
				assert_eq((arrays[Mesh.ARRAY_CUSTOM0] as PackedFloat32Array).size(),
						(arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * 2, "custom0 is per local vertex")
	assert_eq(uv2_seen.size(), data.positions.size(), "every vertex's UV2 survives compaction")
	assert_gt(with_custom, 0, "the splat mask channel rides along")

func test_drag_fast_path_moves_compacted_vertices() -> void:
	var data := _many_material_plane(5)
	data.to_array_meshes()  # warm the cached index buffers
	var moved := data.faces[7].get_distinct_indexes()[0]
	data.positions[moved] += Vector3(0, 2.5, 0)
	data.invalidate_normals()
	var chunks := data.to_array_meshes(true)
	var found := false
	for c in chunks:
		for s in range(c.get_surface_count()):
			for v in (c.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				if v.is_equal_approx(data.positions[moved]):
					found = true
	assert_true(found, "the cached (compacted) path renders the moved vertex")

# ── PBMesh renders every chunk ──────────────────────────────────────────────

func test_pbmesh_draws_overflow_chunks_as_unsaved_internal_children() -> void:
	var mesh := PBMesh.new()
	add_child_autofree(mesh)
	mesh.pb_mesh_data = _many_material_plane(18)
	assert_eq(mesh.mesh.get_surface_count(), PBMeshData.MAX_SURFACES_PER_MESH)
	assert_eq(mesh.get_render_meshes().size(), 2, "the overflow is drawn too")
	var internal := mesh.get_child_count(true) - mesh.get_child_count(false)
	assert_eq(internal, 1, "one internal chunk child, invisible to get_children()")
	for c in mesh.get_children():
		assert_false(String(c.name).begins_with(PBMesh.OVERFLOW_CHUNK_PREFIX), "chunks are not ordinary children")
	# Never saved: pack the mesh as a scene root.
	var packed := PackedScene.new()
	assert_eq(packed.pack(mesh), OK)
	var state := packed.get_state()
	for i in range(state.get_node_count()):
		assert_false(String(state.get_node_name(i)).begins_with(PBMesh.OVERFLOW_CHUNK_PREFIX),
				"a chunk never reaches the saved scene")
	# Back under the cap: the chunk goes away.
	mesh.pb_mesh_data = PBShapeGenerators.create_plane(2.0, 2.0, 2, 2)
	assert_eq(mesh.get_render_meshes().size(), 1)
	assert_eq(mesh.get_child_count(true) - mesh.get_child_count(false), 0, "no stale chunk child")

func test_editor_collider_covers_every_chunk() -> void:
	var mesh := PBMesh.new()
	add_child_autofree(mesh)
	mesh.pb_mesh_data = _many_material_plane(18)
	var shape := mesh.get_collider_body().get_node(PBMesh.COLLIDER_SHAPE_NAME).shape as ConcavePolygonShape3D
	assert_not_null(shape, "fixture: an accurate collider exists")
	assert_eq(shape.get_faces().size(), mesh.pb_mesh_data.index_count(),
			"the overflow chunk's faces collide too")

func test_collider_export_covers_every_chunk() -> void:
	var mesh := PBMesh.new()
	add_child_autofree(mesh)
	mesh.pb_mesh_data = _many_material_plane(18)
	var collider := PBMapExporter._merge_collider_meshes(mesh.get_render_meshes())
	var tris := (collider.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	assert_eq(tris, mesh.pb_mesh_data.index_count() / 3, "every face's triangles reach the collider")

func test_triangle_soup_matches_the_rendered_winding() -> void:
	var data := PBMeshData.create_cube(1.0)
	var soup := data.get_triangle_soup()
	assert_eq(soup.size(), data.index_count())
	assert_eq(_soup_triangles(data), _rendered_triangles([data.to_array_mesh()]),
			"picking triangles are the drawn triangles (same winding)")

func test_csg_refuses_an_operand_past_the_surface_cap() -> void:
	var a := PBMeshData.create_cube(2.0)
	for i in range(4):
		var all := PackedInt32Array()
		for fi in range(a.faces.size()):
			all.append(fi)
		PBMeshOps.subdivide_faces(a, all)
	assert_gt(a.faces.size(), PBMeshData.MAX_SURFACES_PER_MESH, "fixture: enough faces")
	for face in a.faces:
		a.set_face_material(face, StandardMaterial3D.new())
	var b := PBMeshData.create_cube(1.0)
	var res := PBCsg.perform_boolean(a, b, PBCsg.BooleanOp.UNION, Transform3D.IDENTITY, get_tree())
	assert_false(res.get("success", true), "refused instead of returning a mesh with holes")
	assert_string_contains(String(res.get("error", "")), "too many")
