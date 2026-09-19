## AlphaDemoMapBuilder — the ALPHA DEMO MAP: one small map that exercises every
## core feature, used by the end-to-end walkthroughs in the documentation and by
## the frame-pacing benchmark (PB scene vs retro-baked GLB vs modern GLB).
##
## Features on display (docs/site "Build a map, end to end"):
##   - architecture: walls, an arched DOOR, exterior STAIRS to a walkable roof
##   - texture SPLATTING: the courtyard floor blends three albedos
##   - DECALS: two stamps painted into the decal layer
##   - a WATERFALL built from scrolling textures + particles
##   - particle EMITTERS: flame flipbook + embers + waterfall mist + neon dust
##   - BILLBOARDS: trees and bushes
##   - a closed NEON ROOM set up for LightmapGI (UV2 unwrapped, GI Static,
##     BAKE_STATIC lights, emissive strips) with imported barrel props
##
## The map is built headlessly:
##   godot-mono --headless --path project -s res://test_scenes/alpha_demo_build.gd
## (the -s wrapper saves the .tscn; see run_demo_map.sh / run_bench.sh)
##
## Barrel props: PSX Modular Medieval pack by valsekamerplant
## (https://valsekamerplant.itch.io) — loaded from the dev machine's asset
## library; like TestMapShowcaseBuilder the map simply has no props when the
## pack is absent.
@tool
class_name AlphaDemoMapBuilder
extends RefCounted

const PROP_LIBRARY_DIR := "/mnt/ephemeral/assets/PSX_Modular_Medieval/Market"
const TEX := "res://addons/poibuilder/materials/textures/"

## Courtyard: x in [-8, 8], z in [-8, 8] (floor node at the origin, so the
## top face's LOCAL rect == the world rect — decals and splat bounds author
## against one coordinate space).
const FLOOR_HALF_X := 8.0
const FLOOR_Z0 := -8.0
const FLOOR_Z1 := 8.0
const FLOOR_TOP_LOCAL_Y := 0.25 # box half-height: the top face's local plane
const WALL_H := 3.5
const ROOF_TOP := 3.8

static func build_demo_scene(include_player: bool = false, preset_name: String = "dusk") -> Node3D:
	var root := Node3D.new()
	root.name = "AlphaDemoMap"

	# ── Environment: dusk — warm low sun outside, neon carries the indoors ──
	PBEnvironment.apply_preset(root, preset_name)
	root.set_meta("poi_env_preset", preset_name.to_lower())

	# ══════════════════════════════════════════════════════════ courtyard floor
	# Splatting: one box, the +Y face blends three albedos — wet slate base,
	# a brick path running from the doorway to the plaza, and flower patches
	# near the trees. Masks are authored as Images exactly the way the paint
	# brush writes them (the splat bounds map the face's world rect).
	var floor_node := PBMesh.new()
	floor_node.name = "CourtyardFloor"
	floor_node.pb_mesh_data = PBShapeGenerators.create_box(
		Vector3(FLOOR_HALF_X * 2.0, 0.5, FLOOR_Z1 - FLOOR_Z0))
	floor_node.position = Vector3(0, -0.25, 0)
	floor_node.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(floor_node)
	_paint_floor_splat(floor_node)

	# Decal 1: the HELLO stamp across the plaza (spans the splat path boundary).
	# Decal centres are LOCAL: the top face sits at local y = +0.25.
	var hello_path := TEX + "stamp_hello_world.png"
	if ResourceLoader.exists(hello_path):
		var hello_img: Image = (load(hello_path) as Texture2D).get_image()
		var painted := PBSplat.paste_decal(floor_node.pb_mesh_data,
			Vector3(1.2, FLOOR_TOP_LOCAL_Y, 3.0), Vector3.UP, 12.0, 3.6, 1.0, hello_img)
		if painted == 0:
			PBLogger.new().warn("io", "AlphaDemo: floor stamp did not land")
	# Decal 2: flower patch worn into the ground by the pool.
	var flower_path := TEX + "flower_patch.png"
	if ResourceLoader.exists(flower_path):
		var flower_img: Image = (load(flower_path) as Texture2D).get_image()
		PBSplat.paste_decal(floor_node.pb_mesh_data,
			Vector3(-4.6, FLOOR_TOP_LOCAL_Y, 1.2), Vector3.UP, 0.0, 1.6, 0.9, flower_img)
	# Wet-stain dabs ringing the pool — a stamp used as MATERIAL rather than
	# a sticker: soft dark blotches that damp whatever they land on,
	# overlapping each other and the pool's rim.
	var stain_path := TEX + "stamp_wet_stain.png"
	if ResourceLoader.exists(stain_path):
		var stain_img: Image = (load(stain_path) as Texture2D).get_image()
		for dab: Array in [
			[Vector3(-4.7, FLOOR_TOP_LOCAL_Y, 0.1), 25.0, 2.8, 0.85],
			[Vector3(-5.4, FLOOR_TOP_LOCAL_Y, -2.4), 160.0, 2.4, 0.8],
			[Vector3(-6.9, FLOOR_TOP_LOCAL_Y, 1.3), 195.0, 2.6, 0.7],
			[Vector3(-4.2, FLOOR_TOP_LOCAL_Y, -1.2), 90.0, 1.8, 0.6],
		]:
			PBSplat.paste_decal(floor_node.pb_mesh_data, dab[0], Vector3.UP,
				dab[1], dab[2], dab[3], stain_img)

	# ════════════════════════════════════════════════════════════════ building
	# South wall with the arched doorway (the door shape IS the wall piece).
	var door_node := PBMesh.new()
	door_node.name = "DoorwayWall"
	# width 8 / height 3.5 / opening 2.6 / legs (8-2.5)/2=2.75 / depth 0.5
	door_node.pb_mesh_data = PBShapeComplex.create_door(8.0, WALL_H, 2.6, 2.75, 0.5, true, 8)
	door_node.position = Vector3(-2.0, WALL_H * 0.5, -6.75)
	door_node.collider_type = PBMesh.ColliderType.ACCURATE
	root.add_child(door_node)
	_set_interior_faces(door_node, Vector3(0, 0, -1)) # faces pointing into the room
	# Decal 3: a tapestry poster on the wall beside the door. Door mesh local
	# rect: x in [-4, 4] (legs end at ±4), y in [-1.75, 1.75], outer face at
	# local z = +0.25. Poster centre on the west leg.
	var tapestry_path := TEX + "tapestry.png"
	if ResourceLoader.exists(tapestry_path):
		var tapestry_img: Image = (load(tapestry_path) as Texture2D).get_image()
		PBSplat.paste_decal(door_node.pb_mesh_data,
			Vector3(-2.6, 0.2, 0.251), Vector3.BACK, 0.0, 1.7, 1.0, tapestry_img)

	var north_wall := _wall("NorthWall", Vector3(8.0, WALL_H, 0.5), Vector3(-2.0, WALL_H * 0.5, -12.75), Vector3(0, 0, 1))
	var west_wall := _wall("WestWall", Vector3(0.5, WALL_H, 5.5), Vector3(-5.75, WALL_H * 0.5, -9.5), Vector3(1, 0, 0))
	var east_wall := _wall("EastWall", Vector3(0.5, WALL_H, 5.5), Vector3(1.75, WALL_H * 0.5, -9.5), Vector3(-1, 0, 0))
	for w in [north_wall, west_wall, east_wall]:
		root.add_child(w)
	# Interior slabs: dark floor + roof (roof top doubles as the stair landing;
	# its UNDERSIDE is the room's ceiling).
	var room_floor := _wall("RoomFloor", Vector3(7.5, 0.1, 5.5), Vector3(-2.0, 0.05, -9.75))
	var roof := _wall("RoofSlab", Vector3(8.5, 0.3, 6.75), Vector3(-2.0, ROOF_TOP - 0.15, -9.75), Vector3(0, -1, 0))
	root.add_child(room_floor)
	root.add_child(roof)

	# ── Stairs: exterior run along the east wall up to the roof ──
	var stairs := PBMesh.new()
	stairs.name = "RoofStairs"
	stairs.pb_mesh_data = PBShapeComplex.create_stairs(Vector3(1.5, ROOF_TOP, 4.5), 12)
	stairs.position = Vector3(2.75, ROOF_TOP * 0.5, -6.75)
	stairs.rotation.y = PI # climb toward -z, landing on the roof's east edge
	stairs.collider_type = PBMesh.ColliderType.ACCURATE
	stairs.pb_mesh_data.materials = [tiles_material()]
	root.add_child(stairs)

	# ═══════════════════════════════════════════════════════════════ waterfall
	# Every water surface SCROLLS (its material carries a UV speed — PBUv
	# set_scroll_speed; the retro export writes it into the mesh's uv_scroll
	# fields, the modern export mirrors it into the material's glTF extras).
	# The falls is a layered read, back to front:
	#   a stone LIP it pours from, an APRON crawling across that lip, the
	#   broad slow SHEET, two narrow side TRICKLES on their own speeds, the
	#   fast CORE in front (parallax against the sheet sells the depth), a
	#   ripple POOL under a bright impact-FOAM ribbon and a wide faint swell,
	#   two climbing SPRAY billboards, and a MIST bank whose emission SPHERE
	#   spans the sheet's width (spawn_radius rides the retro emitter record,
	#   so the PSP plays the same full-width footprint) plus a thin wisp
	#   drifting up the wall face.
	var fall_wall := PBMesh.new()
	fall_wall.name = "WaterfallWall"
	fall_wall.pb_mesh_data = PBShapeGenerators.create_box(Vector3(0.6, 4.5, 4.0))
	fall_wall.position = Vector3(-7.5, 2.25, -1.0)
	fall_wall.collider_type = PBMesh.ColliderType.ACCURATE
	fall_wall.pb_mesh_data.materials = [wet_tiles_material()]
	root.add_child(fall_wall)

	# The lip: a thin cap across the wall top, protruding past the face —
	# the water has a source to pour from instead of starting mid-wall.
	var fall_lip := PBMesh.new()
	fall_lip.name = "WaterfallLip"
	fall_lip.pb_mesh_data = PBShapeGenerators.create_box(Vector3(0.9, 0.2, 3.0))
	fall_lip.position = Vector3(-7.35, 4.42, -1.0)
	fall_lip.collider_type = PBMesh.ColliderType.OFF
	fall_lip.pb_mesh_data.materials = [wet_tiles_material()]
	root.add_child(fall_lip)

	var apron := make_water_floor("Waterfall_Apron", 0.8, 2.6,
		Vector3(-7.3, 4.53, -1.0), TEX + "water_pool.png",
		Vector2(0.55, 0.0), Vector2(0.35, 1.0))
	root.add_child(apron)
	# The veil: a full-width bright base of slow moving water (the pool
	# texture) the streak layers play in front of — without it the streak
	# textures' transparent-black body reads as a dark smear on the wall.
	var veil := make_water_sheet("Waterfall_Veil", 2.6, 4.3,
		Vector3(-7.14, 2.22, -1.0), TEX + "water_pool.png",
		Vector2(0.02, -0.45), Vector2(0.7, 0.8))
	root.add_child(veil)
	var sheet := make_water_sheet("Waterfall_Sheet", 2.4, 4.3,
		Vector3(-7.12, 2.22, -1.0), TEX + "waterfall_sheet.png",
		Vector2(0.05, -0.7), Vector2(0.75, 0.4))
	root.add_child(sheet)
	var trickle_west := make_water_sheet("Waterfall_TrickleW", 0.4, 3.6,
		Vector3(-7.06, 1.9, -1.95), TEX + "waterfall_core.png",
		Vector2(0.03, -1.05), Vector2(0.4, 0.9))
	root.add_child(trickle_west)
	var trickle_east := make_water_sheet("Waterfall_TrickleE", 0.4, 3.4,
		Vector3(-7.06, 1.85, -0.1), TEX + "waterfall_core.png",
		Vector2(-0.02, -0.9), Vector2(0.4, 0.85))
	root.add_child(trickle_east)
	var core := make_water_sheet("Waterfall_Core", 1.0, 4.0,
		Vector3(-7.0, 2.1, -1.0), TEX + "waterfall_core.png",
		Vector2(0.0, -1.15), Vector2(1.3, 0.55))
	root.add_child(core)
	var pool := make_water_floor("Waterfall_Pool", 3.0, 3.2,
		Vector3(-6.15, 0.04, -1.0), TEX + "water_pool.png",
		Vector2(0.02, -0.03), Vector2(0.55, 0.55))
	root.add_child(pool)
	var foam := make_water_floor("Waterfall_Foam", 2.2, 1.1,
		Vector3(-6.6, 0.06, -1.0), TEX + "water_foam.png",
		Vector2(0.0, -0.5), Vector2(0.5, 1.1))
	root.add_child(foam)
	var swell := make_water_floor("Waterfall_Swell", 2.8, 2.4,
		Vector3(-6.3, 0.05, -1.0), TEX + "water_foam.png",
		Vector2(0.0, -0.12), Vector2(0.45, 0.85))
	root.add_child(swell)
	var spray := TestMapShowcaseBuilder.create_billboard("WaterfallSpray",
		TEX + "water_spray.png", Vector2(2.2, 1.5), Vector3(-6.5, 0.7, -1.0), false, true)
	PBUv.set_scroll_speed(spray.material_override as Material, Vector2(0.0, 0.35))
	root.add_child(spray)
	var spray_fine := TestMapShowcaseBuilder.create_billboard("WaterfallSprayFine",
		TEX + "water_spray.png", Vector2(1.4, 1.0), Vector3(-6.6, 0.42, -0.25), false, true)
	PBUv.set_scroll_speed(spray_fine.material_override as Material, Vector2(0.0, 0.55))
	root.add_child(spray_fine)
	var fall_lantern := OmniLight3D.new()
	fall_lantern.name = "WaterfallLantern"
	# Grazing the falls face at mid height: this is the light that makes the
	# sheet read as water instead of a wet wall.
	fall_lantern.position = Vector3(-6.5, 3.3, -1.0)
	fall_lantern.light_color = Color(0.70, 0.90, 1.0)
	fall_lantern.light_energy = 3.5
	fall_lantern.omni_range = 8.0
	root.add_child(fall_lantern)
	# A low teal uplight inside the mist bank: the spray glows from below.
	var pool_light := OmniLight3D.new()
	pool_light.name = "WaterfallPoolLight"
	pool_light.position = Vector3(-6.2, 0.9, -1.0)
	pool_light.light_color = Color(0.55, 0.8, 1.0)
	pool_light.light_energy = 1.2
	pool_light.omni_range = 4.5
	root.add_child(pool_light)

	# ════════════════════════════════════════════════════════ billboards/trees
	var pine := TestMapShowcaseBuilder.create_billboard("Tree_Pine",
		TEX + "tree_pine.png", Vector2(2.5, 5.0), Vector3(5.5, 2.5, 6.5), true)
	root.add_child(pine)
	var oak := TestMapShowcaseBuilder.create_billboard("Tree_Oak",
		TEX + "tree_oak.png", Vector2(4.0, 4.5), Vector3(-4.5, 2.25, 7.5), true)
	root.add_child(oak)
	var bush := TestMapShowcaseBuilder.create_billboard("Bush_Foliage",
		TEX + "bush_foliage.png", Vector2(1.5, 1.5), Vector3(3.0, 0.75, 6.0), true)
	root.add_child(bush)

	# ═════════════════════════════════════════════════════════ brazier + fire
	var pedestal := PBMesh.new()
	pedestal.name = "BrazierPedestal"
	pedestal.pb_mesh_data = PBShapeGenerators.create_box(Vector3(0.9, 0.9, 0.9))
	pedestal.position = Vector3(-3.5, 0.45, 3.5)
	pedestal.collider_type = PBMesh.ColliderType.ACCURATE
	pedestal.pb_mesh_data.materials = [tiles_material()]
	root.add_child(pedestal)
	var flame := TestMapShowcaseBuilder.create_emitter("Emitter_BrazierFlame",
		Vector3(-3.5, 1.05, 3.5), TEX + "particle_flame_2x2_sheet.png",
		20, 0.8, 0.9, true, true, 2, 2)
	root.add_child(flame)
	var embers := TestMapShowcaseBuilder.create_emitter("Emitter_Embers",
		Vector3(-3.5, 1.05, 3.5), TEX + "particle_glow.png",
		12, 1.3, 0.32, true, false)
	var ember_pm := embers.process_material as ParticleProcessMaterial
	ember_pm.initial_velocity_min = 1.1
	ember_pm.initial_velocity_max = 2.0
	ember_pm.spread = 26.0
	root.add_child(embers)
	# A warm pool of light so the fire lights the plaza at dusk.
	var fire_light := OmniLight3D.new()
	fire_light.name = "BrazierLight"
	fire_light.position = Vector3(-3.5, 1.6, 3.5)
	fire_light.light_color = Color(1.0, 0.65, 0.3)
	fire_light.light_energy = 2.0
	fire_light.omni_range = 6.0
	root.add_child(fire_light)
	# The mist: ONE emitter whose emission SPHERE spans the falls' width, so
	# the bank reads as wide as the sheet it fronts (a point emitter reads as
	# a puff no matter the quad size). spawn_radius is part of the retro
	# emitter record (PBM bytes + glTF extras), so both targets play the same
	# footprint. Blended path (RGBA, sorted), like the sheet in front of it.
	var mist := TestMapShowcaseBuilder.create_emitter("Emitter_Mist",
		Vector3(-6.55, 0.8, -1.0), TEX + "particle_smoke.png",
		40, 2.1, 1.2, false, true)
	var mist_pm := mist.process_material as ParticleProcessMaterial
	mist_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mist_pm.emission_sphere_radius = 1.05
	mist_pm.initial_velocity_min = 0.2
	mist_pm.initial_velocity_max = 0.6
	# Many faint sprites overlap into a bank; fewer opaque ones clump into a
	# blob. The tint rides the retro emitter record (ramp × tint).
	mist_pm.color = Color(1.0, 1.0, 1.0, 0.55)
	root.add_child(mist)
	# A thin wisp drifting up the wall face ties the bank to the falls.
	var wisp := TestMapShowcaseBuilder.create_emitter("Emitter_SprayWisp",
		Vector3(-7.0, 1.7, -1.0), TEX + "particle_smoke.png",
		8, 2.6, 2.1, false, true)
	var wisp_pm := wisp.process_material as ParticleProcessMaterial
	wisp_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	wisp_pm.emission_sphere_radius = 0.45
	wisp_pm.initial_velocity_min = 0.12
	wisp_pm.initial_velocity_max = 0.35
	wisp_pm.gravity = Vector3(0.0, 0.15, 0.0)
	root.add_child(wisp)

	# ═══════════════════════════════════════════════════════════════ neon room
	_build_neon_room(root)

	# ═══════════════════════════════════════════════════════════ spawn/player
	var spawn := Marker3D.new()
	spawn.name = "PlayerSpawn"
	spawn.position = Vector3(0.0, 1.6, 6.0)
	spawn.set_meta("camera_fov", 70.0)
	root.add_child(spawn)

	if include_player:
		var player := CharacterBody3D.new()
		player.name = "Player"
		player.position = Vector3(0.0, 1.0, 5.0)
		if ResourceLoader.exists("res://player.gd"):
			player.set_script(load("res://player.gd"))
		var col := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.4
		cap.height = 1.8
		col.shape = cap
		player.add_child(col)
		var cam := Camera3D.new()
		cam.position = Vector3(0, 0.6, 0)
		cam.current = true
		player.add_child(cam)
		root.add_child(player)

	return root


## The closed cyberpunk room: dark envelope, emissive strips, coloured static
## lights, imported barrels, one additive dust emitter, and a LightmapGI node.
## Every room surface is UV2-unwrapped and GI-Static, and every light is
## BAKE_STATIC — open the editor, select LightmapGI, "Bake Lightmaps", and the
## room lights with pure bounce.
static func _build_neon_room(root: Node3D) -> void:
	# Emissive strips (MeshInstance3D + emission — the light source that bakes).
	var strips := [
		{"n": "NeonStrip_Cyan_Top", "size": Vector3(7.0, 0.08, 0.08),
			"pos": Vector3(-2.0, 3.1, -12.4), "col": Color(0.2, 0.95, 1.0), "e": 6.0},
		{"n": "NeonStrip_Magenta_Low", "size": Vector3(0.08, 0.08, 5.2),
			"pos": Vector3(-5.55, 0.25, -9.75), "col": Color(1.0, 0.15, 0.8), "e": 5.0},
		{"n": "NeonStrip_Teal_Door", "size": Vector3(2.4, 0.08, 0.08),
			"pos": Vector3(-2.0, 2.75, -7.0), "col": Color(0.1, 1.0, 0.75), "e": 5.0},
	]
	for s in strips:
		var strip := MeshInstance3D.new()
		strip.name = s["n"]
		var box := BoxMesh.new()
		box.size = s["size"]
		strip.mesh = box
		strip.position = s["pos"]
		var mat := StandardMaterial3D.new()
		mat.resource_name = String(s["n"]) + "_Mat"
		mat.albedo_color = s["col"]
		mat.emission_enabled = true
		mat.emission = s["col"]
		mat.emission_energy_multiplier = s["e"]
		strip.material_override = mat
		root.add_child(strip)

	# Coloured static lights: the direct light you see before baking, and the
	# input the lightmapper turns into bounce. Energies are sized for the
	# retro bake (whose vertex colors cap at 1.0 — the bake needs headroom to
	# reach it) and RANGES are sized to stay inside the room: an omni whose
	# range crosses the walls paints neon onto the courtyard outside through
	# shadow-map bias.
	var lights := [
		{"n": "NeonLight_Cyan", "pos": Vector3(0.5, 2.8, -11.5),
			"col": Color(0.35, 0.85, 1.0), "e": 2.4, "r": 6.5},
		{"n": "NeonLight_Magenta", "pos": Vector3(-4.5, 1.8, -8.0),
			"col": Color(1.0, 0.3, 0.8), "e": 2.1, "r": 5.5},
		{"n": "NeonLight_Warm", "pos": Vector3(-4.2, 2.3, -11.6),
			"col": Color(1.0, 0.65, 0.35), "e": 1.7, "r": 3.8},
	]
	for l in lights:
		var omni := OmniLight3D.new()
		omni.name = l["n"]
		omni.position = l["pos"]
		omni.light_color = l["col"]
		omni.light_energy = l["e"]
		omni.omni_range = l["r"]
		omni.shadow_enabled = true
		omni.light_bake_mode = Light3D.BAKE_STATIC
		root.add_child(omni)

	# Emissive pedestal — a little monolith for the neon to pool around.
	var pedestal := MeshInstance3D.new()
	pedestal.name = "NeonPedestal"
	var pbox := BoxMesh.new()
	pbox.size = Vector3(1.2, 0.5, 1.2)
	pedestal.mesh = pbox
	pedestal.position = Vector3(-1.0, 0.35, -10.5)
	var pmat := StandardMaterial3D.new()
	pmat.resource_name = "NeonPedestal_Mat"
	pmat.albedo_color = Color(0.05, 0.03, 0.1)
	pmat.emission_enabled = true
	pmat.emission = Color(0.5, 0.2, 1.0)
	pmat.emission_energy_multiplier = 1.2
	pedestal.material_override = pmat
	root.add_child(pedestal)

	# Additive dust motes drifting in the neon.
	var dust := TestMapShowcaseBuilder.create_emitter("Emitter_NeonDust",
		Vector3(-2.0, 1.8, -9.5), TEX + "particle_glow.png",
		12, 2.2, 0.2, true, false)
	var dust_pm := dust.process_material as ParticleProcessMaterial
	dust_pm.spread = 180.0
	dust_pm.initial_velocity_min = 0.05
	dust_pm.initial_velocity_max = 0.25
	root.add_child(dust)

	# Barrel props (PSX Modular Medieval by valsekamerplant). Deliberately left
	# as plain imported MeshInstance3D nodes — the "dropped a GLB in the scene"
	# case — marked GI-Dynamic so they receive the baked lightmap via probes.
	# The library lives outside the repo (/mnt/ephemeral on the dev machine);
	# a machine without it builds a map MISSING THE PROPS — that must be loud,
	# not a silent census drift between machines' bench exports.
	var barrels := [
		{"f": "barrel.glb", "n": "Prop_Barrel", "pos": Vector3(-4.6, 0.06, -11.7), "yaw": 0.4},
		{"f": "barrel_open.glb", "n": "Prop_BarrelOpen", "pos": Vector3(-3.75, 0.06, -11.95), "yaw": -0.6},
		{"f": "barrel_apples.glb", "n": "Prop_BarrelApples", "pos": Vector3(-4.35, 0.06, -10.9), "yaw": 2.4},
	]
	if not DirAccess.dir_exists_absolute(PROP_LIBRARY_DIR):
		push_error("prop library missing: %s — the map builds WITHOUT the %d pack props (barrels); exports on this machine are not comparable to ones from the dev machine" % [
			PROP_LIBRARY_DIR, barrels.size()])
		print("[demo-map] ERROR: prop library missing (%s) — building without the %d barrels" % [
			PROP_LIBRARY_DIR, barrels.size()])
	for b in barrels:
		var prop := TestMapShowcaseBuilder.load_prop_glb(PROP_LIBRARY_DIR.path_join(b["f"]))
		if prop == null:
			continue
		prop.name = b["n"]
		prop.position = b["pos"]
		prop.rotation.y = b["yaw"]
		root.add_child(prop)
		for child in _mesh_instances(prop):
			child.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC

	# LightmapGI: pre-create the .lmbake path (the editor bake writes the atlas
	# next to it without prompting) and mark every room surface ready for it.
	var lgi := LightmapGI.new()
	lgi.name = "LightmapGI"
	lgi.quality = LightmapGI.BAKE_QUALITY_MEDIUM
	lgi.bounces = 3
	lgi.bounce_indirect_energy = 1.2
	lgi.directional = true
	lgi.use_denoiser = true
	lgi.texel_scale = 1.0
	lgi.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_SUBDIV_8
	var data := LightmapGIData.new()
	var data_path := "res://exports/alpha_demo.lmbake"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://exports"))
	var err := ResourceSaver.save(data, data_path)
	if err == OK:
		lgi.light_data = load(data_path)
	else:
		PBLogger.new().warn("io", "AlphaDemo: could not pre-create %s (%s)" % [data_path, error_string(err)])
	root.add_child(lgi)

	# Unwrap UV2 + flip to GI-Static on the room envelope (the meshes the bake
	# lights). Paint never touches UV2 — masks ride in CUSTOM0 — so splatting
	# and lightmaps stay independent on the same mesh.
	for node in root.get_children():
		if node is PBMesh and (node as PBMesh).name in ["RoomFloor", "RoofSlab", "NorthWall", "WestWall", "EastWall", "DoorwayWall"]:
			var mesh := node as PBMesh
			var xf := Transform3D(Basis.from_euler(mesh.rotation), mesh.position)
			PBUvOps.unwrap_lightmap_uv2(mesh.pb_mesh_data, xf, 0.05)
			mesh.gi_mode = GeometryInstance3D.GI_MODE_STATIC


## ── helpers ─────────────────────────────────────────────────────────────────

static func _wall(wall_name: String, size: Vector3, pos: Vector3,
		interior_dir: Vector3 = Vector3.ZERO) -> PBMesh:
	var node := PBMesh.new()
	node.name = wall_name
	node.pb_mesh_data = PBShapeGenerators.create_box(size)
	node.position = pos
	node.collider_type = PBMesh.ColliderType.ACCURATE
	if wall_name == "RoomFloor":
		# Fully interior: every face dark, tiled at the calmer half density.
		node.pb_mesh_data.materials = [dark_interior_material()]
		for face in node.pb_mesh_data.faces:
			if face != null:
				face.uv_scale = Vector2(0.5, 0.5)
	elif interior_dir != Vector3.ZERO:
		# Envelope piece: plaster outside, the dark interior finish on every
		# face whose normal points into the room (interior_dir).
		node.pb_mesh_data.materials = [plaster_material(), dark_interior_material()]
		_set_interior_faces(node, interior_dir)
	else:
		node.pb_mesh_data.materials = [plaster_material()]
	return node


## Faces whose normal points along `interior_dir` (dot > 0.5) take material
## submesh 1 (the dark interior finish); everything else stays on submesh 0.
## Interior faces also tile at half density (one texture repeat per 2 m) —
## at the default 1 repeat/m the 4x4 tile sheet reads as fine noise in
## pooled light instead of a surface you can see.
static func _set_interior_faces(node: PBMesh, interior_dir: Vector3) -> void:
	var md := node.pb_mesh_data
	for f_idx in range(md.faces.size()):
		var face := md.faces[f_idx]
		if face == null:
			continue
		var n := PBMath.normal_from_positions(md.positions, face.get_indexes())
		if n.normalized().dot(interior_dir) > 0.5:
			face.submesh_index = 1
			face.uv_scale = Vector2(0.5, 0.5)
		else:
			face.submesh_index = 0


## The courtyard floor's top face splat: masks are authored as Images over the
## face's world rect, exactly the data the paint brush writes. Two textures
## blend: the wet-slate base and a brick path from the doorway through the
## plaza. (Flower detail is DECAL work — a flower texture tiled as a splat
## layer reads as wallpaper.)
static func _paint_floor_splat(floor_node: PBMesh) -> void:
	var depth := FLOOR_Z1 - FLOOR_Z0
	var res := 1024
	var path_img := Image.create(res, res, false, Image.FORMAT_R8)
	path_img.fill(Color(0, 0, 0, 1))
	for y in range(res):
		var z := (float(y) / res) * depth + FLOOR_Z0
		for x in range(res):
			var wx := (float(x) / res) * (FLOOR_HALF_X * 2.0) - FLOOR_HALF_X
			# Brick path: from the doorway (x=-2) south to the plaza, flaring
			# at the door and around the brazier.
			var w_path := 0.0
			var half_w := 1.25
			var dx := absf(wx + 2.0)
			if z > FLOOR_Z0 - 0.5 and z < 4.0 and dx < half_w:
				w_path = 1.0
			elif z > FLOOR_Z0 - 0.5 and z < 4.0 and dx < half_w + 0.4:
				w_path = smoothstep(half_w + 0.4, half_w, dx)
			var plaza := Vector2(wx + 1.2, z - 2.0).length()
			if plaza < 2.6:
				w_path = maxf(w_path, smoothstep(2.6, 2.0, plaza))
			path_img.set_pixel(x, y, Color(w_path, 0, 0, 1))

	var splat_mat := PBSplat.create_splat_material()
	splat_mat.resource_name = "CourtyardSplatMat"
	if ResourceLoader.exists(TEX + "tiles_wet_4x4.png"):
		splat_mat.set_shader_parameter("base_texture", load(TEX + "tiles_wet_4x4.png"))
	splat_mat.set_shader_parameter("layer_1_enabled", true)
	if ResourceLoader.exists(TEX + "brick_path_4x4.png"):
		splat_mat.set_shader_parameter("layer_1_texture", load(TEX + "brick_path_4x4.png"))
	splat_mat.set_shader_parameter("layer_1_mask", ImageTexture.create_from_image(path_img))

	var side_mat := tiles_material()
	floor_node.pb_mesh_data.materials = [splat_mat, side_mat]
	for f_idx in range(floor_node.pb_mesh_data.faces.size()):
		var f: PBFace = floor_node.pb_mesh_data.faces[f_idx]
		if f_idx == 4:
			f.submesh_index = 0
			f.splat_bounds = PackedFloat32Array([
				-FLOOR_HALF_X, FLOOR_HALF_X, FLOOR_Z0, FLOOR_Z1])
		else:
			f.submesh_index = 1
			f.splat_bounds = PackedFloat32Array()


## A standing water sheet: a 1-cell plane hung on a wall, +Y (its normal)
## rotated out to +X. `uv_scale` is the face's tiling; the scroll speed lives
## on the material (PBUv.set_scroll_speed), which the retro export animates.
static func make_water_sheet(name_str: String, width: float, height: float,
		pos: Vector3, tex_path: String, scroll: Vector2, uv_scale: Vector2) -> PBMesh:
	var node := PBMesh.new()
	node.name = name_str
	node.pb_mesh_data = PBShapeGenerators.create_plane(width, height)
	node.pb_mesh_data.materials = [water_material(name_str + "_Mat", tex_path, scroll)]
	node.pb_mesh_data.faces[0].uv_scale = uv_scale
	# local +X -> world +Z (along the wall), +Y (normal) -> world +X (out of
	# the wall), +Z -> world -Y (down the fall): right-handed, faces east.
	node.transform = Transform3D(
		Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, -1, 0)), pos)
	node.collider_type = PBMesh.ColliderType.OFF
	return node


static func make_water_floor(name_str: String, width: float, depth: float,
		pos: Vector3, tex_path: String, scroll: Vector2, uv_scale: Vector2) -> PBMesh:
	var node := PBMesh.new()
	node.name = name_str
	node.pb_mesh_data = PBShapeGenerators.create_plane(width, depth)
	node.pb_mesh_data.materials = [water_material(name_str + "_Mat", tex_path, scroll)]
	node.pb_mesh_data.faces[0].uv_scale = uv_scale
	node.position = pos
	node.collider_type = PBMesh.ColliderType.OFF
	return node


static func water_material(name_str: String, tex_path: String, scroll: Vector2) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = name_str
	# A bright blue-white tint: the falls textures are streaks over
	# transparent black, and at dusk an unboosted albedo reads as a dark
	# smear instead of lit water. The near-opaque alpha keeps the layering
	# (veil under streaks) from muddying out.
	mat.albedo_color = Color(1.45, 1.6, 1.8, 0.9)
	mat.roughness = 0.35
	if ResourceLoader.exists(tex_path):
		mat.albedo_texture = load(tex_path)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	PBUv.set_scroll_speed(mat, scroll)
	return mat


static func tiles_material() -> StandardMaterial3D:
	return TestMapShowcaseBuilder.tiles_material()


static func wet_tiles_material() -> StandardMaterial3D:
	return TestMapShowcaseBuilder.wet_tiles_material()


static func plaster_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "PlasterMaterial"
	if ResourceLoader.exists(TEX + "tiles_light_4x4.png"):
		mat.albedo_texture = load(TEX + "tiles_light_4x4.png")
	mat.albedo_color = Color(0.85, 0.82, 0.78)
	mat.roughness = 0.85
	return mat


static func dark_interior_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "DarkInteriorMaterial"
	if ResourceLoader.exists(TEX + "tiles_wet_4x4.png"):
		mat.albedo_texture = load(TEX + "tiles_wet_4x4.png")
	# "Dark" is RELATIVE, and the retro pipeline is the reason this is not
	# darker: a retro surface's brightness is albedo x baked vertex color,
	# and vertex color is hard-capped at 1.0 — a 40% albedo wall can never
	# render brighter than 40%, and the baked neon room came out black. ~62%
	# still reads as the dark envelope under dusk ambient, and lets the
	# capped bake carry the neon.
	mat.albedo_color = Color(0.62, 0.62, 0.72)
	mat.roughness = 0.35
	mat.metallic = 0.15
	return mat


static func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## Saves the scene: rebuilds every painted mask/decal texture from the CPU
## images first (a headless save would serialize stale GPU pixels), claims
## owners, packs, writes.
static func save_demo_scene(file_path: String, include_player: bool = false) -> Error:
	var root := build_demo_scene(include_player)
	_flush_paint_textures(root)
	_set_owner_recursive(root, root)
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		root.free()
		return err
	err = ResourceSaver.save(packed, file_path)
	root.free()
	return err


## Exports the demo map in the two GLB flavors the frame-pacing benchmark
## compares against the live PB scene:
##   - retro baked  -> res://exports/alpha_demo_retro_baked.glb (+ .pbm)
##   - modern       -> res://exports/alpha_demo_modern.glb (paint baked
##     into textures; collision included)
## The GLBs stay under res://exports/ — an export target must NOT be a
## scanned directory: ensure_export_dir drops a .gdignore there, and one in
## res://test_scenes/ would make the editor's class scan skip this whole
## directory (test_pb_map_showcase then silently loses TestMapShowcaseBuilder).
## The benchmark therefore parses them with GLTFDocument, like the viewer.
## Returns {retro_glb: Error, pbm: Error, modern_glb: Error}.
static func export_bench_variants() -> Dictionary:
	var results := {}
	var root := build_demo_scene(false)
	_flush_paint_textures(root)
	_set_owner_recursive(root, root)
	var p := PBEnvironment.get_preset("dusk")

	var retro := PBMapExporter.ExportSettings.new()
	retro.export_mode = PBMapExporter.ExportMode.RETRO
	retro.subdivide_quads = true
	retro.grid_size = 1.0
	retro.bake_lighting = true
	retro.bake_shadows = true
	retro.bake_ao = true
	retro.bake_textures = true
	retro.tile_resolution = 128
	retro.export_colliders = true
	retro.export_billboards = true
	retro.ambient_color = p["ambient_color"]
	results["retro_glb"] = PBMapExporter.export_map(root,
		"res://exports/alpha_demo_retro_baked.glb", retro)
	results["pbm"] = PBMapExporter.export_map(root,
		"res://exports/alpha_demo_retro_baked.pbm", retro)

	var modern := PBMapExporter.ExportSettings.new()
	modern.export_mode = PBMapExporter.ExportMode.MODERN
	modern.splat_mode = PBMapExporter.ExportSettings.SplatMode.BAKE
	modern.bake_lighting = false # the live scene carries realtime lights
	modern.export_colliders = true
	modern.export_billboards = true
	results["modern_glb"] = PBMapExporter.export_map(root,
		"res://exports/alpha_demo_modern.glb", modern)

	root.free()
	return results


static func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	for child in node.get_children():
		child.owner = scene_owner
		_set_owner_recursive(child, scene_owner)


## Rebuilds the GPU mask/decal textures of every PBMesh under `node` from the
## CPU image cache (see PBSplat.sync_mesh_mask_textures) — a headless save
## otherwise serializes stale pre-update pixels and silently drops the paint.
static func _flush_paint_textures(node: Node) -> void:
	if node is PBMesh and (node as PBMesh).pb_mesh_data != null:
		PBSplat.sync_mesh_mask_textures((node as PBMesh).pb_mesh_data)
	for child in node.get_children():
		_flush_paint_textures(child)
