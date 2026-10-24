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

# ── v0.9.185: a paste into ANOTHER scene ─────────────────────────────────────

const SCENE_A := "res://pb_test_paste_scene_a.tscn"
const SCENE_B := "res://pb_test_paste_scene_b.tscn"

## Scene A as the editor holds it after a tab switch: claimed, out of the tree.
## Faces wear a material BUILT INTO A's file; the top face is painted.
func _source_scene() -> Dictionary:
	var a_root := Node3D.new()
	a_root.scene_file_path = SCENE_A
	add_child_autofree(a_root)
	get_tree().edited_scene_root = a_root
	var src := PBMesh.new()
	src.pb_mesh_data = PBShapeGenerators.create_box(Vector3(2, 0.2, 2))
	var plain := StandardMaterial3D.new()
	plain.resource_path = SCENE_A + "::StandardMaterial3D_pbpaste"
	var data := src.pb_mesh_data
	data.set_faces_material(data.faces, plain)
	a_root.add_child(src)
	src.owner = a_root
	src.claim_mesh_data()
	var top := -1
	for fi in range(data.faces.size()):
		if PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes()).y > 0.99:
			top = fi
	var splat := PBSplat.ensure_face_owned_material(data, data.faces[top])
	var layer := PBSplat.ensure_layer_for_texture(splat, PlaceholderTexture2D.new(),
			PBSplat.live_mask_resolution_for(data, data.faces[top]).x)
	PBSplat.paint_face_splat(data, data.faces[top], splat, layer, Vector3(-0.5, 0.1, 0.0), 0.35, 0.5, 1.0, false, {})
	a_root.get_parent().remove_child(a_root)   # the tab switch
	return {"src": src, "plain": plain, "top": top, "layer": layer, "a_root": a_root}

## What the dock's cross-scene paste does (scene_tree_dock.cpp _paste_nodes):
## Node.duplicate plus a resource remap that SHALLOW-duplicates the data.
func _paste_into_scene_b(src: PBMesh) -> PBMesh:
	var b_root := Node3D.new()
	b_root.scene_file_path = SCENE_B
	add_child_autofree(b_root)
	get_tree().edited_scene_root = b_root
	var pasted := src.duplicate() as PBMesh
	pasted.pb_mesh_data = src.pb_mesh_data.duplicate()
	b_root.add_child(pasted)
	return pasted

func test_a_paste_into_another_scene_cannot_edit_the_source_scene() -> void:
	var a := _source_scene()
	var src: PBMesh = a["src"]
	var sdata := src.pb_mesh_data
	var top: int = a["top"]
	var layer: int = a["layer"]
	var src_splat := sdata.get_face_material(sdata.faces[top]) as ShaderMaterial
	var src_mask := hash(PBSplat.get_layer_mask_image(src_splat, layer).get_data())
	var pasted := _paste_into_scene_b(src)
	assert_same(pasted.pb_mesh_data.faces[0], sdata.faces[0],
			"fixture: the remap's shallow copy still holds the source scene's faces")
	assert_true(pasted.claim_mesh_data(), "the paste takes its own deep copy")
	var pdata := pasted.pb_mesh_data
	assert_ne(pdata.faces[0], sdata.faces[0])
	# Edit the paste every way PoiBuilder edits a mesh.
	pdata.faces[1].uv_scale = Vector2(7, 7)
	pdata.set_faces_material([pdata.faces[2]], StandardMaterial3D.new())
	var p_splat := pdata.get_face_material(pdata.faces[top]) as ShaderMaterial
	assert_ne(p_splat, src_splat, "the paint material is the paste's own")
	PBSplat.paint_face_splat(pdata, pdata.faces[top], p_splat, layer, Vector3(0.5, 0.1, 0.0), 0.35, 0.5, 1.0, false, {})
	assert_eq(sdata.faces[1].uv_scale, Vector2.ONE, "the source scene's faces are untouched")
	assert_same(sdata.get_face_material(sdata.faces[2]), a["plain"], "and its face materials")
	assert_eq(hash(PBSplat.get_layer_mask_image(src_splat, layer).get_data()), src_mask, "and its paint")

func test_a_paste_gets_its_own_copy_of_the_source_scenes_materials() -> void:
	var a := _source_scene()
	var src: PBMesh = a["src"]
	var plain: StandardMaterial3D = a["plain"]
	var pasted := _paste_into_scene_b(src)
	pasted.claim_mesh_data()
	var pdata := pasted.pb_mesh_data
	var mine := pdata.get_face_material(pdata.faces[0]) as StandardMaterial3D
	assert_ne(mine, plain, "a material built into scene A is copied, not shared")
	assert_false(mine.resource_path.begins_with(SCENE_A), "the copy belongs to no other scene")
	assert_same(pdata.get_face_material(pdata.faces[1]), mine, "faces that shared it share the one copy")
	mine.albedo_color = Color.RED   # an inspector edit in scene B
	assert_eq(plain.albedo_color, Color.WHITE, "never reaches scene A")

func test_foreign_materials_alone_do_not_privatise() -> void:
	# An inherited scene's base nodes wear the BASE file's materials; nothing
	# is shared with another live data, so they must keep their data (a copy
	# would be saved as an override into the inheriting scene).
	var root := Node3D.new()
	root.scene_file_path = SCENE_B
	add_child_autofree(root)
	get_tree().edited_scene_root = root
	var pb := PBMesh.new()
	pb.pb_mesh_data = PBShapeGenerators.create_plane(1.0, 1.0, 1, 1)
	var base_mat := StandardMaterial3D.new()
	base_mat.resource_path = SCENE_A + "::StandardMaterial3D_pbbase"
	pb.pb_mesh_data.set_faces_material(pb.pb_mesh_data.faces, base_mat)
	var data := pb.pb_mesh_data
	root.add_child(pb)
	pb.owner = root
	assert_false(pb.claim_mesh_data())
	assert_same(pb.pb_mesh_data, data)

func test_same_scene_duplicate_keeps_its_scenes_materials_shared() -> void:
	var root := Node3D.new()
	root.scene_file_path = SCENE_A
	add_child_autofree(root)
	get_tree().edited_scene_root = root
	var pb := PBMesh.new()
	pb.pb_mesh_data = PBShapeGenerators.create_plane(1.0, 1.0, 1, 1)
	var own := StandardMaterial3D.new()
	own.resource_path = SCENE_A + "::StandardMaterial3D_pbown"
	pb.pb_mesh_data.set_faces_material(pb.pb_mesh_data.faces, own)
	root.add_child(pb)
	pb.owner = root
	pb.claim_mesh_data()
	var dup := _editor_duplicate(pb)
	assert_same(dup.pb_mesh_data.get_face_material(dup.pb_mesh_data.faces[0]), own,
			"Ctrl+D within the scene keeps one shared material")
