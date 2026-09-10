## TestMapShowcaseBuilder — Programmatically generates a showcase map scene with
## diverse geometry, splatting, stamps, billboards, lights, and colliders, and exports it.
@tool
class_name TestMapShowcaseBuilder
extends RefCounted

static func build_showcase_scene(include_player: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "ShowcaseMap"

	# ==========================================================================
	# 0. World Environment & Sky
	# ==========================================================================
	var env_node := WorldEnvironment.new()
	env_node.name = "WorldEnvironment"
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.45, 0.55, 1.0)
	sky_mat.sky_horizon_color = Color(0.65, 0.70, 0.75, 1.0)
	sky_mat.ground_bottom_color = Color(0.15, 0.15, 0.18, 1.0)
	sky_mat.ground_horizon_color = Color(0.65, 0.70, 0.75, 1.0)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.3, 0.3, 0.35, 1.0)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = env
	root.add_child(env_node)

	# ==========================================================================
	# 1. Lighting
	# ==========================================================================
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.transform = Transform3D(Basis.looking_at(Vector3(0.4, -1.0, -0.6).normalized(), Vector3.UP), Vector3(0, 15, 0))
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	root.add_child(sun)
	var torch := OmniLight3D.new()
	torch.name = "TorchLight"
	torch.position = Vector3(0, 2.5, -4.5)
	torch.light_color = Color(1.0, 0.65, 0.3) # Warm firelight
	torch.light_energy = 2.0
	torch.omni_range = 6.0
	torch.omni_attenuation = 1.2
	root.add_child(torch)

	var spot := SpotLight3D.new()
	spot.name = "AlcoveSpot"
	spot.position = Vector3(4.0, 3.5, 0.0)
	spot.transform = Transform3D(Basis.looking_at(Vector3(-1.0, -0.5, 0.0).normalized(), Vector3.UP), Vector3(4.0, 3.5, 0.0))
	spot.light_color = Color(0.5, 0.75, 1.0) # Cool blue spotlight
	spot.light_energy = 1.5
	spot.spot_angle = 35.0
	spot.spot_attenuation = 1.0
	root.add_child(spot)

	# ==========================================================================
	# 2. Geometry: Courtyard Floor (12m x 12m)
	# ==========================================================================
	var floor_node := PBMesh.new()
	floor_node.name = "CourtyardFloor"
	floor_node.pb_mesh_data = PBShapeGenerators.create_box(Vector3(12.0, 0.5, 12.0))
	floor_node.position = Vector3(0, -0.25, 0)
	floor_node.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(floor_node)

	# Apply texture splatting to floor top face (face 4 = +Y)
	# Brick path with smooth edge going down the middle of the floor through the door
	var top_face: PBFace = floor_node.pb_mesh_data.faces[4]
	var mask_img := Image.create(512, 512, false, Image.FORMAT_R8)
	mask_img.fill(Color(0, 0, 0, 1))
	for y in range(512):
		# y maps from Z = -6.0 (North / Door) to Z = +6.0 (South)
		var z_world := (float(y) / 512.0) * 12.0 - 6.0
		for x in range(512):
			# x maps from X = -6.0 (West) to X = +6.0 (East)
			var x_world := (float(x) / 512.0) * 12.0 - 6.0

			# Path width: 1.2m half-width, flaring out to 1.6m at the doorway (z < -3.5)
			var path_half_w := 1.2
			if z_world < -3.5:
				path_half_w = lerpf(1.2, 1.6, clampf((-3.5 - z_world) / 2.0, 0.0, 1.0))

			var dx := absf(x_world)
			var w_path := 0.0
			# Solid brick core with smooth edge falloff
			var falloff_w := 0.4
			if dx < path_half_w:
				w_path = 1.0
			elif dx < path_half_w + falloff_w:
				w_path = smoothstep(path_half_w + falloff_w, path_half_w, dx)

			# Central circular plaza widening in the courtyard
			var dist_center := Vector2(x_world, z_world).length()
			if dist_center < 2.5:
				var w_plaza := smoothstep(2.5, 1.8, dist_center)
				w_path = maxf(w_path, w_plaza)

			mask_img.set_pixel(x, y, Color(w_path, 0, 0, 1))

	var splat_mat := PBSplat.create_splat_material()
	splat_mat.resource_name = "FloorSplatMat"
	splat_mat.set_shader_parameter("base_color", Color(1.0, 1.0, 1.0, 1.0))
	if ResourceLoader.exists("res://addons/poibuilder/materials/textures/tiles_light_4x4.png"):
		splat_mat.set_shader_parameter("base_texture", load("res://addons/poibuilder/materials/textures/tiles_light_4x4.png"))
	splat_mat.set_shader_parameter("layer_1_enabled", true)
	splat_mat.set_shader_parameter("layer_1_color", Color(1.0, 1.0, 1.0, 1.0))
	var brick_tex_path := "res://addons/poibuilder/materials/textures/brick_path_4x4.png"
	if ResourceLoader.exists(brick_tex_path):
		splat_mat.set_shader_parameter("layer_1_texture", load(brick_tex_path))
	elif ResourceLoader.exists("res://addons/poibuilder/materials/textures/circular_square_pattern.png"):
		splat_mat.set_shader_parameter("layer_1_texture", load("res://addons/poibuilder/materials/textures/circular_square_pattern.png"))
	splat_mat.set_shader_parameter("layer_1_mask", ImageTexture.create_from_image(mask_img))

	var tiles_mat := _get_tiles_material()
	floor_node.pb_mesh_data.materials = [splat_mat, tiles_mat]
	for f_idx in range(floor_node.pb_mesh_data.faces.size()):
		var f: PBFace = floor_node.pb_mesh_data.faces[f_idx]
		if f_idx == 4:
			f.submesh_index = 0 # splat_mat
			f.splat_bounds = PackedFloat32Array([-6.0, 6.0, -6.0, 6.0])
		else:
			f.submesh_index = 1 # tiles_mat
			f.splat_bounds = PackedFloat32Array()
	# Add Decal Stamp on floor: "HELLO WORLD" text stamp crossing the brick splat boundary
	var floor_stamps := Node3D.new()
	floor_stamps.name = "PBStamps"
	floor_node.add_child(floor_stamps)

	var hello_stamp := MeshInstance3D.new()
	hello_stamp.name = "Stamp_HelloWorld"
	var qm := QuadMesh.new()
	qm.size = Vector2.ONE
	hello_stamp.mesh = qm

	# Flush on floor top face (+Y normal, pointing up) at X=1.7 (boundary of brick path), Z=1.0
	# Width = 4.32m, Height = 2.16m. Right-handed unmirrored basis
	var hello_basis := Basis(
		Vector3(4.32, 0.0, 0.0),
		Vector3(0.0, 0.0, -2.16),
		Vector3(0.0, 1.0, 0.0)
	)
	hello_stamp.transform = Transform3D(
		hello_basis,
		Vector3(1.7, 0.252, 1.0)
	)

	var hello_tex_path := "res://addons/poibuilder/materials/textures/stamp_hello_world.png"
	var hello_tex: Texture2D = load(hello_tex_path) if ResourceLoader.exists(hello_tex_path) else null
	var decal_shader_res: Shader = load("res://addons/poibuilder/materials/shaders/pb_decal_shader.gdshader") if ResourceLoader.exists("res://addons/poibuilder/materials/shaders/pb_decal_shader.gdshader") else null

	if decal_shader_res != null:
		var hello_mat := ShaderMaterial.new()
		hello_mat.shader = decal_shader_res
		hello_mat.set_shader_parameter("albedo_texture", hello_tex)
		hello_mat.set_shader_parameter("albedo_color", Color.WHITE)
		hello_mat.set_shader_parameter("stamp_to_mesh", hello_stamp.transform)
		hello_mat.set_shader_parameter("clip_to_face", true)
		var fb := PBSplat.get_face_planar_bounds(floor_node.pb_mesh_data, top_face, true)
		hello_mat.set_shader_parameter("face_u", fb["u"])
		hello_mat.set_shader_parameter("face_v", fb["v"])
		hello_mat.set_shader_parameter("face_bounds", Vector4(fb["min_u"], fb["max_u"], fb["min_v"], fb["max_v"]))
		hello_stamp.material_override = hello_mat
	else:
		var hello_mat := StandardMaterial3D.new()
		hello_mat.albedo_texture = hello_tex
		hello_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		hello_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		hello_stamp.material_override = hello_mat
	hello_stamp.set_meta("face_idx", 4)
	hello_stamp.set_meta("stamp_texture_path", hello_tex_path)
	hello_stamp.set_meta("stamp_opacity", 1.0)
	hello_stamp.set_meta("stamp_scale", 4.32)
	hello_stamp.set_meta("anchor_u", 1.7)
	hello_stamp.set_meta("anchor_v", 1.0)
	hello_stamp.set_meta("anchor_scale_x", 4.32)
	hello_stamp.set_meta("anchor_scale_y", 2.16)
	hello_stamp.set_meta("anchor_rot_right", Vector3.RIGHT)
	hello_stamp.set_meta("anchor_rot_up", Vector3.FORWARD)
	hello_stamp.set_meta("anchor_center", Vector2((1.7 - (-6.0)) / 12.0, (1.0 - (-6.0)) / 12.0))
	hello_stamp.set_meta("anchor_du", Vector2((4.32 * 0.5) / 12.0, 0.0))
	hello_stamp.set_meta("anchor_dv", Vector2(0.0, (2.16 * 0.5) / 12.0))
	floor_stamps.add_child(hello_stamp)

	# ==========================================================================
	# 3. Geometry: North Wall with Arched Doorway
	# ==========================================================================
	var door_node := PBMesh.new()
	door_node.name = "NorthArchedDoorway"
	# Door width=4, height=4, opening_height=2.8, leg_width=0.8, depth=1.0, arched=true, arch_segments=8
	door_node.pb_mesh_data = PBShapeComplex.create_door(4.0, 4.0, 2.8, 0.8, 1.0, true, 8)
	door_node.position = Vector3(0, 2.0, -5.5)
	door_node.collider_type = PBMesh.ColliderType.ACCURATE
	door_node.pb_mesh_data.materials = [_get_tiles_material()]
	root.add_child(door_node)

	# ==========================================================================
	# 4. Geometry: Grand Stairs to Balcony
	# ==========================================================================
	var stairs_node := PBMesh.new()
	stairs_node.name = "TerraceStairs"
	stairs_node.pb_mesh_data = PBShapeComplex.create_stairs(Vector3(2.5, 3.0, 4.0), 8)
	stairs_node.position = Vector3(-4.5, 1.5, 0.0)
	stairs_node.rotation.y = PI
	stairs_node.collider_type = PBMesh.ColliderType.ACCURATE
	stairs_node.pb_mesh_data.materials = [_get_tiles_material()]
	root.add_child(stairs_node)

	# Elevated Balcony Platform
	var balcony := PBMesh.new()
	balcony.name = "BalconyPlatform"
	balcony.pb_mesh_data = PBShapeGenerators.create_box(Vector3(3.0, 0.4, 4.0))
	balcony.position = Vector3(-4.5, 3.0, -4.0)
	balcony.collider_type = PBMesh.ColliderType.ACCURATE
	balcony.pb_mesh_data.materials = [_get_tiles_material()]
	root.add_child(balcony)

	# ==========================================================================
	# 5. Geometry: N-gon Pillars (Hexagonal Prisms)
	# ==========================================================================
	var pillar1 := PBMesh.new()
	pillar1.name = "Pillar_Left"
	pillar1.pb_mesh_data = PBShapeCylinder.create_cylinder(0.4, 3.0, 6) # 6-sided prism
	pillar1.position = Vector3(-3.2, 1.5, -4.0)
	pillar1.collider_type = PBMesh.ColliderType.ACCURATE
	pillar1.pb_mesh_data.materials = [_get_checker_material()]
	root.add_child(pillar1)

	var pillar2 := PBMesh.new()
	pillar2.name = "Pillar_Right"
	pillar2.pb_mesh_data = PBShapeCylinder.create_cylinder(0.4, 3.0, 6)
	pillar2.position = Vector3(-5.5, 1.5, -4.0)
	pillar2.collider_type = PBMesh.ColliderType.ACCURATE
	pillar2.pb_mesh_data.materials = [_get_checker_material()]
	root.add_child(pillar2)

	# ==========================================================================
	# 6. Geometry: Sloped Ramp (Prism)
	# ==========================================================================
	var ramp := PBMesh.new()
	ramp.name = "EastRamp"
	ramp.pb_mesh_data = PBShapeGenerators.create_prism(Vector3(2.0, 2.0, 4.0))
	ramp.position = Vector3(4.5, 1.0, 1.0)
	ramp.collider_type = PBMesh.ColliderType.ACCURATE
	ramp.pb_mesh_data.materials = [_get_tiles_material()]
	root.add_child(ramp)

	# Decal stamp on prism slope (face 3), partially cut off at the top ridge
	var ramp_stamps := Node3D.new()
	ramp_stamps.name = "PBStamps"
	ramp.add_child(ramp_stamps)

	var prism_stamp := MeshInstance3D.new()
	prism_stamp.name = "Stamp_CircularPrism"
	var prism_qm := QuadMesh.new()
	prism_qm.size = Vector2.ONE
	prism_stamp.mesh = prism_qm

	# Face 3 normal = (-0.894427, 0.447214, 0), u = (0, 0, 1), v = (0.447214, 0.894427, 0)
	# Width = 3.6m, Height = 3.6m
	var ramp_basis := Basis(
		Vector3(0.0, 0.0, 3.6),
		Vector3(0.447214 * 3.6, 0.894427 * 3.6, 0.0),
		Vector3(-0.894427, 0.447214, 0.0)
	)
	prism_stamp.transform = Transform3D(
		ramp_basis,
		Vector3(-0.224, 0.559, 0.0)
	)

	var circle_tex_path := "res://addons/poibuilder/materials/textures/circular_square_pattern.png"
	var circle_tex: Texture2D = load(circle_tex_path) if ResourceLoader.exists(circle_tex_path) else null

	if decal_shader_res != null:
		var prism_mat := ShaderMaterial.new()
		prism_mat.shader = decal_shader_res
		prism_mat.set_shader_parameter("albedo_texture", circle_tex)
		prism_mat.set_shader_parameter("albedo_color", Color.WHITE)
		prism_mat.set_shader_parameter("stamp_to_mesh", prism_stamp.transform)
		prism_mat.set_shader_parameter("clip_to_face", true)
		var rb := PBSplat.get_face_planar_bounds(ramp.pb_mesh_data, ramp.pb_mesh_data.faces[3], true)
		prism_mat.set_shader_parameter("face_u", rb["u"])
		prism_mat.set_shader_parameter("face_v", rb["v"])
		prism_mat.set_shader_parameter("face_bounds", Vector4(rb["min_u"], rb["max_u"], rb["min_v"], rb["max_v"]))
		prism_stamp.material_override = prism_mat
	else:
		var prism_mat := StandardMaterial3D.new()
		prism_mat.albedo_texture = circle_tex
		prism_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		prism_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		prism_stamp.material_override = prism_mat
	prism_stamp.set_meta("face_idx", 3)
	prism_stamp.set_meta("stamp_texture_path", circle_tex_path)
	prism_stamp.set_meta("stamp_opacity", 1.0)
	prism_stamp.set_meta("stamp_scale", 3.6)
	prism_stamp.set_meta("anchor_u", 0.0)
	prism_stamp.set_meta("anchor_v", 0.4)
	prism_stamp.set_meta("anchor_scale_x", 3.6)
	prism_stamp.set_meta("anchor_scale_y", 3.6)
	prism_stamp.set_meta("anchor_rot_right", Vector3(0.0, 0.0, 1.0))
	prism_stamp.set_meta("anchor_rot_up", Vector3(0.447214, 0.894427, 0.0))
	prism_stamp.set_meta("anchor_center", Vector2((0.0 - (-2.0)) / 4.0, (0.4 - (-1.3416)) / 2.236))
	prism_stamp.set_meta("anchor_du", Vector2((3.6 * 0.5) / 4.0, 0.0))
	prism_stamp.set_meta("anchor_dv", Vector2(0.0, (3.6 * 0.5) / 2.236))
	ramp_stamps.add_child(prism_stamp)

	# ==========================================================================
	# 7. Waterfall: animated (scrolling) textures, retro-exportable
	# ==========================================================================
	# Every surface below scrolls because its MATERIAL carries a speed (see
	# PBUv.set_scroll_speed): the retro exporters write that into each mesh's
	# uv_scroll fields, so the engine animates it with a texture-coordinate
	# offset — no shader, no per-frame vertex traffic.
	#
	# The speed is where the PATTERN TRAVELS, in the surface's own UV axes
	# (V runs up a wall, and toward +Z on a floor), so falling water is a
	# NEGATIVE V and churn spreading away from the wall is a POSITIVE V.
	#
	# Composition is what sells a waterfall at this polygon budget:
	#   - a wall panel to fall down,
	#   - a broad sheet + a narrower, faster inner core in front of it
	#     (parallax => depth), the core drawn with SOFT ALPHA so the stone
	#     reads through the water,
	#   - a ripple pool hugging the wall with a foam ribbon spreading from the
	#     impact point,
	#   - one alpha-cutout spray billboard at the base.
	var fall_wall := PBMesh.new()
	fall_wall.name = "WaterfallWall"
	fall_wall.pb_mesh_data = PBShapeGenerators.create_box(Vector3(4.0, 5.0, 0.6))
	fall_wall.position = Vector3(4.5, 2.5, -5.3)
	fall_wall.collider_type = PBMesh.ColliderType.ACCURATE
	fall_wall.pb_mesh_data.materials = [_get_tiles_material()]
	root.add_child(fall_wall)

	# Standing water sheets: the plane's local +X/+Z span the sheet, and the
	# basis points its normal (+Y) out of the wall.
	var fall_x := 4.5
	var wall_face_z := -5.0
	# The sheet is BLENDED as well: its alpha is how much water stands in front
	# of the wall at that texel, so the stone reads through the thin parts and
	# the rope crests go almost opaque. It is emitted before the core, which is
	# the order the engine needs to blend the two layers back to front.
	var sheet := _make_water_sheet("Waterfall_Sheet", 2.0, 4.2,
		Vector3(fall_x, 2.2, wall_face_z + 0.06),
		"res://addons/poibuilder/materials/textures/waterfall_sheet.png",
		Vector2(0.04, -0.75), Vector2(0.6, 0.35))
	_water_material_props(sheet.pb_mesh_data.materials[0], true)
	root.add_child(sheet)

	# The core sheet is BLENDED (transparency = Alpha): the spray of water in
	# front of the fall lets the wall through, which is what reads as "wet".
	# It also sits in front of the opaque sheet, so it blends over finished
	# pixels whatever order the engine draws the two in.
	var core := _make_water_sheet("Waterfall_Core", 0.9, 4.0,
		Vector3(fall_x - 0.25, 2.1, wall_face_z + 0.14),
		"res://addons/poibuilder/materials/textures/waterfall_core.png",
		Vector2(0.0, -1.15), Vector2(1.2, 0.5))
	_water_material_props(core.pb_mesh_data.materials[0], true)
	root.add_child(core)

	# Pool: a flat ripple surface floating just above the courtyard floor, its
	# far edge tucked against the wall so no dry floor shows through under the
	# fall (the stand-off also keeps it clear of the floor's depth values).
	var pool := _make_water_floor("Waterfall_Pool", 3.6, 3.2,
		Vector3(fall_x, 0.04, wall_face_z + 1.6),
		"res://addons/poibuilder/materials/textures/water_pool.png",
		Vector2(0.02, 0.03), Vector2(0.55, 0.55))
	root.add_child(pool)

	# Foam ribbon: the churn pushed out of the impact point, its trailing edge
	# at the wall so the churn starts where the water lands (+Z is +V on a
	# floor, so spreading away from the wall is a POSITIVE v speed).
	var foam := _make_water_floor("Waterfall_Foam", 2.8, 1.6,
		Vector3(fall_x, 0.06, wall_face_z + 0.8),
		"res://addons/poibuilder/materials/textures/water_foam.png",
		Vector2(0.0, 0.30), Vector2(0.5, 0.9))
	root.add_child(foam)

	# Spray: a billboard whose texture scrolls upwards, so the mist appears to
	# climb off the impact point. Billboard materials repeat their texture (the
	# exporter only clamps tiling for decals), which is what lets it scroll.
	var spray := _create_billboard_node("WaterfallSpray",
		"res://addons/poibuilder/materials/textures/water_spray.png",
		Vector2(2.2, 1.5), Vector3(fall_x, 0.62, wall_face_z + 0.35), false, true)
	PBUv.set_scroll_speed(spray.material_override as Material, Vector2(0.0, 0.35))
	root.add_child(spray)

	# ==========================================================================
	# 7b. Billboards: Foliage & Trees (Lit and Unlit)
	# ==========================================================================
	# Lit Pine Tree
	var tree_pine := _create_billboard_node("Tree_Pine",
		"res://addons/poibuilder/materials/textures/tree_pine.png",
		Vector2(2.5, 5.0), Vector3(3.5, 2.5, 4.0), true)
	root.add_child(tree_pine)

	# Lit Oak Tree
	var tree_oak := _create_billboard_node("Tree_Oak",
		"res://addons/poibuilder/materials/textures/tree_oak.png",
		Vector2(4.0, 4.5), Vector3(-4.0, 2.25, 4.0), true)
	root.add_child(tree_oak)

	# Lit Bush
	var bush := _create_billboard_node("Bush_Foliage",
		"res://addons/poibuilder/materials/textures/bush_foliage.png",
		Vector2(1.5, 1.5), Vector3(2.0, 0.75, 3.2), true)
	root.add_child(bush)

	# Unlit Wildflowers (Pure white unshaded emission)
	var flowers := _create_billboard_node("Wildflowers_Unlit",
		"res://addons/poibuilder/materials/textures/flower_patch.png",
		Vector2(1.2, 1.2), Vector3(-2.0, 0.6, 2.0), false)
	root.add_child(flowers)

	# ==========================================================================
	# 7c. Custom Gameplay Entities (Spawn, Walkable, Trigger, Emitter, BallPit)
	# ==========================================================================
	# 1. Player Spawn Point
	var spawn_node := Marker3D.new()
	spawn_node.name = "PlayerSpawn"
	spawn_node.position = Vector3(0.0, 1.6, 4.2)
	spawn_node.set_meta("camera_fov", 65.0)
	root.add_child(spawn_node)

	# 2. Walkable Mesh Navigation Surface
	var walkable_node := MeshInstance3D.new()
	walkable_node.name = "Walkable_Courtyard"
	var w_am := ArrayMesh.new()
	var w_arrs: Array = []
	w_arrs.resize(Mesh.ARRAY_MAX)
	w_arrs[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-4.0, 0.0, -5.5), Vector3(4.0, 0.0, -5.5), Vector3(4.0, 0.0, 5.0),
		Vector3(-4.0, 0.0, -5.5), Vector3(4.0, 0.0, 5.0),  Vector3(-4.0, 0.0, 5.0)
	])
	w_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, w_arrs)
	walkable_node.mesh = w_am
	walkable_node.visible = false # Navigation surface, hidden in visual game view
	root.add_child(walkable_node)

	# 3. Cutscene / Event Trigger Area
	var trig_node := Area3D.new()
	trig_node.name = "Trigger_Archway"
	trig_node.position = Vector3(0.0, 1.75, -5.3)
	trig_node.set_meta("event", "on_enter_archway")
	trig_node.set_meta("oneshot", true)
	var trig_col := CollisionShape3D.new()
	trig_col.name = "TriggerBox"
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(4.0, 3.5, 1.0)
	trig_col.shape = box_shape
	trig_node.add_child(trig_col)
	root.add_child(trig_node)

	# 4. Particle Emitter Marker
	var emitter_node := Marker3D.new()
	emitter_node.name = "Emitter_Torch"
	emitter_node.position = Vector3(2.5, 1.8, -4.5)
	emitter_node.set_meta("rate", 30)
	emitter_node.set_meta("lifetime", 1.2)
	emitter_node.set_meta("velocity", Vector3(0.0, 1.5, 0.0))
	emitter_node.set_meta("spread", 0.3)
	emitter_node.set_meta("color", Color(1.0, 0.55, 0.2, 1.0))
	root.add_child(emitter_node)

	# 5. Physics Rigid Bodies (Ball Pit Container)
	var ball_pit_node := Node3D.new()
	ball_pit_node.name = "BallPit"
	ball_pit_node.position = Vector3(0.0, 0.0, 0.0)
	ball_pit_node.set_meta("count", 16)
	ball_pit_node.set_meta("radius", 0.22)
	ball_pit_node.set_meta("mass", 1.0)
	ball_pit_node.set_meta("restitution", 0.75)
	root.add_child(ball_pit_node)
	# ==========================================================================
	# 8. Optional Player Character
	# ==========================================================================
	if include_player:
		var player := CharacterBody3D.new()
		player.name = "Player"
		player.position = Vector3(0.0, 1.0, 3.5)
		if ResourceLoader.exists("res://player.gd"):
			player.set_script(load("res://player.gd"))

		var col := CollisionShape3D.new()
		col.name = "CollisionShape3D"
		var cap := CapsuleShape3D.new()
		cap.radius = 0.4
		cap.height = 1.8
		col.shape = cap
		player.add_child(col)

		var cam := Camera3D.new()
		cam.name = "Camera3D"
		cam.position = Vector3(0.0, 0.6, 0.0)
		cam.current = true
		player.add_child(cam)

		root.add_child(player)
	return root

static func save_showcase_scene(file_path: String, include_player: bool = false) -> Error:
	var root := build_showcase_scene(include_player)
	_set_owner_recursive(root, root)
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		root.free()
		return err
	err = ResourceSaver.save(packed, file_path)
	root.free()
	return err

static func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	for child in node.get_children():
		child.owner = scene_owner
		_set_owner_recursive(child, scene_owner)

## A standing water sheet: a 1-cell plane whose normal (+Y) is rotated out of
## the wall it hangs on. `uv_scale` is the face's tiling (repeats per metre);
## the scroll speed lives on the material (see PBUv.set_scroll_speed).
static func _make_water_sheet(name_str: String, width: float, height: float,
		pos: Vector3, tex_path: String, scroll: Vector2, uv_scale: Vector2) -> PBMesh:
	var node := PBMesh.new()
	node.name = name_str
	node.pb_mesh_data = PBShapeGenerators.create_plane(width, height)
	node.pb_mesh_data.materials = [_water_material(name_str + "_Mat", tex_path, scroll)]
	node.pb_mesh_data.faces[0].uv_scale = uv_scale
	# local +X -> world +X, +Y (the plane normal) -> +Z out of the wall,
	# +Z -> -Y (down): a right-handed basis whose sheet faces the courtyard.
	node.transform = Transform3D(Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN), pos)
	node.collider_type = PBMesh.ColliderType.OFF
	return node

## A horizontal water surface (pool, foam ribbon) lying on the floor, normal up.
static func _make_water_floor(name_str: String, width: float, depth: float,
		pos: Vector3, tex_path: String, scroll: Vector2, uv_scale: Vector2) -> PBMesh:
	var node := PBMesh.new()
	node.name = name_str
	node.pb_mesh_data = PBShapeGenerators.create_plane(width, depth)
	node.pb_mesh_data.materials = [_water_material(name_str + "_Mat", tex_path, scroll)]
	node.pb_mesh_data.faces[0].uv_scale = uv_scale
	node.position = pos
	node.collider_type = PBMesh.ColliderType.OFF
	return node

static func _water_material(name_str: String, tex_path: String, scroll: Vector2,
		blended: bool = false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = name_str
	mat.albedo_color = Color.WHITE
	mat.roughness = 0.35
	if ResourceLoader.exists(tex_path):
		mat.albedo_texture = load(tex_path)
	PBUv.set_scroll_speed(mat, scroll)
	_water_material_props(mat, blended)
	return mat

## Sets the transparency a water surface needs. TRANSPARENCY_ALPHA is the
## SOFT one: the retro exporters turn it into a blended texture with an 8-bit
## alpha ramp (and keep its mip chain), where DISABLED keeps it opaque.
static func _water_material_props(mat: Material, blended: bool) -> void:
	var sm := mat as StandardMaterial3D
	if sm == null:
		return
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if blended else BaseMaterial3D.TRANSPARENCY_DISABLED
	if blended:
		# Water darkens what is under it; a white albedo keeps the tint in the
		# texture's own alpha ramp rather than in the material color.
		sm.albedo_color = Color(1.0, 1.0, 1.0, 0.85)
		sm.cull_mode = BaseMaterial3D.CULL_DISABLED

static func _create_billboard_node(name_str: String, tex_path: String,
		size: Vector2, pos: Vector3, is_lit: bool, soft_alpha: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_str
	mi.position = pos
	mi.set_meta("is_billboard", true)
	mi.set_meta("is_lit", is_lit)

	var qm := QuadMesh.new()
	qm.size = size
	mi.mesh = qm

	var mat := StandardMaterial3D.new()
	mat.resource_name = name_str + "_Mat"
	# Foliage art is a CUTOUT: a hard silhouette that alpha-tests, so its
	# texture keeps level 0 (mip levels of a 1-bit alpha eat the leaves). Mist
	# and smoke are the opposite case and ask for a soft blend.
	mat.transparency = (BaseMaterial3D.TRANSPARENCY_ALPHA if soft_alpha
		else BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if ResourceLoader.exists(tex_path):
		mat.albedo_texture = load(tex_path)

	if not is_lit:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat

	return mi
## Shared instances, built once per process. Building a fresh material per call
## makes each caller hold its own Texture2D reference, and the glTF writer then
## embeds one image PER MATERIAL — which changes the exported texture count
## depending on whether Godot's resource cache happened to hand back the same
## texture, and makes the export fixtures non-reproducible.
static var _cached_checker_material: StandardMaterial3D = null
static var _cached_tiles_material: StandardMaterial3D = null

static func _get_checker_material() -> StandardMaterial3D:
	if _cached_checker_material != null:
		return _cached_checker_material
	var mat := StandardMaterial3D.new()
	mat.resource_name = "CheckerMaterial"
	mat.albedo_color = Color(0.9, 0.9, 0.9, 1.0)
	if ResourceLoader.exists("res://addons/poibuilder/materials/textures/checkerboard_2x2.png"):
		mat.albedo_texture = load("res://addons/poibuilder/materials/textures/checkerboard_2x2.png")
	mat.roughness = 0.8
	_cached_checker_material = mat
	return mat

static func _get_tiles_material() -> StandardMaterial3D:
	if _cached_tiles_material != null:
		return _cached_tiles_material
	var mat := StandardMaterial3D.new()
	mat.resource_name = "TilesMaterial"
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	if ResourceLoader.exists("res://addons/poibuilder/materials/textures/tiles_light_4x4.png"):
		mat.albedo_texture = load("res://addons/poibuilder/materials/textures/tiles_light_4x4.png")
	mat.roughness = 0.7
	_cached_tiles_material = mat
	return mat
