## test_pb_scene_pick.gd — the ONE scene-wide face pick every viewport tool
## uses (PBPicking.scene_ray_pick, v0.9.182).
##
## The plugin had seven hand-copied "which surface is under the cursor" loops:
## two with an AABB prefilter, three with a visibility check. The paint brush
## ray-tested every triangle of every mesh in GDScript on every interpolated
## step (50 ms per pick at 500 meshes), returned the SELECTED mesh whenever
## the ray met it anywhere (painting through whatever stood in front), and
## shape creation snapped onto hidden meshes.
extends GutTest

func _box(size: Vector3, pos: Vector3, name_hint: String = "Box") -> PBMesh:
	var m := PBMesh.new()
	m.name = name_hint
	m.collider_type = PBMesh.ColliderType.OFF
	m.pb_mesh_data = PBShapeGenerators.create_box(size)
	m.position = pos
	add_child_autofree(m)
	return m

func test_the_nearest_surface_wins_in_any_order() -> void:
	var far := _box(Vector3.ONE, Vector3(0, 0, -10), "Far")
	var near := _box(Vector3.ONE, Vector3(0, 0, -5), "Near")
	for order in [[far, near], [near, far]]:
		var hit := PBPicking.scene_ray_pick(order, Vector3.ZERO, Vector3.FORWARD)
		assert_eq(hit.get("mesh"), near, "the nearer box wins regardless of list order")
		assert_almost_eq(float(hit["distance"]), 4.5, 0.001)
		assert_true((hit["normal"] as Vector3).is_equal_approx(Vector3.BACK), "the face facing the ray")

func test_hidden_and_excluded_meshes_never_hit() -> void:
	var near := _box(Vector3.ONE, Vector3(0, 0, -5), "Near")
	var far := _box(Vector3.ONE, Vector3(0, 0, -10), "Far")
	near.visible = false
	assert_eq(PBPicking.scene_ray_pick([near, far], Vector3.ZERO, Vector3.FORWARD).get("mesh"), far,
			"a hidden mesh is looked through (creation used to snap onto hidden meshes)")
	near.visible = true
	assert_eq(PBPicking.scene_ray_pick([near, far], Vector3.ZERO, Vector3.FORWARD, [near]).get("mesh"), far,
			"an excluded mesh (a tool's own preview) is looked through")

func test_face_filter_looks_through_rejected_faces() -> void:
	# A thin floor slab between the camera and a wall, ray looking down-forward.
	var wall := _box(Vector3(4, 4, 0.2), Vector3(0, 0, -6), "Wall")
	var slab := _box(Vector3(4, 0.1, 4), Vector3(0, -0.6, -2.5), "Slab")
	var ray_d := Vector3(0, -0.55, -3.0).normalized()  # meets the slab top at z = -3
	var any := PBPicking.scene_ray_pick([wall, slab], Vector3.ZERO, ray_d)
	assert_eq(any.get("mesh"), slab, "fixture: unfiltered, the slab is in front")
	var walls_only := PBPicking.scene_ray_pick([wall, slab], Vector3.ZERO, ray_d, [],
			func(h: Dictionary) -> bool: return absf((h["normal"] as Vector3).dot(Vector3.UP)) <= 0.7)
	assert_eq(walls_only.get("mesh"), wall, "the filter rejects the floor and the wall behind it wins")

func test_faces_in_an_overflow_chunk_are_pickable() -> void:
	var m := PBMesh.new()
	m.collider_type = PBMesh.ColliderType.OFF
	add_child_autofree(m)
	var data := PBShapeGenerators.create_plane(18.0, 18.0, 18, 18)
	for i in range(data.faces.size()):
		data.set_face_material(data.faces[i], StandardMaterial3D.new())
	m.pb_mesh_data = data
	assert_eq(m.get_render_meshes().size(), 2, "fixture: the plane renders in two chunks")
	var box := m.get_full_aabb()
	for p in data.positions:
		assert_true(box.grow(0.001).has_point(p), "the full AABB covers every chunk (%s)" % p)
	# Every face's centre is hit from above, overflow chunk included.
	var missed := 0
	for fi in range(data.faces.size()):
		var c := PBMath.average(data.positions, data.faces[fi].get_distinct_indexes())
		var hit := PBPicking.scene_ray_pick([m], c + Vector3.UP * 5.0, Vector3.DOWN)
		if hit.get("face_index", -1) != fi:
			missed += 1
	assert_eq(missed, 0, "no face is unpickable")

## The cost contract, pinned as work rather than time: a pick across a 500
## object scene triangle-tests only the meshes at the front of the ray.
func test_a_pick_across_many_meshes_tests_only_the_front_ones() -> void:
	var meshes: Array = []
	for i in range(500):
		meshes.append(_box(Vector3(1, 3, 0.2), Vector3(float(i % 50) * 2.0, 1.5, -float(i / 50) * 2.0 - 2.0)))
	var hit := PBPicking.scene_ray_pick(meshes, Vector3(10, 1.5, 5), Vector3.FORWARD)
	assert_false(hit.is_empty(), "fixture: the ray hits the front row")
	assert_lt(PBPicking.last_scene_pick_meshes_tested, 3,
			"%d of 500 meshes were triangle-tested" % PBPicking.last_scene_pick_meshes_tested)

func test_collect_finds_nested_pbmeshes_and_skips_render_chunks() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var group := Node3D.new()
	root.add_child(group)
	var a := PBMesh.new()
	a.pb_mesh_data = PBShapeGenerators.create_box(Vector3.ONE)
	group.add_child(a)
	var big := PBMesh.new()
	var data := PBShapeGenerators.create_plane(18.0, 18.0, 18, 18)
	for i in range(data.faces.size()):
		data.set_face_material(data.faces[i], StandardMaterial3D.new())
	big.pb_mesh_data = data
	root.add_child(big)
	var found := PBPicking.collect_pbmeshes(root)
	assert_eq(found.size(), 2, "both PBMeshes, at any depth — and no internal render chunk")

func test_plain_mesh_pick_cache_holds_no_mesh_alive() -> void:
	var am := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var faces := PBPicking.plain_mesh_pick_faces(am)
	assert_eq(faces.size(), 3)
	var weak: WeakRef = weakref(am)
	am = null
	assert_null(weak.get_ref(), "the pick cache keeps no strong reference to a mesh")

func test_plain_mesh_pick_ignores_pbmeshes() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var pb := PBMesh.new()
	pb.pb_mesh_data = PBShapeGenerators.create_box(Vector3.ONE)
	pb.position = Vector3(0, 0, -5)
	root.add_child(pb)
	var hit := PBPicking.pick_plain_mesh_surface(root, Vector3.ZERO, Vector3.FORWARD, INF)
	assert_true(hit.is_empty(), "PBMeshes are picked from their data, never as plain meshes")

func test_a_prepared_scene_answers_like_a_fresh_pick() -> void:
	var near := _box(Vector3.ONE, Vector3(0, 0, -5), "Near")
	var far := _box(Vector3.ONE, Vector3(1.5, 0, -10), "Far")
	var hidden := _box(Vector3.ONE, Vector3(0, 0, -3), "Hidden")
	hidden.visible = false
	var prepared := PBPicking.prepare_scene_candidates([near, far, hidden])
	assert_eq(prepared.size(), 2, "the hidden mesh is not a candidate")
	for ray in [[Vector3.ZERO, Vector3.FORWARD], [Vector3(1.5, 0, 0), Vector3.FORWARD], [Vector3(9, 0, 0), Vector3.FORWARD]]:
		var fresh := PBPicking.scene_ray_pick([near, far, hidden], ray[0], ray[1])
		var reused := PBPicking.scene_ray_pick_prepared(prepared, ray[0], ray[1])
		assert_eq(reused.get("mesh"), fresh.get("mesh"), "same answer for ray %s" % str(ray))
