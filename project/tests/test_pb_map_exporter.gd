## Unit tests for PBMapExporter
extends GutTest

func test_export_tree_retro_mode() -> void:
	var root := Node3D.new()
	autofree(root)

	# Light
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(0, 10, 0))
	root.add_child(light)

	# PBMesh cube
	var cube := PBMesh.create_cube(2.0)
	cube.name = "Floor"
	cube.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(cube)

	# Billboard sprite
	var sprite := MeshInstance3D.new()
	sprite.name = "SpriteTree"
	sprite.set_meta("is_billboard", true)
	sprite.set_meta("is_lit", true)
	var quad_mesh := QuadMesh.new()
	sprite.mesh = quad_mesh
	root.add_child(sprite)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.subdivide_quads = true
	settings.bake_lighting = true
	settings.bake_textures = true
	settings.export_colliders = true
	settings.export_billboards = true

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	# Check children of export_tree
	var floor_node := export_tree.get_node_or_null("Floor") as MeshInstance3D
	assert_not_null(floor_node, "Exported tree must have 'Floor' MeshInstance3D")
	assert_not_null(floor_node.mesh, "Floor must have an ArrayMesh")
	assert_gt(floor_node.mesh.get_surface_count(), 0, "Floor must have surfaces")

	# Verify vertex colors exist on the floor mesh
	var arrays := floor_node.mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_gt(colors.size(), 0, "Floor mesh surface must contain baked vertex colors")

	# Check collider node
	var col_node := export_tree.get_node_or_null("Collider_Floor") as MeshInstance3D
	assert_not_null(col_node, "Exported tree must contain 'Collider_Floor'")

	# Check billboard node
	var bb_node := export_tree.get_node_or_null("SpriteTree") as MeshInstance3D
	assert_not_null(bb_node, "Exported tree must contain 'SpriteTree'")
	var bb_arrays := bb_node.mesh.surface_get_arrays(0)
	var bb_colors: PackedColorArray = bb_arrays[Mesh.ARRAY_COLOR]
	assert_gt(bb_colors.size(), 0, "Lit billboard must have vertex colors")

func test_export_tree_modern_mode() -> void:
	var root := Node3D.new()
	autofree(root)

	var cube := PBMesh.create_cube(2.0)
	cube.name = "ModernCube"
	cube.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(cube)

	# Paint one face so the modern export has a splat stack to carry.
	var mesh_data := cube.pb_mesh_data
	var patch := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	patch.fill(Color(0.1, 0.8, 0.3, 1.0))
	var face := mesh_data.faces[0]
	var center := Vector3.ZERO
	for idx in face.get_distinct_indexes():
		center += mesh_data.positions[idx]
	center /= float(face.get_distinct_indexes().size())
	PBSplat.paste_decal(mesh_data, center, PBMath.normal_from_positions(mesh_data.positions, face.get_indexes()), 0.0, 0.6, 1.0, patch)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	settings.bake_lighting = false
	settings.export_colliders = true

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	var cube_node := export_tree.get_node_or_null("ModernCube") as MeshInstance3D
	assert_not_null(cube_node)

	# Default modern splat mode is BAKE: the painted face must ship a baked
	# texture, and no scene-node decals may exist any more.
	var baked_found := false
	for s in range(cube_node.mesh.get_surface_count()):
		var mat := cube_node.mesh.surface_get_material(s)
		if mat is StandardMaterial3D and mat.resource_name.begins_with("BakedSplat"):
			baked_found = true
	assert_true(baked_found, "Modern bake must substitute a per-face composite texture")
	assert_null(cube_node.get_node_or_null("PBStamps"),
			"Decals are pixels now — no decal nodes may reach the export")

func test_export_map_to_glb_file() -> void:
	var root := Node3D.new()
	autofree(root)

	var cube := PBMesh.create_cube(2.0)
	cube.name = "TestCube"
	root.add_child(cube)

	var out_path := "user://test_map_export.glb"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.subdivide_quads = true
	settings.bake_lighting = false

	var err := PBMapExporter.export_map(root, out_path, settings)
	assert_eq(err, OK, "export_map should return OK")
	assert_true(FileAccess.file_exists(out_path), "Exported GLB file must exist on disk")

	var fa := FileAccess.open(out_path, FileAccess.READ)
	assert_not_null(fa)
	assert_gt(fa.get_length(), 100, "GLB file must contain valid non-empty data")
	fa.close()

	# Clean up test file
	DirAccess.remove_absolute(out_path)

func test_ensure_export_dir_creates_gdignore() -> void:
	var test_dir := "res://test_export_temp"
	var test_path := test_dir.path_join("map.glb")
	PBMapExporter.ensure_export_dir(test_path)
	assert_true(DirAccess.dir_exists_absolute(test_dir), "Export dir must be created")
	assert_true(FileAccess.file_exists(test_dir.path_join(".gdignore")), ".gdignore must exist to prevent auto-import")
	# Cleanup
	DirAccess.remove_absolute(test_dir.path_join(".gdignore"))
	DirAccess.remove_absolute(test_dir)

func test_cleanup_intermediate_files() -> void:
	var test_dir := "user://test_cleanup_dir"
	DirAccess.make_dir_recursive_absolute(test_dir)
	var glb_path := test_dir.path_join("test_map.glb")
	var f := FileAccess.open(glb_path, FileAccess.WRITE)
	f.store_string("glb data")
	f.close()

	var loose_tex := test_dir.path_join("test_map_BakedTile_0_0_0_albedo.png")
	f = FileAccess.open(loose_tex, FileAccess.WRITE)
	f.store_string("png data")
	f.close()

	var loose_import := test_dir.path_join("test_map_BakedTile_0_0_0_albedo.png.import")
	f = FileAccess.open(loose_import, FileAccess.WRITE)
	f.store_string("import data")
	f.close()

	var unrelated := test_dir.path_join("unrelated_texture.png")
	f = FileAccess.open(unrelated, FileAccess.WRITE)
	f.store_string("keep me")
	f.close()

	var cleaned := PBMapExporter.cleanup_intermediate_files(glb_path)
	assert_eq(cleaned, 2, "Must clean 2 intermediate files")
	assert_false(FileAccess.file_exists(loose_tex), "Loose extracted texture must be removed")
	assert_false(FileAccess.file_exists(loose_import), "Loose texture .import must be removed")
	assert_true(FileAccess.file_exists(glb_path), "GLB file itself must be kept")
	assert_true(FileAccess.file_exists(unrelated), "Unrelated file must be kept")

	# Cleanup
	DirAccess.remove_absolute(glb_path)
	DirAccess.remove_absolute(unrelated)
	DirAccess.remove_absolute(test_dir)

func test_export_retro_pbm_format() -> void:
	var root := Node3D.new()
	var pb := PBMesh.new()
	pb.name = "TestCube"
	pb.pb_mesh_data = PBShapeGenerators.create_box(Vector3(2, 2, 2))
	root.add_child(pb)
	add_child_autofree(root)

	var pbm_path := "user://test_export_retro.pbm"
	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.bake_textures = false

	var err := PBMapExporter.export_retro_pbm(root, pbm_path, settings)
	assert_eq(err, OK, "PBM export must return OK")
	assert_true(FileAccess.file_exists(pbm_path), "PBM file must exist on disk")

	var f := FileAccess.open(pbm_path, FileAccess.READ)
	assert_not_null(f)
	var magic := f.get_32()
	assert_eq(magic, PBMapExporter.PBM_MAGIC, "Magic must match PBM3")
	var ver := f.get_32()
	assert_eq(ver, PBMapExporter.PBM_VERSION, "Version must match 3")
	var n_tex := f.get_32()
	var n_mesh := f.get_32()
	assert_gt(n_mesh, 0, "Must have at least 1 mesh exported")
	f.close()

	# Cleanup
	DirAccess.remove_absolute(pbm_path)

func _make_npot_texture(w: int = 300, h: int = 180) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.8, 0.2, 0.1, 1.0))
	return ImageTexture.create_from_image(img)

func _is_pot(n: int) -> bool:
	return n > 0 and (n & (n - 1)) == 0

func test_plain_meshinstance_is_exported() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var mi := MeshInstance3D.new()
	mi.name = "PropCrate"
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	mi.mesh = box
	root.add_child(mi)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.bake_textures = false
	var tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(tree)
	autofree(tree)
	var exported := tree.get_node_or_null("PropCrate") as MeshInstance3D
	assert_not_null(exported, "A regular MeshInstance3D must survive retro export")
	assert_not_null(exported.mesh)
	assert_gt(exported.mesh.get_surface_count(), 0)

func test_walkable_meshinstance_is_not_drawn() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var walk := MeshInstance3D.new()
	walk.name = "Walkable_Courtyard"
	walk.mesh = BoxMesh.new()
	root.add_child(walk)
	var prop := MeshInstance3D.new()
	prop.name = "PropCrate"
	prop.mesh = BoxMesh.new()
	root.add_child(prop)
	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	var tree := PBMapExporter.build_export_tree(root, settings)
	autofree(tree)
	assert_null(tree.get_node_or_null("Walkable_Courtyard"), "Walkable meshes are metadata, not a draw")
	assert_not_null(tree.get_node_or_null("PropCrate"), "Ordinary props still export")


## The paint controller's preview subtree lives in the LIVE scene (brush ring,
## StampQuad, StampDeleteHighlight). Exporting it shipped a floating stamp decal
## quad into GLB and PBM — reading as a stamp's edge leaking onto whatever mesh
## it overhung. Both the name guard and the explicit meta must stop it.
func test_paint_preview_subtree_is_never_exported() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var prop := MeshInstance3D.new()
	prop.name = "PropCrate"
	prop.mesh = BoxMesh.new()
	root.add_child(prop)

	var previews := Node3D.new()
	previews.name = "PBSplatPreviewNode"
	root.add_child(previews)
	var stamp_quad := MeshInstance3D.new()
	stamp_quad.name = "StampQuad"
	stamp_quad.mesh = QuadMesh.new()
	previews.add_child(stamp_quad)
	var delete_highlight := MeshInstance3D.new()
	delete_highlight.name = "StampDeleteHighlight"
	delete_highlight.mesh = QuadMesh.new()
	previews.add_child(delete_highlight)

	var meta_flagged := MeshInstance3D.new()
	meta_flagged.name = "SomeFutureToolGhost"
	meta_flagged.mesh = QuadMesh.new()
	meta_flagged.set_meta("poi_editor_preview", true)
	root.add_child(meta_flagged)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.bake_textures = false
	var tree := PBMapExporter.build_export_tree(root, settings)
	autofree(tree)
	assert_null(tree.get_node_or_null("PBSplatPreviewNode"), "Preview root must never export")
	assert_null(tree.get_node_or_null("StampQuad"), "Stamp preview quad must never export (it read as a leaked stamp)")
	assert_null(tree.get_node_or_null("StampDeleteHighlight"), "Delete highlight must never export")
	assert_null(tree.get_node_or_null("SomeFutureToolGhost"), "poi_editor_preview meta must never export")
	assert_not_null(tree.get_node_or_null("PropCrate"), "Ordinary props still export")


func test_plain_and_poibuilderized_both_export() -> void:
	var root := Node3D.new()
	add_child_autofree(root)

	var mi := MeshInstance3D.new()
	mi.name = "ImportedBarrel"
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 1.1, 0.8)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _make_npot_texture()
	mi.material_override = mat
	root.add_child(mi)

	var pb: PBMesh = PBObjectOps.poibuilderize(mi)
	assert_not_null(pb)
	pb.name = "ImportedBarrel_PB"
	root.add_child(pb)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.bake_textures = false
	settings.max_texture_size = 256
	var tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(tree)
	autofree(tree)
	assert_not_null(tree.get_node_or_null("ImportedBarrel"), "Unconverted MeshInstance3D is exported")
	assert_not_null(tree.get_node_or_null("ImportedBarrel_PB"), "Poibuilderized mesh is exported")

	var pbm_path := "user://test_plain_and_pb.pbm"
	if FileAccess.file_exists(pbm_path):
		DirAccess.remove_absolute(pbm_path)
	var err := PBMapExporter.export_retro_pbm(root, pbm_path, settings)
	assert_eq(err, OK)
	assert_true(FileAccess.file_exists(pbm_path))
	var f := FileAccess.open(pbm_path, FileAccess.READ)
	assert_not_null(f)
	assert_eq(f.get_32(), PBMapExporter.PBM_MAGIC)
	assert_eq(f.get_32(), PBMapExporter.PBM_VERSION)
	var n_tex := f.get_32()
	var n_mesh := f.get_32()
	assert_gt(n_mesh, 0, "PBM must contain geometry from both meshes")
	assert_gte(n_tex, 1, "NPOT albedo must be registered as a texture")
	f.get_32() # colliders
	f.get_32() # metadata
	for i in range(4):
		f.get_float() # spawn xyz + rot
	for i in range(6):
		f.get_float() # bounds
	for ti in range(n_tex):
		f.get_buffer(32)
		var w := f.get_16()
		var h := f.get_16()
		var fmt := f.get_16()
		var _alpha := f.get_16()
		var data_size := f.get_32()
		assert_true(_is_pot(w), "exported texture width %d must be power-of-two" % w)
		assert_true(_is_pot(h), "exported texture height %d must be power-of-two" % h)
		assert_lte(w, 256, "exported texture width must respect max_texture_size")
		assert_lte(h, 256, "exported texture height must respect max_texture_size")
		var bpp := 4 if fmt == PBMapExporter.PBM_TEX_FMT_RGBA8888 else 2
		assert_eq(data_size, w * h * bpp)
		f.seek(f.get_position() + data_size)
	f.close()
	DirAccess.remove_absolute(pbm_path)

func test_npot_albedo_sanitized_on_export_tree() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var mi := MeshInstance3D.new()
	mi.name = "Prop"
	mi.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _make_npot_texture(300, 180)
	mi.material_override = mat
	root.add_child(mi)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.max_texture_size = 512
	var tree := PBMapExporter.build_export_tree(root, settings)
	autofree(tree)
	var exported := tree.get_node_or_null("Prop") as MeshInstance3D
	assert_not_null(exported)
	var out_mat := exported.get_active_material(0) as StandardMaterial3D
	assert_not_null(out_mat)
	assert_not_null(out_mat.albedo_texture)
	var out_img := out_mat.albedo_texture.get_image()
	assert_not_null(out_img)
	assert_true(_is_pot(out_img.get_width()))
	assert_true(_is_pot(out_img.get_height()))
	assert_lte(out_img.get_width(), 512)
	assert_lte(out_img.get_height(), 512)
	assert_ne(out_img.get_width(), 300, "NPOT width must have been resized")


# ==============================================================================
# Imported props (an asset-pack .glb dropped into the scene, never poibuilderized)
# ==============================================================================

## A texture whose pixels are a known gradient, so a remapped UV can be checked
## against the texel it is supposed to land on.
func _make_gradient_texture(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			img.set_pixel(x, y, Color(float(x) / float(w), float(y) / float(h), 0.25, 1.0))
	return ImageTexture.create_from_image(img)

## A quad whose UVs cover `rect` of its texture, i.e. a prop that samples one
## corner of an atlas.
func _make_quad_uv(mi: MeshInstance3D, rect: Rect2) -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, -0.5), Vector3(0.5, 0.0, 0.5),
		Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, 0.5), Vector3(-0.5, 0.0, 0.5),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP,
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(rect.position.x, rect.position.y),
		Vector2(rect.end.x, rect.position.y),
		Vector2(rect.end.x, rect.end.y),
		Vector2(rect.position.x, rect.position.y),
		Vector2(rect.end.x, rect.end.y),
		Vector2(rect.position.x, rect.end.y),
	])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = am

## Reads the texture table out of a .pbm (name, width, height, format, alpha).
func _read_pbm_textures(path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	f.get_32() # magic
	f.get_32() # version
	var n_tex := f.get_32()
	f.get_32() # meshes
	f.get_32() # colliders
	f.get_32() # metadata
	for i in range(4):
		f.get_float()
	for i in range(6):
		f.get_float()
	for i in range(n_tex):
		var name_bytes := f.get_buffer(32)
		var tex_name := ""
		for b in name_bytes:
			if b == 0:
				break
			tex_name += char(b)
		var w := f.get_16()
		var h := f.get_16()
		var fmt := f.get_16()
		var alpha := f.get_16()
		var data_size := f.get_32()
		out.append({"name": tex_name, "w": w, "h": h, "fmt": fmt, "alpha": alpha})
		f.seek(f.get_position() + data_size)
	f.close()
	return out

## Reads the (name, texture_id, first vertex) of every mesh record in a .pbm.
func _read_pbm_meshes(path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	f.get_32()
	f.get_32()
	var n_tex := f.get_32()
	var n_mesh := f.get_32()
	f.get_32()
	f.get_32()
	for i in range(4):
		f.get_float()
	for i in range(6):
		f.get_float()
	for i in range(n_tex):
		f.get_buffer(32)
		f.get_16()
		f.get_16()
		f.get_16()
		f.get_16()
		var data_size := f.get_32()
		f.seek(f.get_position() + data_size)
	for i in range(n_mesh):
		var name_bytes := f.get_buffer(32)
		var mesh_name := ""
		for b in name_bytes:
			if b == 0:
				break
			mesh_name += char(b)
		var tex_id := f.get_32()
		var n_verts := f.get_32()
		var bounds := []
		for k in range(6):
			bounds.append(f.get_float())
		f.get_float() # scroll u
		f.get_float() # scroll v
		var u := f.get_float()
		var v := f.get_float()
		f.get_32()
		var x := f.get_float()
		var y := f.get_float()
		var z := f.get_float()
		f.seek(f.get_position() + (n_verts - 1) * 24)
		out.append({"name": mesh_name, "tex": tex_id, "verts": n_verts, "uv": Vector2(u, v),
			"pos": Vector3(x, y, z), "bounds": bounds})
	f.close()
	return out

## The exported instance's UV (in the sanitized texture's frame) has to sample
## the same texel the source did — the crop must not shift the art.
func test_prop_atlas_region_is_cropped_without_moving_the_art() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var mi := MeshInstance3D.new()
	mi.name = "ImportedProp"
	var rect := Rect2(0.60, 0.40, 0.10, 0.08)
	_make_quad_uv(mi, rect)
	var mat := StandardMaterial3D.new()
	var src_tex := _make_gradient_texture(512, 512)
	mat.albedo_texture = src_tex
	mi.material_override = mat
	root.add_child(mi)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.max_texture_size = 512
	var tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(tree)
	autofree(tree)
	var exported := tree.get_node_or_null("ImportedProp") as MeshInstance3D
	assert_not_null(exported)
	var out_mat := exported.get_active_material(0) as StandardMaterial3D
	var out_img := out_mat.albedo_texture.get_image()
	assert_lt(out_img.get_width() * out_img.get_height(), 512 * 512,
		"A small atlas region must not ship the whole atlas")
	var uvs: PackedVector2Array = exported.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var src_uv := rect.position
	var out_uv := uvs[0]
	var src_px := src_tex.get_image().get_pixel(
		int(src_uv.x * 512.0), int(src_uv.y * 512.0))
	var out_px := out_img.get_pixel(
		int(out_uv.x * float(out_img.get_width())), int(out_uv.y * float(out_img.get_height())))
	assert_almost_eq(out_px.r, src_px.r, 0.08,
		"The remapped UV must sample the same texel: exported r=%.3f source r=%.3f (uv %s -> %s)"
			% [out_px.r, src_px.r, src_uv, out_uv])
	assert_almost_eq(out_px.g, src_px.g, 0.08, "…in both axes (v is not flipped)")

func test_prop_alpha_is_narrowed_to_what_its_pixels_need() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var mi := MeshInstance3D.new()
	mi.name = "GlassProp"
	_make_quad_uv(mi, Rect2(0, 0, 1, 1))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _make_gradient_texture(64, 64) # fully opaque art
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA # …declared as a blend
	mi.material_override = mat
	root.add_child(mi)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.max_texture_size = 512
	var tree := PBMapExporter.build_export_tree(root, settings)
	autofree(tree)
	var exported := tree.get_node_or_null("GlassProp") as MeshInstance3D
	assert_not_null(exported)
	var out_mat := exported.get_active_material(0) as StandardMaterial3D
	assert_eq(out_mat.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED,
		"Opaque pixels must not be drawn as a blended surface")

func test_nested_prop_keeps_its_placement() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	# A .glb dropped into a scene arrives as a wrapper node with the mesh under
	# it; the placement lives on the wrapper.
	var wrapper := Node3D.new()
	wrapper.name = "ImportedBarrel"
	wrapper.position = Vector3(3.0, 0.0, -2.0)
	wrapper.rotation.y = 0.5
	root.add_child(wrapper)
	var mi := MeshInstance3D.new()
	mi.name = "barrel"
	mi.scale = Vector3(0.75, 0.75, 0.75)
	var box := BoxMesh.new()
	mi.mesh = box
	wrapper.add_child(mi)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	var tree := PBMapExporter.build_export_tree(root, settings)
	autofree(tree)
	var exported := tree.get_node_or_null("barrel") as MeshInstance3D
	assert_not_null(exported, "The prop's mesh node is exported")
	var origin: Vector3 = PBMapExporter._get_world_transform(exported).origin
	assert_almost_eq(origin.x, 3.0, 0.001, "The wrapper's placement must reach the export")
	assert_almost_eq(origin.z, -2.0, 0.001, "…in world space, not the mesh's local space")

	# …and the .pbm route bakes the same transform into its vertices.
	var pbm_path := "user://test_nested_prop.pbm"
	if FileAccess.file_exists(pbm_path):
		DirAccess.remove_absolute(pbm_path)
	assert_eq(PBMapExporter.export_retro_pbm(root, pbm_path, settings), OK)
	var meshes := _read_pbm_meshes(pbm_path)
	assert_eq(meshes.size(), 1, "One prop, one mesh record")
	# The mesh record's bounds are world-space: a 0.75 m box centred on the
	# wrapper's origin. Reading them loose (half a metre) still separates
	# "placed at (3, -2)" from the bug it guards, which put it at (0, 0).
	var bounds: Array = meshes[0]["bounds"]
	assert_almost_eq((float(bounds[0]) + float(bounds[3])) * 0.5, 3.0, 0.5,
		"The PBM geometry must be baked in the prop's world position")
	assert_almost_eq((float(bounds[2]) + float(bounds[5])) * 0.5, -2.0, 0.5,
		"…not at the map origin")
	DirAccess.remove_absolute(pbm_path)

func test_prop_texture_survives_the_pbm_writer_without_atlasing() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var mi := MeshInstance3D.new()
	mi.name = "PackProp"
	_make_quad_uv(mi, Rect2(0, 0, 1, 1))
	var mat := StandardMaterial3D.new()
	# A 128x128 texture is the shape an asset pack ships all the time; it used
	# to be mistaken for a baked tile and packed into a TileAtlas slot, which
	# both destroyed its wrap and (RGB source into an RGBA atlas) dropped it.
	var img := Image.create(128, 128, false, Image.FORMAT_RGB8)
	img.fill(Color(0.8, 0.2, 0.1, 1.0))
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mi.material_override = mat
	root.add_child(mi)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.bake_textures = false
	var pbm_path := "user://test_pack_prop.pbm"
	# Straight through the PBM writer (the GLB->PBM converters are retired).
	var err := PBMapExporter.export_map(root, pbm_path, settings)
	assert_eq(err, OK)

	var textures := _read_pbm_textures(pbm_path)
	var prop_tex := -1
	for i in range(textures.size()):
		if String(textures[i]["name"]).begins_with("PackProp") or \
				(textures[i]["w"] == 128 and textures[i]["h"] == 128 and not String(textures[i]["name"]).begins_with("TileAtlas")):
			prop_tex = i
	assert_true(prop_tex >= 0,
		"A prop's own 128x128 texture must survive as a texture record, not be atlased: %s" % [textures])
	var meshes := _read_pbm_meshes(pbm_path)
	assert_eq(meshes.size(), 1)
	assert_eq(meshes[0]["tex"], prop_tex, "The prop's mesh must reference its own texture")

	DirAccess.remove_absolute(pbm_path)

func test_prop_instances_share_one_texture() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var shared := StandardMaterial3D.new()
	shared.albedo_texture = _make_gradient_texture(256, 256)
	for i in range(3):
		var mi := MeshInstance3D.new()
		mi.name = "Barrel%d" % i
		_make_quad_uv(mi, Rect2(0.1, 0.1, 0.5, 0.5))
		mi.material_override = shared
		mi.position = Vector3(float(i) * 0.5, 0.0, 0.0)
		root.add_child(mi)

	var settings := PBMapExporter.ExportSettings.new()
	settings.bake_lighting = false
	settings.max_texture_size = 512
	var pbm_path := "user://test_shared_prop_texture.pbm"
	if FileAccess.file_exists(pbm_path):
		DirAccess.remove_absolute(pbm_path)
	assert_eq(PBMapExporter.export_retro_pbm(root, pbm_path, settings), OK)
	var textures := _read_pbm_textures(pbm_path)
	assert_eq(textures.size(), 1,
		"Three instances of one prop cost one texture, got %s" % [textures])
	var meshes := _read_pbm_meshes(pbm_path)
	assert_eq(meshes.size(), 3)
	for m in meshes:
		assert_eq(m["tex"], 0, "Every instance must reference the shared texture")
	DirAccess.remove_absolute(pbm_path)

func test_modern_export_substitutes_splat_base_material() -> void:
	# GLTF cannot carry custom ShaderMaterials: a splat-painted face used to
	# export as an untextured default (paint AND base look lost). The modern
	# path now substitutes the splat base as a StandardMaterial3D.
	var root := Node3D.new()
	autofree(root)

	var floor_mesh := PBMesh.create_cube(4.0)
	floor_mesh.name = "SplatFloor"
	root.add_child(floor_mesh)

	var base_img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	base_img.fill(Color(0.2, 0.4, 0.8))
	var base_tex := ImageTexture.create_from_image(base_img)
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_texture = base_tex
	base_mat.albedo_color = Color(1, 1, 1)

	var md := floor_mesh.pb_mesh_data
	var top_face: PBFace = null
	var top_y := -INF
	for f in md.faces:
		if f == null:
			continue
		var idxs := f.get_distinct_indexes()
		var cy := 0.0
		for i in idxs:
			cy += md.positions[i].y
		if cy / idxs.size() > top_y:
			top_y = cy / idxs.size()
			top_face = f
	var splat_mat := PBSplat.create_splat_material(base_mat)
	md.set_face_material(top_face, splat_mat)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	settings.bake_lighting = false
	settings.export_colliders = false

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	var mi := export_tree.get_node_or_null("SplatFloor") as MeshInstance3D
	assert_not_null(mi)
	var found_base := false
	for s in range(mi.mesh.get_surface_count()):
		var mat: Material = mi.mesh.surface_get_material(s)
		if mat is ShaderMaterial:
			assert_true(false, "Modern export must not carry splat ShaderMaterials into GLTF surfaces")
			return
		if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture == base_tex:
			found_base = true
	assert_true(found_base, "Splat surface must export with its base albedo texture substituted")

func test_bake_pb_mesh_in_place_frees_uv2_for_lightmaps() -> void:
	var floor_mesh := PBMesh.create_cube(4.0)
	autofree(floor_mesh)
	floor_mesh.name = "BakeFloor"
	var md := floor_mesh.pb_mesh_data

	# Paint the top face: splat material + one green layer with a white center
	var top_face: PBFace = null
	var top_y := -INF
	for f in md.faces:
		if f == null:
			continue
		var idxs := f.get_distinct_indexes()
		var cy := 0.0
		for i in idxs:
			cy += md.positions[i].y
		if cy / idxs.size() > top_y:
			top_y = cy / idxs.size()
			top_face = f
	var checker := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	checker.fill(Color(0.5, 0.5, 0.5))
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_texture = ImageTexture.create_from_image(checker)
	var splat_mat := PBSplat.create_splat_material(base_mat)
	md.set_face_material(top_face, splat_mat)
	var layer_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	layer_img.fill(Color.GREEN)
	PBSplat.add_layer(splat_mat, ImageTexture.create_from_image(layer_img))
	PBSplat.paint_face_splat(md, top_face, splat_mat, 1, Vector3(0, top_y, 0), 0.4, 0.0, 1.0)

	var report := PBTileBaker.bake_pb_mesh_in_place(floor_mesh)
	assert_true(report["ok"], "Bake must succeed")
	assert_true(report["had_splat"], "Bake must report splat data was present")
	assert_gt(int(report["faces"]), 0, "Bake must produce baked faces")

	for f in md.faces:
		if f != null and f.splat_bounds.size() == 4:
			assert_true(false, "Baked faces must not carry splat_bounds")
			return
	for mat in md.materials:
		assert_false(PBSplat.is_splat_material(mat), "Baked materials must be plain StandardMaterial3D")
	assert_true(md.splat_uvs.is_empty(), "Splat mask coordinates must be gone after the bake")
	assert_true(md.textures1.is_empty(), "Precondition: this fixture had no authored UV2 to begin with")
	for f in md.faces:
		if f != null and not f.manual_uv:
			assert_true(false, "Baked faces must be manual_uv so rebuilds keep tile coordinates")
			return

	# The mesh still compiles, and rebuilds never move the baked tile UVs
	var am := md.to_array_mesh()
	assert_eq(am.get_surface_count(), md.materials.size(), "Baked mesh must compile one surface per material slot")
	var uv_snapshot := md.textures0.duplicate()
	floor_mesh.rebuild()
	assert_eq(md.textures0, uv_snapshot, "Rebuild must not move baked tile UVs")

	# Painted content survives into some baked tile (green pixels present)
	var found_paint := false
	for mat in md.materials:
		if mat is StandardMaterial3D:
			var tex: Texture2D = (mat as StandardMaterial3D).albedo_texture
			if tex == null or tex == base_mat.albedo_texture:
				continue
			var img := tex.get_image()
			if img == null:
				continue
			if img.is_compressed():
				img.decompress()
			for py in range(0, img.get_height(), 5):
				for px in range(0, img.get_width(), 5):
					var c := img.get_pixel(px, py)
					if c.g > 0.5 and c.r < 0.4:
						found_paint = true
	assert_true(found_paint, "A baked tile must contain the painted layer's green")

	# Second bake is a clean no-op
	var report2 := PBTileBaker.bake_pb_mesh_in_place(floor_mesh)
	assert_true(report2["ok"], "Second bake must succeed")
	assert_false(report2["had_splat"], "Second bake must find no splat data")

## BAKE mode (the default) composites the paint into a per-face texture and
## rewrites that face's UVs into mask space, so any glTF consumer shows it.
func test_modern_glb_bake_embeds_painted_pixels() -> void:
	var root := Node3D.new()
	autofree(root)

	var mesh_node := PBMesh.create_cube(2.0)
	mesh_node.name = "PaintedFloor"
	mesh_node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(mesh_node)

	var mesh_data := mesh_node.pb_mesh_data
	var face := mesh_data.faces[4] # top
	var center := Vector3.ZERO
	for idx in face.get_distinct_indexes():
		center += mesh_data.positions[idx]
	center /= float(face.get_distinct_indexes().size())

	var patch := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	patch.fill(Color(0.95, 0.1, 0.1, 1.0))
	assert_eq(PBSplat.paste_decal(mesh_data, center, Vector3.UP, 0.0, 1.2, 1.0, patch), 1,
			"Fixture: the decal must land on the top face")

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	settings.splat_mode = PBMapExporter.ExportSettings.SplatMode.BAKE
	settings.bake_lighting = false
	settings.export_colliders = false

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	var exported := export_tree.get_node_or_null("PaintedFloor") as MeshInstance3D
	assert_not_null(exported)
	var baked_surface := -1
	for s_i in range(exported.mesh.get_surface_count()):
		var m := exported.mesh.surface_get_material(s_i)
		if m is StandardMaterial3D and m.resource_name.begins_with("BakedSplat"):
			baked_surface = s_i
			break
	assert_true(baked_surface >= 0, "The painted face must export as a baked texture surface")
	if baked_surface < 0:
		return

	var baked_mat := exported.mesh.surface_get_material(baked_surface) as StandardMaterial3D
	var img := baked_mat.albedo_texture.get_image()
	var px := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	assert_almost_eq(px.r, 0.95, 0.08, "Baked texels must carry the painted color")
	assert_almost_eq(px.g, 0.1, 0.08, "…and not the base material's color")

	# UVs of that surface must be inside the baked texture (mask space).
	var arrays: Array = exported.mesh.surface_get_arrays(baked_surface)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	assert_gt(uvs.size(), 0, "Baked surface must carry UVs")
	for uv in uvs:
		if uv.x < -0.001 or uv.x > 1.001 or uv.y < -0.001 or uv.y > 1.001:
			assert_true(false, "Baked UVs must land inside the mask-space texture")
			break


## INCLUDE mode ships the live splat stack: geometry keeps its mask coordinates
## (CUSTOM0 -> TEXCOORD_2 -> CUSTOM0), each painted face's material carries a
## `poi_splat` record, and the masks/decal ride as sidecar PNGs. The round trip
## must reproduce the painted pixels.
## Modulate-2x: settings.bake_boost multiplies the baked vertex colors
## (saturating at 1.0) in the retro export tree — brighter shadows and
## mid-tones, sunlit areas ride the clamp.
func test_bake_boost_multiplies_vertex_colors() -> void:
	var root := Node3D.new()
	autofree(root)
	var floor_mesh := PBMesh.create_cube(4.0)
	floor_mesh.name = "Floor"
	root.add_child(floor_mesh)
	var light := OmniLight3D.new()
	light.position = Vector3(0, 2.5, 0)
	light.omni_range = 8.0
	root.add_child(light)

	var baked_colors := func(boost: float) -> PackedColorArray:
		var settings := PBMapExporter.ExportSettings.new()
		settings.export_mode = PBMapExporter.ExportMode.RETRO
		settings.bake_boost = boost
		settings.export_colliders = false
		settings.export_billboards = false
		var tree := PBMapExporter.build_export_tree(root, settings)
		autofree(tree)
		var exported := tree.get_node_or_null("Floor") as MeshInstance3D
		var arrays: Array = exported.mesh.surface_get_arrays(0)
		return arrays[Mesh.ARRAY_COLOR]

	var plain: PackedColorArray = baked_colors.call(1.0)
	var boosted: PackedColorArray = baked_colors.call(2.0)
	assert_eq(plain.size(), boosted.size(), "Same vertex count")
	var plain_sum := 0.0
	var expected_boosted_sum := 0.0
	for i in range(plain.size()):
		var pcol := plain[i]
		var pm := (pcol.r + pcol.g + pcol.b) / 3.0
		plain_sum += pm
		# The expected boost: per-component multiply with saturate.
		expected_boosted_sum += (minf(pcol.r * 2.0, 1.0) + minf(pcol.g * 2.0, 1.0) \
			+ minf(pcol.b * 2.0, 1.0)) / 3.0
	var plain_mean := plain_sum / plain.size()
	var expected_mean := expected_boosted_sum / boosted.size()
	var boosted_mean := 0.0
	var max_component := 0.0
	for c in boosted:
		boosted_mean += (c.r + c.g + c.b) / 3.0
		max_component = maxf(max_component, maxf(c.r, maxf(c.g, c.b)))
	boosted_mean /= boosted.size()
	assert_gt(plain_mean, 0.0, "Fixture: the bake must produce light")
	assert_almost_eq(boosted_mean, expected_mean, 0.02,
			"Bake boost must multiply the baked colors per-component (saturating)")
	assert_true(max_component <= 1.0001, "Boosted colors must stay clamped at 1.0")
	assert_eq(PBMapExporter.ExportSettings.new().bake_boost, 2.0,
			"Modulate-2x must be the default")

## glTF lights cannot carry shadows, so a shadow-casting light tags its export
## node with `extras.poi_shadow` — and the tag survives a GLB round trip, so a
## consumer (the frame bench, a Godot re-import) can restore the authored look.
func test_shadowed_lights_export_poi_shadow_extras() -> void:
	var root := Node3D.new()
	autofree(root)

	var shadowed := OmniLight3D.new()
	shadowed.name = "ShadowedLight"
	shadowed.shadow_enabled = true
	root.add_child(shadowed)
	var plain := OmniLight3D.new()
	plain.name = "PlainLight"
	plain.shadow_enabled = false
	root.add_child(plain)
	# A mesh so the GLB carries real buffer data — a lights-only scene parses
	# with an empty-buffer engine error, which GUT counts as a failure.
	var box := MeshInstance3D.new()
	box.name = "Box"
	box.mesh = BoxMesh.new()
	root.add_child(box)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	settings.bake_lighting = false
	settings.export_colliders = false
	settings.export_billboards = false

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)
	var exported_shadowed := export_tree.get_node_or_null("ShadowedLight") as OmniLight3D
	var exported_plain := export_tree.get_node_or_null("PlainLight") as OmniLight3D
	assert_not_null(exported_shadowed)
	assert_not_null(exported_plain)
	if exported_shadowed != null:
		assert_true(exported_shadowed.has_meta("extras") \
				and (exported_shadowed.get_meta("extras") as Dictionary).get("poi_shadow", false),
				"A shadow-casting light must tag its export node with poi_shadow")
	if exported_plain != null:
		assert_false(exported_plain.has_meta("extras") \
				and (exported_plain.get_meta("extras") as Dictionary).has("poi_shadow"),
				"A non-shadow light must not claim poi_shadow")

	# Round trip: the extras ride the glTF node JSON and come back as node meta.
	var out_path := "user://test_light_shadow_extras.glb"
	var err := PBMapExporter.export_map(root, out_path, settings)
	assert_eq(err, OK, "GLB export with lights must succeed")
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var lerr := doc.append_from_file(out_path, state)
	assert_eq(lerr, OK, "Re-import must succeed")
	if lerr != OK:
		return
	var scene := doc.generate_scene(state)
	autofree(scene)
	var came_back := _find_light_recursive(scene, "ShadowedLight")
	assert_not_null(came_back, "The shadowed light must survive the round trip")
	if came_back != null:
		assert_true(came_back.has_meta("extras") \
				and (came_back.get_meta("extras") as Dictionary).get("poi_shadow", false),
				"The poi_shadow tag must ride the round trip as node extras")

func _find_light_recursive(node: Node, light_name: String) -> Light3D:
	if node is Light3D and node.name.begins_with(light_name):
		return node as Light3D
	for c in node.get_children():
		var hit := _find_light_recursive(c, light_name)
		if hit != null:
			return hit
	return null


func test_modern_glb_include_roundtrip_reproduces_paint() -> void:
	var root := Node3D.new()
	autofree(root)

	var floor_mesh := PBMesh.create_cube(2.0)
	floor_mesh.name = "SplatFloor"
	root.add_child(floor_mesh)

	var mesh_data := floor_mesh.pb_mesh_data
	var patch := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	patch.fill(Color(0.2, 0.4, 0.95, 1.0))
	var face := mesh_data.faces[4] # top
	var center := Vector3.ZERO
	for idx in face.get_distinct_indexes():
		center += mesh_data.positions[idx]
	center /= float(face.get_distinct_indexes().size())
	var painted := PBSplat.paste_decal(mesh_data, center, Vector3.UP, 0.0, 0.8, 1.0, patch)
	assert_eq(painted, 1, "Fixture: the decal must land on the top face")
	var mat := mesh_data.get_face_material(face) as ShaderMaterial
	var decal := PBSplat.get_decal_layer_image(mat)
	var mid := decal.get_width() / 2
	var alpha_before := decal.get_pixel(mid, mid).a
	assert_gt(alpha_before, 0.5, "Fixture: the decal layer must hold pixels")

	var out_path := "user://test_splat_include.glb"
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	settings.splat_mode = PBMapExporter.ExportSettings.SplatMode.INCLUDE
	settings.bake_lighting = false
	settings.export_colliders = false

	var err := PBMapExporter.export_map(root, out_path, settings)
	assert_eq(err, OK, "Modern INCLUDE export must succeed")

	var sidecar_dir := out_path.get_basename() + ".splat"
	assert_true(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(sidecar_dir)),
			"INCLUDE export must write its sidecar folder")
	var sidecar_files := DirAccess.get_files_at(sidecar_dir)
	var has_decal_png := false
	for f in sidecar_files:
		if f.ends_with("_decal.png"):
			has_decal_png = true
	assert_true(has_decal_png, "The decal channel must ship as a sidecar PNG")

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var lerr := doc.append_from_file(out_path, state)
	assert_eq(lerr, OK, "Re-import of the INCLUDE .glb must succeed")
	if lerr != OK:
		return
	var scene := doc.generate_scene(state)
	autofree(scene)

	var imported := scene.get_node_or_null("SplatFloor") as MeshInstance3D
	assert_not_null(imported, "Floor must survive the round trip")
	if imported == null:
		return

	# CUSTOM0 must come back from TEXCOORD_2 on every surface that carries it.
	var custom_found := false
	var record_found := false
	for s_i in range(imported.mesh.get_surface_count()):
		if (imported.mesh.surface_get_format(s_i) & Mesh.ARRAY_FORMAT_CUSTOM0) != 0:
			custom_found = true
		var surface_mat := imported.mesh.surface_get_material(s_i)
		if surface_mat != null and surface_mat.has_meta("extras"):
			var extras = surface_mat.get_meta("extras")
			if extras is Dictionary and (extras as Dictionary).has("poi_splat"):
				record_found = true
	assert_true(custom_found, "Mask coordinates must round-trip as CUSTOM0 (via TEXCOORD_2)")
	assert_true(record_found, "The poi_splat record must ride on the painted face's material extras")

	# …and the documented loader rebuilds a live, painted splat material.
	var rebuilt := PBSplatImport.rebuild_from_extras(scene, out_path)
	assert_gt(rebuilt, 0, "PBSplatImport must rebuild at least one splat material")
	var rebuilt_mat: ShaderMaterial = null
	for s_i in range(imported.mesh.get_surface_count()):
		var m := imported.get_surface_override_material(s_i)
		if PBSplat.is_splat_material(m):
			rebuilt_mat = m
			break
	assert_not_null(rebuilt_mat, "The rebuilt surface must carry a splat material")
	if rebuilt_mat == null:
		return
	assert_true(PBSplat.has_decal_layer(rebuilt_mat), "The rebuilt material must carry the decal layer")
	var rebuilt_decal := PBSplat.get_decal_layer_image(rebuilt_mat)
	assert_almost_eq(rebuilt_decal.get_pixel(rebuilt_decal.get_width() / 2, rebuilt_decal.get_height() / 2).a,
			alpha_before, 0.02, "The rebuilt decal must hold the exported pixels")
func test_async_export_routes_pbm_extension() -> void:
	# The dialog's path (async entry) must honor .pbm — it used to only write
	# GLB, leaving the PSP format unreachable from the UI.
	var root := Node3D.new()
	autofree(root)
	var cube := PBMesh.create_cube(2.0)
	cube.name = "AsyncPbmCube"
	root.add_child(cube)

	var out_path := "user://test_async_export.pbm"
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.bake_lighting = false
	var err: Error = await PBMapExporter.export_map_async(root, out_path, settings)
	assert_eq(err, OK, "Async .pbm export must route to the retro PBM writer")
	assert_true(FileAccess.file_exists(out_path), "Async .pbm export must write the file")
	var f := FileAccess.open(out_path, FileAccess.READ)
	assert_not_null(f)
	if f != null:
		var magic := f.get_32()
		assert_eq(magic, PBMapExporter.PBM_MAGIC, "Async export must produce a real PBM3 file")

func test_export_dialog_defaults_to_pbm() -> void:
	var dialog := PBExportDialog.new()
	autofree(dialog)
	assert_eq(dialog._mode_option.selected, 0, "PBM must be the default format")
	assert_true(dialog._txt_path.text.ends_with(".pbm"), "Default path must be .pbm")

	# The MODERN bake is the first GLB flavor (the one to play/ship on the
	# modern pipeline); the retro GLB follows it.
	assert_eq(dialog._mode_option.get_item_id(1), dialog.FORMAT_MODERN_GLB,
			"Modern Bake must be the first GLB flavor in the list")
	assert_eq(dialog._mode_option.get_item_id(2), dialog.FORMAT_RETRO_GLB,
			"Retro Baked Map must follow the Modern Bake")

	# Switching to the modern GLB flavor swaps the extension, relaxes the
	# retro bake toggles AND defaults to the optimized bake: paint baked into
	# textures, no vertex lighting (realtime lights / LightmapGI stay in
	# charge). Switching back restores .pbm.
	dialog._mode_option.select(1)
	dialog._on_mode_selected(1)
	assert_eq(dialog._mode_option.get_selected_id(), dialog.FORMAT_MODERN_GLB,
			"Modern GLB flavor must be selectable")
	assert_true(dialog._txt_path.text.ends_with(".glb"), "Modern flavor must swap the path to .glb")
	assert_false(dialog._chk_subdivide.button_pressed, "Modern flavor must not force grid subdivision")
	assert_false(dialog._chk_bake_lighting.button_pressed, "Modern flavor must not bake vertex lighting")
	assert_eq(dialog._opt_splat_mode.get_selected_id(),
			PBMapExporter.ExportSettings.SplatMode.BAKE,
			"Selecting the modern flavor must default the paint mode to Bake")
	# ...and a deliberate INCLUDE choice resets to Bake when the flavor is
	# re-picked, so the flavor switch always lands on the optimized bake.
	dialog._opt_splat_mode.select(PBMapExporter.ExportSettings.SplatMode.INCLUDE)
	dialog._mode_option.select(1)
	dialog._on_mode_selected(1)
	assert_eq(dialog._opt_splat_mode.get_selected_id(),
			PBMapExporter.ExportSettings.SplatMode.BAKE,
			"Re-picking the modern flavor must reset the paint mode to Bake")
	dialog._mode_option.select(0)
	dialog._on_mode_selected(0)
	assert_true(dialog._txt_path.text.ends_with(".pbm"), "PBM flavor must swap the path back to .pbm")
	assert_true(dialog._chk_bake_lighting.button_pressed, "PBM flavor restores the retro bake toggles")
	assert_eq(dialog._mode_option.get_item_id(2), dialog.FORMAT_RETRO_GLB,
			"Retro flavor stays selectable after the round trip")
	dialog._mode_option.select(2)
	dialog._on_mode_selected(2)
	assert_true(dialog._chk_bake_lighting.button_pressed, "Retro GLB flavor carries the vertex-light bake")
	assert_true(dialog._opt_splat_mode.disabled, "The modern paint switch must be inert for the retro flavors")

func test_editor_tool_meshes_are_never_exported() -> void:
	# The sprite raise guide (ImmediateMesh line art) lives in the live scene;
	# exporting it reads its vertices as a triangle soup of arbitrary winding —
	# the "flipped windings on the PSP" regression.
	var root := Node3D.new()
	autofree(root)

	var floor_mesh := PBMesh.create_cube(2.0)
	floor_mesh.name = "Floor"
	root.add_child(floor_mesh)

	var guide := MeshInstance3D.new()
	guide.name = "RaiseGuideLine"
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(Vector3(1, 0, 1))
	im.surface_add_vertex(Vector3(1, 0.4, 1))
	im.surface_end()
	guide.mesh = im
	root.add_child(guide)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.export_colliders = false

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	var mis := export_tree.find_children("*", "MeshInstance3D", true, false)
	assert_eq(mis.size(), 1, "Only the floor's baked mesh may export")
	for mi in mis:
		var mi3d := mi as MeshInstance3D
		assert_false(mi3d.mesh is ImmediateMesh, "No ImmediateMesh may enter the export tree")
		assert_false(mi3d.name.begins_with("RaiseGuideLine"),
				"Editor tool meshes must not export")

func test_pbm_triangle_winding_matches_oracle() -> void:
	# The PSP GU runs GU_CCW over a y-down framebuffer: front faces must be
	# stored CCW-from-outward ("outward-up" for top faces), matching the
	# device-verified oracle converter. The direct writer used to emit Godot's
	# CW order — the whole map rendered inside-out on the PSP.
	var root := Node3D.new()
	autofree(root)
	var cube := PBMesh.create_cube(2.0)
	cube.name = "WindingCube"
	root.add_child(cube)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.bake_lighting = false
	settings.export_colliders = false
	var out_path := "user://test_winding.pbm"
	var err: Error = await PBMapExporter.export_map_async(root, out_path, settings)
	assert_eq(err, OK, "PBM export must succeed")
	if err != OK:
		return

	var f := FileAccess.open(out_path, FileAccess.READ)
	assert_not_null(f)
	var magic := f.get_32()
	assert_eq(magic, PBMapExporter.PBM_MAGIC, "Must be a PBM3 file")
	var ver := f.get_32()
	var n_tex := f.get_32()
	var n_mesh := f.get_32()
	var n_col := f.get_32()
	var n_meta := f.get_32()
	var spawn := Vector3(f.get_float(), f.get_float(), f.get_float())
	var bmin := Vector3(f.get_float(), f.get_float(), f.get_float())
	var bmax := Vector3(f.get_float(), f.get_float(), f.get_float())
	var mesh_hdr := 72 if ver >= 3 else 64
	var off := 64
	for t in range(n_tex):
		# Texture header: name[32] + width(2) + height(2) + format(2) +
		# alpha_mode(2) = 40, then the 4-byte data size at +40. Reading +36
		# (height+format) made every subsequent offset garbage, and the mesh
		# parse below appended vertices against a garbage count — a runaway
		# that ballooned to 15+ GB of RAM.
		f.seek(off + 40) # data size sits at +40 inside the 44-byte texture header
		var dsz := f.get_32()
		off += 44 + dsz
	var top_up := 0
	var top_down := 0
	for mi in range(n_mesh):
		f.seek(off + 36) # vertex count sits at +36 inside the mesh header
		var nv := f.get_32() as int
		f.seek(off)
		var verts: Array[Vector3] = []
		for vi in range(nv):
			# PbmVertex device order (pbm.h): u, v, color, THEN x, y, z.
			# Reading position-first parsed UVs as coordinates and the winding
			# checks below ran against garbage.
			f.get_float(); f.get_float(); f.get_32() # uv (2 floats) + baked color
			var x := f.get_float(); var y := f.get_float(); var z := f.get_float()
			verts.append(Vector3(x, y, z))
		var ymax := -INF
		for v in verts:
			ymax = maxf(ymax, v.y)
		for ti in range(0, nv - 2, 3):
			var a := verts[ti]; var b := verts[ti + 1]; var c := verts[ti + 2]
			if absf(a.y - ymax) > 0.01 or absf(b.y - ymax) > 0.01 or absf(c.y - ymax) > 0.01:
				continue
			var n := (b - a).cross(c - a)
			if n.length() < 1e-9:
				continue
			if n.normalized().y > 0.9:
				top_up += 1
			elif n.normalized().y < -0.9:
				top_down += 1
		off += mesh_hdr + nv * 24
	assert_gt(top_up + top_down, 0, "Must find the cube's top-face triangles")
	assert_eq(top_down, 0, "PBM top faces must be stored outward-up (CCW), never inward-down")
	assert_gt(top_up, 0, "PBM top faces must be outward-up (oracle convention)")
	# Header sanity while we are here: bounds must reflect the actual geometry
	assert_almost_eq(bmax.y, 1.0, 0.01, "Cube top at +1 m")
	assert_almost_eq(bmin.y, -1.0, 0.01, "Cube bottom at -1 m")
	assert_true(spawn.z > bmax.z, "Default spawn sits beyond the far edge")

## Regression ("upside-down tree on the PSP"): a billboard authored with its
## up axis pointing DOWN looks upright in the editor (BILLBOARD_FIXED_Y
## rebuilds the basis from world up + camera) but bakes with the authored
## transform — hanging into the floor. The bake must un-flip it.
func test_billboard_upside_down_basis_is_unflipped_for_bake() -> void:
	var root := Node3D.new()
	autofree(root)

	var flipped := MeshInstance3D.new()
	flipped.name = "SpriteFlipped"
	flipped.set_meta("is_billboard", true)
	flipped.mesh = QuadMesh.new()
	# What a backface/inward-wound placement pick produced pre-fix: a basis
	# whose up column points below the horizon.
	flipped.transform = Transform3D(
		Basis(Vector3(-0.869, 0, 0.494), Vector3(0, -1, 0), Vector3(0.494, 0, 0.869)),
		Vector3(1.0, -0.4, 2.0))
	root.add_child(flipped)

	var upright := MeshInstance3D.new()
	upright.name = "SpriteUpright"
	upright.set_meta("is_billboard", true)
	upright.mesh = QuadMesh.new()
	root.add_child(upright)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.export_billboards = true
	settings.bake_lighting = false

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	var bb := export_tree.get_node_or_null("SpriteFlipped") as MeshInstance3D
	assert_not_null(bb, "Exported tree must contain 'SpriteFlipped'")
	assert_gt(bb.transform.basis.y.y, 0.0, "Flipped billboard basis must be un-flipped: up axis points up after bake")
	assert_gt(bb.transform.basis.determinant(), 0.0, "Un-flip must stay a proper rotation (no mirroring)")
	assert_almost_eq(bb.transform.origin.y, -0.4, 0.001, "The anchor/pivot is preserved")

	var ub := export_tree.get_node_or_null("SpriteUpright") as MeshInstance3D
	assert_not_null(ub, "Exported tree must contain 'SpriteUpright'")
	assert_almost_eq(ub.transform.basis.y.y, 1.0, 0.001, "Upright billboard passes through untouched")

## Regression: a Node3D named "Spawn" must reach the PBM binary HEADER — the
## PSP engine spawns from header spawn_pos/spawn_rot, not from the
## player_spawn metadata tag.
func test_pbm_header_spawn_honors_spawn_node() -> void:
	var root := Node3D.new()
	autofree(root)

	var cube := PBMesh.create_cube(2.0)
	cube.name = "Floor"
	root.add_child(cube)

	var spawn := Node3D.new()
	spawn.name = "Spawn"
	spawn.transform = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(1.5, 0.8, 2.5))
	root.add_child(spawn)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.bake_lighting = false
	settings.export_colliders = false
	var out_path := "user://test_spawn_header.pbm"
	var err: Error = await PBMapExporter.export_map_async(root, out_path, settings)
	assert_eq(err, OK, "PBM export must succeed")
	if err != OK:
		return

	var f := FileAccess.open(out_path, FileAccess.READ)
	assert_not_null(f)
	if f == null:
		return
	for i in range(6):
		f.get_32() # magic, version, texture/mesh/collider/meta counts
	var hx := f.get_float()
	var hy := f.get_float()
	var hz := f.get_float()
	var hyaw := f.get_float()
	assert_almost_eq(hx, 1.5, 0.001, "Header spawn X must come from the Spawn node")
	assert_almost_eq(hy, 0.8, 0.001, "Header spawn Y must come from the Spawn node")
	assert_almost_eq(hz, 2.5, 0.001, "Header spawn Z must come from the Spawn node")
	assert_almost_eq(wrapf(hyaw, -PI, PI), PI * 0.5, 0.01, "Header spawn yaw must come from the Spawn node")

## Godot's ArrayMesh refuses a 257th surface — and it only LOGS the refusal, so
## every surface past the cap was silently dropped from the exported map. The
## retro bake makes one surface per painted tile, and a large painted floor is
## hundreds: on a real 60 m painted floor the export tree came out as a single
## 256-surface node and ~70 errors, with most of the paint missing from the
## device. Surfaces now pour into as many nodes as it takes.
func test_export_surfaces_are_chunked_below_the_godot_cap() -> void:
	var chunker := PBMapExporter.SurfaceChunker.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var surfaces := PBMapExporter.MAX_SURFACES_PER_EXPORT_MESH * 2 + 5
	for i in range(surfaces):
		chunker.add(arrays, null)
	chunker.flush()
	assert_eq(chunker.meshes.size(), 3, "Two full meshes and a remainder")
	var total := 0
	for m in chunker.meshes:
		assert_lte(m.get_surface_count(), PBMapExporter.MAX_SURFACES_PER_EXPORT_MESH,
			"No mesh may reach Godot's 256-surface cap")
		total += m.get_surface_count()
	assert_eq(total, surfaces, "Every surface lands, none is dropped")
	assert_lt(PBMapExporter.MAX_SURFACES_PER_EXPORT_MESH, 256,
		"The chunk size stays under Godot's cap with headroom")

	# The nodes carry the same name plus an index, and the geometry is real.
	var root := Node3D.new()
	autofree(root)
	PBMapExporter._attach_meshes(root, "Floor", Transform3D.IDENTITY, chunker.meshes)
	assert_eq(root.get_child_count(), 3)
	assert_eq(String(root.get_child(0).name), "Floor")
	assert_eq(String(root.get_child(1).name), "Floor_2")
	assert_eq(String(root.get_child(2).name), "Floor_3")
	for child in root.get_children():
		var mi := child as MeshInstance3D
		assert_eq(mi.mesh.get_surface_count(), mi.mesh.get_surface_count())
		assert_true(mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] != null,
			"A chunk keeps its geometry")
