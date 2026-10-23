## test_pb_scrolling_scan.gd — which materials the editor's scrolling-texture
## animation finds (PBUv.collect_scrolling_materials, v0.9.182).
extends GutTest

func _scrolling(speed: Vector2) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	PBUv.set_scroll_speed(m, speed)
	return m

func test_collects_every_scrolling_material_once_at_any_depth() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var water := _scrolling(Vector2(0.5, 0))
	var lava := _scrolling(Vector2(0, -0.2))
	var flag := _scrolling(Vector2(1, 0))
	var still := StandardMaterial3D.new()
	# A PBMesh wearing a scrolling and a still material — twice (dedupe).
	for i in range(2):
		var pb := PBMesh.new()
		var data := PBMeshData.create_cube(1.0)
		data.set_face_material(data.faces[0], water)
		data.set_face_material(data.faces[1], still)
		pb.pb_mesh_data = data
		root.add_child(pb)
	# A plain mesh deep in the tree: override material.
	var group := Node3D.new()
	root.add_child(group)
	var plain := MeshInstance3D.new()
	plain.mesh = BoxMesh.new()
	plain.material_override = lava
	group.add_child(plain)
	# A plain mesh with a scrolling SURFACE material.
	var plain2 := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.material = flag
	plain2.mesh = box
	group.add_child(plain2)
	var found := PBUv.collect_scrolling_materials(root)
	assert_eq(found.size(), 3, "water, lava and flag — once each, the still one never")
	for m in [water, lava, flag]:
		assert_true(found.has(m), "%s found" % m)
	assert_false(found.has(still))

func test_render_chunks_do_not_duplicate_a_pbmesh_material() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var water := _scrolling(Vector2(0.5, 0))
	var pb := PBMesh.new()
	var data := PBShapeGenerators.create_plane(18.0, 18.0, 18, 18)
	for i in range(data.faces.size()):
		data.set_face_material(data.faces[i], water if i == data.faces.size() - 1 else StandardMaterial3D.new())
	pb.pb_mesh_data = data
	root.add_child(pb)
	assert_eq(pb.get_render_meshes().size(), 2, "fixture: the scrolling face renders in the overflow chunk")
	assert_eq(PBUv.collect_scrolling_materials(root), [water] as Array[StandardMaterial3D])
