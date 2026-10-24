## test_pb_duplicate_mesh.gd — a duplicated PBMesh owns its data (v0.9.184).
##
## Reported: duplicate a plane wearing a scrolling texture, re-texture the
## copy, and the ORIGINAL stops scrolling; export, and both come out with the
## same texture. The editor's Duplicate (Node.duplicate) shares Resource-valued
## properties, so the copy and the original edited ONE PBMeshData: the copy's
## re-texture rewrote the original's material slot (the scroll scan reads the
## data, so the original's animated material left the registry), and the
## exporter read both nodes from that one data. PBMesh.claim_mesh_data (run on
## _enter_tree in the editor) gives the second holder a deep copy.
extends GutTest

const TEX_A := "res://addons/poibuilder/materials/textures/waterfall_sheet.png"
const TEX_B := "res://addons/poibuilder/materials/textures/waterfall_core.png"

var _prev_edited_root: Node = null

func before_each() -> void:
	_prev_edited_root = get_tree().edited_scene_root

func after_each() -> void:
	get_tree().edited_scene_root = _prev_edited_root

func _scrolling_material(tex_path: String, speed: Vector2) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(tex_path)
	PBUv.set_scroll_speed(m, speed)
	return m

## An "edited scene" root holding one scrolling plane, the way the editor has
## it: the plane is owned by the root and has claimed its data.
func _scene_with_plane() -> Array:
	var root := Node3D.new()
	add_child_autofree(root)
	get_tree().edited_scene_root = root
	var plane := PBMesh.new()
	plane.name = "Shape_Plane"
	plane.pb_mesh_data = PBShapeGenerators.create_plane(2.2, 2.2, 1, 1)
	plane.pb_mesh_data.set_faces_material(plane.pb_mesh_data.faces,
			_scrolling_material(TEX_A, Vector2(0, -2.4)))
	root.add_child(plane)
	plane.owner = root
	plane.claim_mesh_data()
	return [root, plane]

## What the editor's Duplicate does: Node.duplicate, add as a sibling, THEN
## set_owner (scene_tree_dock.cpp TOOL_DUPLICATE), entering the tree unowned.
func _editor_duplicate(node: PBMesh) -> PBMesh:
	var dup := node.duplicate() as PBMesh
	node.add_sibling(dup, true)
	var privatised := dup.claim_mesh_data()   # what _enter_tree runs in the editor
	dup.owner = node.owner
	assert_true(privatised, "the duplicate takes its own copy of the data")
	return dup

func test_node_duplicate_shares_the_data_resource() -> void:
	# The engine behaviour the fix exists for; if this ever stops holding, the
	# claim is dead code and the docs/comments should say so.
	var parts := _scene_with_plane()
	var plane: PBMesh = parts[1]
	var dup := plane.duplicate() as PBMesh
	autofree(dup)
	assert_same(dup.pb_mesh_data, plane.pb_mesh_data, "Node.duplicate shares the PBMeshData")

func test_duplicate_owns_a_deep_copy() -> void:
	var parts := _scene_with_plane()
	var plane: PBMesh = parts[1]
	var dup := _editor_duplicate(plane)
	assert_ne(dup.pb_mesh_data, plane.pb_mesh_data)
	assert_ne(dup.pb_mesh_data.faces[0], plane.pb_mesh_data.faces[0], "faces are not shared")
	assert_eq(dup.pb_mesh_data.positions, plane.pb_mesh_data.positions, "same geometry")
	assert_same(dup.pb_mesh_data.materials[0], plane.pb_mesh_data.materials[0],
			"a plain material stays shared (same look, one animated material)")
	assert_ne(dup.mesh, plane.mesh, "the copy rebuilt its own ArrayMesh")

func test_retexturing_the_copy_keeps_the_original_scrolling() -> void:
	var parts := _scene_with_plane()
	var root: Node3D = parts[0]
	var plane: PBMesh = parts[1]
	var original_mat: Material = plane.pb_mesh_data.materials[0]
	var dup := _editor_duplicate(plane)
	# Re-texture the copy the way the material dock does: the scroll is carried.
	var prepared := PBApplyPrep.prepare(StandardMaterial3D.new(), dup.pb_mesh_data.get_face_material(dup.pb_mesh_data.faces[0]))
	(prepared as StandardMaterial3D).albedo_texture = load(TEX_B)
	dup.pb_mesh_data.set_faces_material(dup.pb_mesh_data.faces, prepared)
	dup.rebuild()
	assert_same(plane.pb_mesh_data.get_face_material(plane.pb_mesh_data.faces[0]), original_mat,
			"the original's face keeps its material")
	var scrolling := PBUv.collect_scrolling_materials(root)
	assert_true(scrolling.has(original_mat), "the original still scrolls")
	assert_true(scrolling.has(prepared), "and so does the copy")

func test_export_carries_both_textures() -> void:
	var parts := _scene_with_plane()
	var root: Node3D = parts[0]
	var plane: PBMesh = parts[1]
	var dup := _editor_duplicate(plane)
	dup.position.x += 3.0
	dup.pb_mesh_data.set_faces_material(dup.pb_mesh_data.faces,
			_scrolling_material(TEX_B, Vector2(0, -1.15)))
	dup.rebuild()
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.bake_textures = true
	var tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(tree)
	autofree(tree)
	# The drawn meshes carry the exporter's converted textures (no source
	# path), so the evidence is per drawn mesh: its speed and its pixels.
	var pixels_by_speed: Dictionary = {}
	for mi in tree.find_children("*", "MeshInstance3D", true, false):
		var m := (mi as MeshInstance3D).mesh
		if m == null or String(mi.name).begins_with("Collider_"):
			continue
		for s in range(m.get_surface_count()):
			var mat := m.surface_get_material(s) as StandardMaterial3D
			if mat != null and mat.albedo_texture != null and PBUv.has_scroll(mat):
				var centi_v := roundi(PBUv.get_scroll_speed(mat).y * 100.0)
				pixels_by_speed[centi_v] = hash(mat.albedo_texture.get_image().get_data())
	assert_eq(pixels_by_speed.size(), 2, "two scrolling meshes: the original's speed and the copy's (%s)" % [pixels_by_speed.keys()])
	assert_true(pixels_by_speed.has(-240) and pixels_by_speed.has(-115), "speeds -2.4 and -1.15")
	if pixels_by_speed.size() == 2:
		assert_ne(pixels_by_speed.values()[0], pixels_by_speed.values()[1], "and two different textures")

func test_reentering_the_tree_keeps_the_data() -> void:
	var parts := _scene_with_plane()
	var root: Node3D = parts[0]
	var plane: PBMesh = parts[1]
	var data := plane.pb_mesh_data
	root.remove_child(plane)       # what undoing a create / scene-tab switch does
	root.add_child(plane)
	assert_false(plane.claim_mesh_data(), "its own claim: no copy")
	assert_same(plane.pb_mesh_data, data)
	plane.owner = root

func test_instanced_content_keeps_sharing_its_scene_data() -> void:
	var parts := _scene_with_plane()
	var root: Node3D = parts[0]
	var shared := PBShapeGenerators.create_plane(1.0, 1.0, 1, 1)
	var meshes: Array[PBMesh] = []
	for i in range(2):
		# An instance of a prefab: the instance root carries scene_file_path and
		# owns the prefab's nodes, which share the prefab's resources.
		var inst := Node3D.new()
		inst.scene_file_path = "res://prefab_torch.tscn"
		root.add_child(inst)
		inst.owner = root
		var pb := PBMesh.new()
		pb.pb_mesh_data = shared
		pb.owner = null
		inst.add_child(pb)
		pb.owner = inst
		pb.claim_mesh_data()
		meshes.append(pb)
	assert_same(meshes[0].pb_mesh_data, shared)
	assert_same(meshes[1].pb_mesh_data, shared, "an instance's node never privatises (no override saved)")

func test_a_scene_saved_while_shared_is_repaired_on_load() -> void:
	# The reporter's scratch scene was SAVED with both planes on one data
	# resource; loading it must split them again.
	var src := Node3D.new()
	var data := PBShapeGenerators.create_plane(2.0, 2.0, 1, 1)
	for i in range(2):
		var pb := PBMesh.new()
		pb.name = "Plane%d" % i
		pb.pb_mesh_data = data
		src.add_child(pb)
		pb.owner = src
	var packed := PackedScene.new()
	assert_eq(packed.pack(src), OK)
	src.free()
	var root := packed.instantiate() as Node3D
	assert_same((root.get_child(0) as PBMesh).pb_mesh_data, (root.get_child(1) as PBMesh).pb_mesh_data,
			"fixture: the saved scene shares one data")
	get_tree().edited_scene_root = root
	add_child_autofree(root)
	var a := root.get_child(0) as PBMesh
	var b := root.get_child(1) as PBMesh
	assert_false(a.claim_mesh_data())
	assert_true(b.claim_mesh_data(), "the second holder privatises")
	assert_ne(a.pb_mesh_data, b.pb_mesh_data)

func test_scroll_speed_on_a_copy_leaves_the_originals_gltf_extras() -> void:
	# Resource.duplicate() shares metadata dictionaries: writing the copy's
	# speed into its `extras` in place re-timed the original's GLB animation.
	var original := _scrolling_material(TEX_A, Vector2(0, -2.4))
	var copy := original.duplicate() as StandardMaterial3D
	PBUv.set_scroll_speed(copy, Vector2(0, -1.15))
	assert_eq(PBUv.scroll_from_extras(original.get_meta(PBUv.GLTF_EXTRAS_META)), Vector2(0, -2.4),
			"the original's extras keep its own speed")
	assert_almost_eq(PBUv.scroll_from_extras(copy.get_meta(PBUv.GLTF_EXTRAS_META)).y, -1.15, 1e-5)
	PBUv.set_scroll_speed(copy, Vector2.ZERO)
	assert_true(original.has_meta(PBUv.GLTF_EXTRAS_META), "clearing the copy leaves the original's extras")
	assert_false(copy.has_meta(PBUv.GLTF_EXTRAS_META))
