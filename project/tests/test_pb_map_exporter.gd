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

	# Add stamp child
	var stamps := Node3D.new()
	stamps.name = "PBStamps"
	cube.add_child(stamps)
	var stamp := MeshInstance3D.new()
	stamp.name = "Stamp_0"
	stamp.set_meta("face_idx", 0)
	stamp.set_meta("stamp_texture_path", "res://addons/poibuilder/materials/textures/flower_patch.png")
	stamp.set_meta("anchor_center", Vector2(0, 0))
	stamp.set_meta("anchor_du", Vector2(0.1, 0.0))
	stamp.set_meta("anchor_dv", Vector2(0.0, 0.1))
	stamps.add_child(stamp)
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	settings.bake_lighting = false
	settings.export_colliders = true

	var export_tree := PBMapExporter.build_export_tree(root, settings)
	assert_not_null(export_tree)
	autofree(export_tree)

	var cube_node := export_tree.get_node_or_null("ModernCube") as MeshInstance3D
	assert_not_null(cube_node)
	assert_true(cube_node.has_meta("poi_stamps"), "Modern export should attach poi_stamps metadata")

	var stamps_node := cube_node.get_node_or_null("PBStamps")
	assert_not_null(stamps_node, "Modern export should preserve PBStamps container")
	assert_not_null(stamps_node.get_node_or_null("Stamp_0"), "Modern export should preserve decal quads")

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

func test_prop_texture_survives_glb_to_pbm_without_atlasing() -> void:
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
	var glb_path := "user://test_pack_prop.glb"
	var pbm_path := "user://test_pack_prop.pbm"
	var err := PBMapExporter.export_map(root, glb_path, settings)
	assert_eq(err, OK)
	assert_eq(PBPbmConverter.convert_glb_to_pbm(glb_path, pbm_path, true), OK)

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

	DirAccess.remove_absolute(glb_path)
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
