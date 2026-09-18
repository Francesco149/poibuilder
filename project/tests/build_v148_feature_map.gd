## Builds the v0.9.148 feature-verification map and exports it as a .pbm for
## the PSP. Exercises everything this round adds on the device path:
##   - a blended water plane (auto-detected soft alpha)
##   - a foliage billboard (auto-detected cutout alpha)
##   - a face dimmed to 50% via vertex-color alpha (the Opacity slider)
##   - a billboard dimmed to 40% via its material albedo alpha
##   - two emitters built exactly like the Particles tab's presets
##     (additive flame + blended upright smoke)
## Run headless:
##   godot-mono --headless -s tests/build_v148_feature_map.gd
extends SceneTree

func _init() -> void:
	_build.call_deferred()

func _build() -> void:
	var root := Node3D.new()
	root.name = "FeatureMap"

	# Floor: an opaque brick plane to stand on (and behind which opacity shows).
	var floor_mesh := PBMesh.new()
	floor_mesh.pb_mesh_data = PBShapeFactory.create_shape(&"cube", Vector3(8, 0.2, 8))
	floor_mesh.name = "Floor"
	floor_mesh.position = Vector3(4, -0.1, 4)
	floor_mesh.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(floor_mesh)

	# 1. Blended water plane (auto-detected soft alpha from water_pool.png).
	var water_path := "res://addons/poibuilder/materials/textures/water_pool.png"
	var water := PBMesh.new()
	water.name = "WaterPlane"
	var wmd := PBShapeGenerators.create_plane(4.0, 4.0)
	var wmat := StandardMaterial3D.new()
	if ResourceLoader.exists(water_path):
		wmat.albedo_texture = load(water_path)
	wmat.roughness = 0.8
	wmat.vertex_color_use_as_albedo = true
	wmat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	PBAlphaDetect.ensure_transparency(wmat)
	PBUv.set_scroll_speed(wmat, Vector2(0.18, 0.0))
	wmd.materials = [wmat]
	for f in range(wmd.faces.size()):
		wmd.faces[f].manual_uv = false
	water.pb_mesh_data = wmd
	water.position = Vector3(2, 0.05, 2)
	root.add_child(water)

	# 2. A wall whose front face is dimmed to 50% (vertex-color alpha; the
	#    exporter must carry it into the baked vertex colors and the material
	#    must blend for the device to honor it).
	var wall := PBMesh.new()
	wall.name = "OpacityWall"
	wall.pb_mesh_data = PBShapeFactory.create_shape(&"cube", Vector3(2.0, 1.0, 3.0))
	wall.position = Vector3(6, 0.5, 3)
	root.add_child(wall)
	var wall_data := wall.pb_mesh_data
	wall_data.colors.resize(wall_data.positions.size())
	wall_data.colors.fill(Color(1, 1, 1, 1))
	var wsmat := StandardMaterial3D.new()
	# Deliberately UNTEXTURED white: the A/B below must show ONLY the opacity
	# difference (texture brightness and blend-backdrop tricks muddy it).
	wsmat.roughness = 0.9
	wsmat.vertex_color_use_as_albedo = true
	# DIAGNOSTIC: dim BOTH +-X faces to 50% with the blend material — if the
	# frame shows GRAY the face is drawn and blended; if it shows BRIGHT WHITE
	# we are seeing the opposite (untouched) face through a culled one.
	var blend_faces: Array[PBFace] = []
	for fi in range(wall_data.faces.size()):
		var face := wall_data.faces[fi]
		var n := PBMath.normal_from_positions(
			wall_data.positions, face.get_indexes()).normalized()
		if absf(n.dot(Vector3(1, 0, 0))) > 0.9:
			blend_faces.append(face)
			for idx in face.get_distinct_indexes():
				var c := wall_data.colors[idx]
				c.a = 0.5
				wall_data.colors[idx] = c
	var dup: StandardMaterial3D = wsmat.duplicate()
	dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wall_data.set_faces_material(blend_faces, dup)
	for fi in range(wall_data.faces.size()):
		if wall_data.faces[fi] not in blend_faces:
			wall_data.set_faces_material([wall_data.faces[fi]], wsmat)

	# 3. A foliage billboard at 100% (cutout alpha) next to a dimmed one
	#    (albedo alpha 0.4 — the billboard opacity path).
	var leaf_path := "res://addons/poibuilder/materials/textures/bush_foliage.png"
	for i in range(2):
		var bush := MeshInstance3D.new()
		bush.name = "Bush%d" % i
		bush.set_meta("is_billboard", true)
		var quad := QuadMesh.new()
		quad.size = Vector2(1.2, 1.2)
		var bmat := StandardMaterial3D.new()
		if ResourceLoader.exists(leaf_path):
			bmat.albedo_texture = load(leaf_path)
		bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		bmat.albedo_color = Color(1, 1, 1, 1.0 if i == 0 else 0.4)
		bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		quad.material = bmat
		bush.mesh = quad
		bush.position = Vector3(2 + i * 1.4, 0.6, 0.4)
		root.add_child(bush)

	# 4. Emitters built by the Particles tab's own presets (not hand-rolled):
	#    additive flame + blended upright smoke.
	var flame_values := PBParticleParams.preset_for_texture("particle_flame")
	var flame := PBParticleParams.build_node(
		load("res://addons/poibuilder/materials/textures/particle_flame_2x2_sheet.png")
		if ResourceLoader.exists("res://addons/poibuilder/materials/textures/particle_flame_2x2_sheet.png") else null,
		flame_values, "Emitter_Flame")
	flame.position = Vector3(2, 1.1, 2)
	root.add_child(flame)

	var smoke_values := PBParticleParams.preset_for_texture("particle_smoke")
	var smoke := PBParticleParams.build_node(
		load("res://addons/poibuilder/materials/textures/particle_smoke.png")
		if ResourceLoader.exists("res://addons/poibuilder/materials/textures/particle_smoke.png") else null,
		smoke_values, "Emitter_Smoke")
	smoke.position = Vector3(4.5, 1.3, 2)
	root.add_child(smoke)

	# One sun aimed with look_at (euler-guessproof): from high +X straight at
	# the walls' east faces, plus a brighter ambient so the A/B reads.
	var sun := DirectionalLight3D.new()
	sun.position = Vector3(30, 14, 3)
	sun.basis = Basis.looking_at(Vector3(-0.906, -0.423, 0.0).normalized(), Vector3.UP)
	root.add_child(sun)

	# A solid twin of the opacity wall: same texture, same light, no alpha —
	# one screen shows the A/B.
	var solid_wall := PBMesh.new()
	solid_wall.name = "SolidWall"
	solid_wall.pb_mesh_data = PBShapeFactory.create_shape(&"cube", Vector3(2.0, 1.0, 3.0))
	solid_wall.position = Vector3(6, 0.5, 7.0)
	root.add_child(solid_wall)
	var solid_data := solid_wall.pb_mesh_data
	solid_data.colors.resize(solid_data.positions.size())
	solid_data.colors.fill(Color(1, 1, 1, 1))
	for fi in range(solid_data.faces.size()):
		solid_data.set_faces_material([solid_data.faces[fi]], wsmat)

	# Spawn east of both walls; yaw PI/2 faces -X (forward = (-sin, 0, -cos)): the 50% face (z=3) and its solid
	# twin (z=7) side by side.
	var spawn := Node3D.new()
	spawn.name = "Spawn"
	spawn.position = Vector3(8.7, 0.9, 3.0)
	spawn.rotation.y = PI / 2.0
	root.add_child(spawn)

	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.RETRO
	settings.subdivide_quads = true
	settings.bake_lighting = true
	settings.bake_shadows = true
	settings.bake_textures = true
	settings.export_colliders = true
	settings.export_billboards = true
	settings.ambient_color = Color(0.8, 0.8, 0.85)

	var out := "/tmp/poibuilder_scratch/exports/feature_v148.pbm"
	DirAccess.make_dir_recursive_absolute("/tmp/poibuilder_scratch/exports")
	var err := PBMapExporter.export_retro_pbm(root, out, settings)
	print("EXPORT err=%d -> %s (%d bytes)" % [err, out,
		FileAccess.file_exists(out) if false else 0])
	var f := FileAccess.open(out, FileAccess.READ)
	if f != null:
		print("EXPORT size=%d" % f.get_length())
		f.close()
	quit(0 if err == OK else 1)
